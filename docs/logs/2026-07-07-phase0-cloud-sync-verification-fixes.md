# Phase 0 云端同步验证与 bug 修复日志

关联:`docs/logs/2026-07-07-phase0-cloud-data-sync.md`(第 4 步初次实现)、`docs/plans/2026-07-07-phase0-auth-sync-plan.md`

## 背景

对第 4 步的实现做了一次严肃的自我审查(而不是只信任之前"绿了"的独立 harness),发现独立 harness 只覆盖了 `running_workouts` 一张表,没有覆盖真正的推送顺序、`profiles`/`user_preferences` 的特殊约束,也没有覆盖 App 内真实的启停时序。逐一验证后发现并修复了 **4 个真 bug**。过程中用户已经用真实 App UI 登录并记录了当天计划(卧推/上斜推胸/绳索下压),这份真实数据全程未被触碰——所有验证性删除都改为按唯一 id 定点操作,不再对该账号做整表清空。

## 发现并修复的 Bug

### Bug 1 — `profiles` upsert 撞 RLS(403),整条推送第一步就失败

`profiles` 表只有 `SELECT`/`UPDATE` 策略、没有 `INSERT` 策略(表由 `handle_new_user` 触发器创建,不需要客户端插入)。原实现对它用 `upsert`(即 `POST` + `Prefer: resolution=merge-duplicates`,本质是 INSERT),被 RLS 拒绝:
```
403 new row violates row-level security policy for table "profiles"
```
`profiles` 是 `performPush` 推送顺序里的第一张表,一旦失败,后面所有表都不会推送。

**修复**:给 `SupabaseDataClient` 加 `update(table:match:row:)`(PATCH),`profiles`/`user_preferences` 改用它按 `id`/`user_id` 定点更新,不再 upsert。

### Bug 2 — `user_preferences` upsert 撞唯一键(409)

`user_preferences` 主键是自己的 `id`,但唯一约束在 `user_id` 上;upsert 按 PK 语义走的是"按 `id` 冲突才合并",而请求体没带 `id`,于是变成插入新行,撞上 `UNIQUE(user_id)`:
```
409 duplicate key value violates unique constraint "user_preferences_user_id_key"
```
**修复**:同 Bug 1,改用 PATCH。

### Bug 3 — `training_plan_exercises` 缺 `exercise_id` 列

`CloudRows.TrainingPlanExerciseRow` 里写了 `exercise_id` 字段,但线上表实际没有这一列(`exercises` 表当时已经补过,`training_plan_exercises` 漏补了),推送时 PostgREST 报 `PGRST204 Could not find the 'exercise_id' column`。这个 bug 在第一次做全表列名核对时才发现——之前的独立验证只测过 `running_workouts`,没有实际推过计划数据。

**修复**:新增 migration `20260707000011_add_exercise_id_to_training_plan_exercises.sql`,补列。

### Bug 4 — 登录后到推送钩子安装之间存在竞态窗口

`CloudSyncController` 原来用 SwiftUI `.onChange(of: authManager.state)` 驱动同步启停。`.onChange` 是**延迟到下一次视图更新**才触发的,不是和 `@Published` 状态变化同步发生的。这意味着登录成功后有一个真实存在的窗口——`auth.state` 已经变成 `.signedIn`,但 `CloudSyncController.start()`(从而 `onChange` 推送钩子的安装)还没被调用。如果这个窗口内发生了本地写入,这次写入会永远不被推送(钩子还不存在,不会补触发)。

用真实 App(而非独立 harness)跑一次完整链路时,这个 bug 被复现:登录 → 等首次拉取完成 → 通过真实 service 创建一条记录 → **推送钩子从未触发** → 记录留在本地、云端始终为空。

**修复**:同步启停改用 `auth.$state.sink { ... }`(Combine 订阅在 `@Published` 赋值时**同步**触发),在 `.task` 里先 `bind(to:)` 再 `restore()`,消除窗口。修复后同一条链路(真实 App 内)复现验证:签入 → 拉取 → 真实写入 → 钩子触发 → 推送 → 云端出现记录。

## 额外发现的完整性缺口(非 bug,补齐)

第 4 步把写路径从"云端优先"反转成了"本地先改、后台异步全量推送"——这意味着 UI 操作的 `await` 只等本地写入,**用户完全看不到云端推送是否成功**。这在方案里没有被显式承诺过,是这次架构选择带来的一个真实缺口:用户可能离线训练好几天,完全不知道数据没有备份。

**修复**:新增 `CloudSyncStatus`(idle / syncing / pendingRetry),`CloudSyncCoordinator` 在推送开始/成功/失败时通过回调上报,`CloudSyncController` 转发为 `@Published`,`ProfileScreen` 头像下方加一行小字状态指示(已同步 / 同步中 / 未同步将自动重试),仅在 `.signedIn` 时显示。

