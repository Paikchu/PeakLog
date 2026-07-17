# 本地计划编辑重启丢失:推送 PGRST102 根因修复 + 欠推送标志持久化

关联:`docs/logs/2026-07-07-phase0-cloud-sync-verification-fixes.md`(推送链路既往修复)、`docs/plans/2026-07-08-cloud-pull-merge-local-plan.md`(拉取合并语义)

## 现象

2026-07-16,iPhone 17 Pro Max iOS 26.5 模拟器,Tester 账号:任意本地计划编辑(今日页加动作、未来日改组重量,两条路径均复现)落库成功且 UI 回显正常,但 kill 后重启 App,编辑全部回退为云端旧状态。拉取正常,推送静默失败,UI 上没有任何报错。

## 根因(两层叠加)

### 根因 1 — 推送死于 PGRST102:批量 upsert 的对象键集合不一致

用 stderr 分步埋点 + 真实 Tester 会话在模拟器里重放推送,定位到失败点:

```
performPush: upsert training_plan_days (7)
push FAILED: http(status: 400, body: {"code":"PGRST102", "message":"All object keys must match"})
```

PostgREST 要求批量 insert/upsert 数组里**每个对象的键集合完全一致**;而 Swift 合成的
`Encodable` 对 nil 可选字段是"省略键"而不是"输出 null"。当周计划里训练日带
`focus`、休息日 `focus = nil` 时,7 行 `training_plan_days` 的键集合不一致,
整个批量请求 400。`performPush` 是"一步失败、整体中止",于是**每一次全量推送
必定失败**——这解释了为什么编辑事件积压了 7 条横跨多个会话。

嫌疑排除记录:
- 生产库所有推送列均存在(用 anon key 逐表逐列探测,`item_type`/`activity_type`
  等 cardio 新列已部署),排除迁移未部署;
- 本地数据全部是合法 UUID、无 cardio 项,排除 uuid 毒化和 cardio CHECK 约束;
- RLS 各表均为 `FOR ALL USING (user_id = auth.uid())`,排除策略缺失;
- `Prefer: missing=default` 实测在当前部署的 PostgREST 版本上**不生效**
  (仍返回 PGRST102),不能作为修复手段。

任何"部分行有值、部分行为 nil"的可选列都会触发同类失败(计划动作的
`notes`/cardio 字段、组的 `target_weight`/`completed_at`、编辑事件的
`plan_day_id` 等),所以这是系统性问题,不只是 `focus` 一列。

**修复**:`SupabaseDataClient.normalizedBulkBody`——编码后对批量行取键并集,
缺失键补显式 JSON `null`(对全量对账语义而言,省略的 nil 本来就该表达"清空该列")。
所有行都省略的键(如 `training_plans.revision`,故意不编码以保留服务端计数)
维持省略,不破坏"冲突时不触碰"契约。`upsert` 与 `insertIgnoringDuplicates`
共用该归一化。

### 根因 2 — "欠推送"标志只在内存里,冷启动 pull 以云端为真相覆盖本地

`requestPush()` 失败只把 `hasUnpushedChanges` 留在内存等前台重试;进程死亡后
冷启动 `start() → pull() → mergeFromCloud`,计划结构"云端获胜"(只保留完成标记),
未推送的本地编辑被静默覆盖。根因 1 让推送必失败,根因 2 让失败的代价变成数据丢失。

**修复**(持久化欠推送标志,即修复方向 (1);未采用双向 updatedAt 合并——计划子表
没有本地 updatedAt,改动面大且与现有"全量对账"写模型冲突):

- `LocalAppState` 新增 `hasUnpushedChanges` + `localMutationSeq`,在 `persist()`
  里**与业务变更同一次原子落盘**(以 `ownerUserId != nil` 为界,DEBUG 本地模式
  不受影响);旧状态文件缺键按 `false`/`0` 解码,不会重置。
- `snapshot()` 携带 `mutationSeq`;推送成功后 `acknowledgePushedState(mutationSeq:)`
  仅在序号仍匹配时清标志并落盘——推送途中落库的新变更不会被误标为已推送
  (coalescing 循环会立即再推一轮并重新确认)。
- `CloudSyncCoordinator.start()`:检测到持久化欠推送时**改为 push-first**,
  不再 pull 覆盖;`performPush` 原有 revision guard 仍保护服务端 replan
  (服务端 revision 前进时先 pull-merge 再推)。
- `onForeground()` 未武装分支改为复用 `start()`:离线冷启动(初次 pull 失败)
  期间做的编辑同样标脏,回前台后走 push-first,堵住同一 bug 的第二个入口。
- 推送/拉取失败现在写 `os.Logger`(subsystem `com.max.PeakLog`, category
  `CloudSync`)——此前失败完全不可观测,是这次拖了多天才发现的直接原因。

## 验证

- 真实 Tester 会话模拟器实测(临时 stderr 埋点,已移除):修复后全量推送
  端到端走通——`training_plan_days (7)`、`training_plan_exercises (15)`、
  `training_plan_sets (44)`、积压的 7 条 `plan_edit_events` 全部入云并清空。
- 机制验证:向本地状态文件注入"未推送编辑(改组重量 62.5)+ 脏标志",
  冷启动走 push-first,本地值保留并推上云;再次干净冷启动走 pull,
  62.5 依然在(证明经受住了 pull-merge,即完成云端往返)。
- 逻辑测试(swiftc,全部通过):
  - 新增 `tests/cloud_push_bulk_body_test.swift`:键并集补 null、全省略键不发明、
    单行/同构直通、嵌套 payload 幸存。
  - 新增 `tests/cloud_unpushed_flag_test.swift`:无主变更不标脏、有主变更标脏且
    随变更原子落盘、过期 acknowledge 不清标志、匹配 acknowledge 持久清除、
    pull-merge 不动标志与计数、换账号重置。
  - `tests/local_state_decode_compat_test.swift` 增补:缺新键的旧状态文件
    正常加载且出箱干净。
  - 回归:`cloud_pull_merge_test`、`cloud_mapper_roundtrip_test`、
    `plan_edit_event_recording_test` 通过。
- `xcodebuild test` 全量(iPhone 17 Pro Max iOS 26.5,串行)——见 PR 描述。

## 残余风险与后续事项

- **多端并发**:push-first 沿用现有"最后一次全量推送获胜"语义,与前台重试路径
  一致;A 端欠推送冷启动时会以 A 的全量状态对账,B 端在此期间的**客户端**编辑
  可能被 prune(服务端 replan 有 revision guard 保护,不受影响)。本次未扩大
  也未收窄该既有语义。
- **同步失败无 UI 呈现**:`CloudSyncStatus` 注释声称 "Surfaced minimally in
  ProfileScreen",实际无任何 UI 消费 `syncStatus`——建议后续补一个轻量指示器,
  已另开任务。
- **验证过程副作用**:多轮快速启动/杀进程触发 Supabase refresh token 单次使用
  轮换竞态,模拟器上的 Tester 会话已失效登出(与本修复无关)。本地状态文件
  完好且带脏标志(硬拉组重量已还原为 30),下次以 Tester 登录时 push-first
  会自动把还原值推上云,无需人工处理。
- JSONSerialization 重序列化可能改变浮点最短表示,对 numeric(x,y) 列无实际影响
  (服务端按精度取整);同构批量与单行走原编码器直通路径,零风险。
