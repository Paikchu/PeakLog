# Phase 0 云端数据服务(第 4 步)落地日志

关联:`docs/plans/2026-07-07-phase0-auth-sync-plan.md`(§1 云端为主同步、§4 客户端改动)、`docs/logs/2026-07-07-phase0-auth-gate.md`

## 本次范围

实施 Phase 0 第 4 步:云端数据读写。登录用户的数据流从"纯本地"接到 Supabase——登录时全量拉取覆盖本地缓存,任何本地写入后全量对账推送上云。开发账号:`yzh5277@outlook.com`。

## 关键架构决策(对方案的一处务实反转)

方案 §1 写的是"写路径先写云端,成功后更新本地缓存"。实际落地反转为**本地先改 → 全量对账推送**:

- 复用 `LocalAppDatabase` 已有的全部领域逻辑(id 生成、set 重排、plan↔session 关联),不在云端重复实现。
- 每个 mutation 统一走一条推送路径(全表 bulk upsert + delete-not-in),避免为 ~25 个 service 方法各写一份云端映射。
- 推送失败不阻塞本地;下次 `pull` 自动自愈。前台回来时:有未推送改动就重推,否则拉取(避免用云端覆盖掉未推送的本地改动)。
- **登录时先 pull 再装 onChange 钩子**,保证种子数据(非 UUID id)永不上云。DEBUG 本地模式不装钩子,零网络。

代价:每次写会推送整份用户数据(约 20 个小请求)。个人应用数据量小、写频率低(约每 90 秒一组),可接受;已在协调器注释与本日志记录。

## 数据库改动(已应用到 fqyurmsuvtdafbnynurg)

- `20260707000010_add_exercise_library_fields_to_exercises.sql`:`exercises` 表补 `exercise_id text` + `exercise_load_type`,否则已记录动作的库 slug 与负重类型在 pull→push 往返中丢失。

## 新增文件

- `Services/Cloud/SupabaseDataClient.swift` — PostgREST 三动词客户端:`fetch` / `upsert`(`Prefer: resolution=merge-duplicates`)/ `deleteNotIn`。每请求带 publishable key + 新鲜 JWT(经 `TokenProviding`),RLS 服务端隔离。
- `Services/Cloud/CloudRows.swift` — 各表 Row DTO(日期/时间戳统一用 String,避开 date 与 timestamptz 解码冲突)+ `CloudDate` 转换助手。
- `Services/Cloud/CloudMapper.swift` — 领域模型 ↔ Row 双向映射(纯函数、静态、可离线测)。自定义动作 id 剥/接 `custom-` 前缀。空计划合成器给冷启动用户一个稳定 UUID 的空计划。
- `Services/Cloud/CloudSnapshotLoader.swift` — 读路径:并发拉取所有表 → `CloudMapper.assembleSnapshot`。
- `Services/Cloud/CloudSyncCoordinator.swift`(actor)— pull / 合并串行化的 push / 前台处理;`performPush` 按父→子 upsert、子→父 delete-not-in。
- `Services/Cloud/CloudSyncController.swift`(@MainActor ObservableObject)— 按 auth 状态启停协调器,按 userId 幂等,转发前台 tick。
- `Services/Cloud/LocalDataSnapshot.swift` — 从 `LocalAppDatabase.swift` 抽出,便于映射层脱离 actor 单测。

## 改动文件

- `Services/LocalAppDatabase.swift` — 加 `onChange` 钩子(在 `persist()` 后触发,`replaceAll` 不触发以防回声)、`snapshot()`、`replaceAll(...)`(拉取写入,重算派生 stats/PR,不触发钩子)。
- `Services/Auth/AuthProviding.swift` — 加 `TokenProviding` 协议。
- `Services/Auth/AuthStateManager.swift` — 加 `validToken()`(过期自动 refresh)+ `makeTokenProvider()` 的 Sendable adapter。
- `PeakLogApp.swift` — 加 `CloudSyncController`;`onChange(of: authManager.state)` 驱动启停;前台触发 `onForeground()`。

## 验证

- `xcodebuild build` → **BUILD SUCCEEDED**;`xcodebuild test`(PeakLogTests 全量)→ **TEST SUCCEEDED**。
- **真实网络往返**(独立 harness 编译 auth+client+rows 源码打线上):真登录 → upsert running 行 → 回读字段一致 → delete-not-in 清空 → 验证空 → `CLOUD_ROUNDTRIP_PASSED`。证明 URLSession PostgREST 客户端(upsert Prefer 头、delete-not-in、fetch 解码)、auth、token 全链路对。
- **映射纯度**(`tests/cloud_mapper_roundtrip_test.swift`,swiftc 逻辑型):LocalDataSnapshot → 推送行 → 回装快照,plan/session/running/custom/profile 关键字段全保真;自定义 id 前缀正确剥接。
- 收尾核查线上 6 张核心表均 0 行,未在用户库遗留测试数据。

## 未直接验证(说明)

App 内的集成粘合(`CloudSyncController`→协调器→钩子→真实 mutation 触发推送 / 登录后 pull 覆盖缓存)未在模拟器里跑通,因为模拟器键盘输入被劫持,无法在登录页输入账号。两处最易错的部分(网络、映射)已用真实 Swift 代码打线上验证;粘合层薄且随全量 build/test 通过。建议下次真机或用 pbcopy 输入法在 App 内跑一次:登录 → Today 加计划动作 → 查云端出现对应行。

## 待办 / 下一步

- 人工:仍需在 Today/History 里跑一遍真实 App 流验证集成粘合(见上)。
- 冷启动体验:新账号 pull 后本地是空计划,Today 为空,直到用户手动加或 Phase 2 生成。
- 已知取舍:离线写入直接失败(方案 E1),暂无离线队列。
- 下一步进入 ADR-001 的 Phase 1:`plan_edit_events` / `plan_generations` 表 + 客户端编辑事件记录 + GoalSpec。