## 验证方法与结果

**原则**:发现用户已用真实账号记录了当天计划后,所有后续验证严格避免整表清空(`deleteNotIn(keepIds: [])`),只用带唯一标记的行 + 按 id/条件定点删除。

1. **curl 直接打线上,逐一复现 Bug 1/2**:profiles/user_preferences 的 upsert 分别返回 403/409;改用 PATCH 后均返回 204。✅
2. **全表列名核对**:用 SQL 查询实际 schema,和 `CloudRows.swift` 里全部 DTO 逐字段核对,发现 Bug 3(仅此一处不匹配)。✅ 补列后复核。
3. **真实网络全量推送+拉取往返**(独立 harness,直连 `SupabaseDataClient`/`CloudMapper`/`CloudSnapshotLoader`,按 `performPush` 相同顺序):push → pull → 断言 plan/session/running/custom/profile 全部关键字段一致 → 清理。**PASSED**。
4. **App 内真实端到端验证**(`CloudSyncE2ECheck`,DEBUG-only,`PEAKLOG_E2E=1` 触发):真实 `AuthStateManager` 登录 → 等 `isPreparingSession` 变 false → 通过真实 `AppServices.workoutService` 创建记录 → 独立客户端从云端读回确认 → 清理。**首次运行暴露 Bug 4(FAIL row never appeared),修复后重跑 PASSED**(`performPush running=1` → `PASS row present in cloud`)。
5. **异常路径(隔离环境,不碰真实账号)**:
   - **E1 离线写入**:临时 `LocalAppDatabase`(独立文件)+ 指向 `127.0.0.1:1`(连接立即被拒,不等 DNS 超时)的 client。验证:本地写入成功、`syncStatus` 变 `.pendingRetry`、`hasUnpushedChanges` 保持 true、协调器不抛出/不崩溃、本地记录未回滚。**PASSED**。
   - **E4 token 失效强制登出**:`InMemoryAuthSessionStore` 注入一个已过期 + 假 refresh token 的 session,真实打线上 GoTrue 的 refresh 端点(真实网络,预期被拒),验证 `restore()` 后状态变为 `.signedOut` 且 store 已清空。**PASSED**。
   - **E5 换账号**:未用真实第二账号测试(避免为测试新建/污染账号),改为代码走查确认——`coordinator.start()` 恒定"先 pull 后装钩子",任何账号切换后的首次同步必然先用新账号的云端真相覆盖本地缓存。逻辑与 E1/E2E 验证的启动顺序一致。
   - **E10 双端收敛**:`deleteNotIn` 的非空 `not.in.(...)` 分支此前已用一次性 disposable 行验证过编码正确(保留/删除符合预期);未对当前含真实数据的账号重复该验证。
6. **回归**:`xcodebuild build` **BUILD SUCCEEDED**;`xcodebuild test`(全量 PeakLogTests)**TEST SUCCEEDED**;`supabase_config_test`、`cloud_mapper_roundtrip_test` 均 passed。
7. **数据完整性收尾核查**:确认用户在云端的真实计划数据(2026-07-08,杠铃卧推/上斜器械推胸/绳索下压)全程未被修改;`running_workouts` 表确认无测试残留。

## 改动文件汇总

- `Services/Cloud/SupabaseDataClient.swift` — 新增 `update(table:match:row:)`。
- `Services/Cloud/CloudSyncCoordinator.swift` — `profiles`/`user_preferences` 改 PATCH;新增 `onStatusChange` 回调与 `diagnostics()`。
- `Services/Cloud/CloudSyncController.swift` — 新增 `bind(to:)`(Combine 订阅替代 SwiftUI onChange)、`@Published syncStatus`、`isPreparingSession` 逻辑不变。
- `Services/Cloud/CloudSyncStatus.swift`(新增)。
- `PeakLogApp.swift` — `.task` 内先 `bind` 后 `restore`;移除原 `.onChange(of: authManager.state)`;新增 `environmentObject(syncController)` / `environmentObject(authManager)`。
- `Views/Profile/ProfileScreen.swift` — 新增同步状态指示行。
- `Localizable.xcstrings` — 新增 3 个 `profile.sync.*` 键。
- `backend/supabase/migrations/20260707000011_add_exercise_id_to_training_plan_exercises.sql`(新增,已应用到 `fqyurmsuvtdafbnynurg`)。
- `Services/Cloud/CloudSyncE2ECheck.swift` — 保留(DEBUG-only,`PEAKLOG_E2E=1` 触发),作为后续回归的可重跑真实端到端检查。

## 待办

- E5(换账号)和 E10(双端收敛)未对真实多账号/多端场景做过 live 验证,建议后续有第二个测试账号时补跑。
- 下一步进入 ADR-001 Phase 1。
