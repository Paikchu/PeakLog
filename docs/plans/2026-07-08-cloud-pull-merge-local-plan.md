# 技术方案：云端拉取本地保留式合并（修复 Issue #1）

> 上承需求 `docs/requirements/2026-07-08-cloud-pull-merge-local.md`；
> 修复 GitHub Issue #1（`[High] 登录后 pull() 整体覆盖本地数据导致记录丢失`）；
> 分支 `codex/fix-cloud-pull-merge-local`。

## 1. 范围

### 做

- 新增 `LocalAppDatabase.mergeFromCloud(...)`：登录拉取时与本地状态合并，而非整体覆盖。
- `CloudSyncCoordinator.pull()` 改调 `mergeFromCloud`，替换 `replaceAll`。
- 新增合并辅助：`CloudMergeableRecord` 协议、`mergeRecords`、`mergeCustomExercises`、`mergePlanPreservingCompletions`、`isUserGeneratedID` 判据。
- 新增单元测试 `tests/cloud_pull_merge_test.swift`。

### 明确不做

- 不改 push 路径（`performPush` 不变；合并后本地非计划表与云端一致，`deleteNotIn` 不会误删云端历史）。
- 不改 `CloudSnapshotLoader`（拉取范围不变）。
- 不给 `profile` / `goalSpec` 加时间戳或"离线脏标记"（单例云端胜出，确认决策）。
- 不改 `pendingEditEvents` / `editEventSeq` 的 EV1 保留语义。
- 不改 seed 生成逻辑（`makeSeedState`）。

## 2. 数据流

```
登录 → CloudSyncController.start() → coordinator.start()
        │
        ▼
      pull() ─▶ loader.load(userId)  [云端快照，不变]
        │
        ▼
      database.mergeFromCloud(snapshot)   ◀── 替换原 replaceAll
        │
        ├─ strengthSessions : 云端为准 ∪ 本地-only UUID session；同 id updatedAt 取新
        ├─ runningRecords   : 同上
        ├─ customExercises  : 云端为准 ∪ 本地-only custom-<uuid>
        ├─ activePlan       : 云端结构胜出；同 plan.id 则回填离线完成标记
        ├─ profile / goalSpec : 云端胜出
        ├─ pendingEditEvents / editEventSeq : 不动（EV1）
        └─ recalculateDerivedProfile() + writeStateToDisk()  [不触发 onChange]
        │
        ▼
      installChangeHook()  [arming 后的用户 mutation 才推送]
```

关键性质：合并不触发 `onChange`（与原 `replaceAll` 一致），pull 不会回声成 push。

## 3. 设计

### 3.1 判据：`isUserGeneratedID`

`String` 扩展：剥去 `custom-` 前缀后 `UUID(uuidString:)` 可解析 → 用户创建（保留）；否则视为 seed/legacy（合并时丢弃）。

排查确认：`createStrengthSession` / `createRunningRecord` 用 `UUID().uuidString`；`addCustomExercise` 用 `"custom-\(UUID())"`；seed 用 `local-*` / `seed-*` / `plan-*`。无遗漏。

### 3.2 `CloudMergeableRecord` 协议

```swift
nonisolated protocol CloudMergeableRecord: Identifiable, Sendable {
    var id: String { get }
    var updatedAt: Date { get }
}
extension WorkoutSession: CloudMergeableRecord {}
extension RunningWorkoutRecord: CloudMergeableRecord {}
```

`WorkoutSession` 与 `RunningWorkoutRecord` 均为 `nonisolated struct ... Codable, Equatable, Sendable`，已有 `id` / `updatedAt`，conform 无新字段。

### 3.3 `mergeRecords<T: CloudMergeableRecord>(cloud:local:)`

1. 云端行建 `[String: T]` 字典。
2. 遍历本地行：
   - `id` 不在字典：仅当 `id.isUserGeneratedID` 时补入（保留离线用户记录，丢弃 seed）。
   - `id` 在字典（冲突）：若 `local.updatedAt > cloud.updatedAt` 则用本地覆盖（LWW，平手云端）。
3. 返回 `Array(values)`。

exercises/sets 随所属 session 一并保留（嵌套结构，不单独合并）。

### 3.4 `mergeCustomExercises(cloud:local:)`

云端为准；本地-only 且 `isUserGeneratedID`（`custom-<uuid>`）保留；同 id 平手云端。`ExerciseDefinition` 无时间戳，不做 LWW。

### 3.5 `mergePlanPreservingCompletions(cloud:local:) -> TrainingPlan`

- `cloud.id != local.id` → 直接返 `cloud`（seed/local 计划被云端替换）。
- `cloud.id == local.id` → 重建 `cloud.days`，对每个 planSet：
  - 若云端 set `!isCompleted` 且本地同 `set.id` 的 set `isCompleted` → 回填 `completedAt` / `linkedExerciseSetId`（完成单调）。
  - 否则保持云端值。
- 其余 plan 字段（`goalSummary` / `coachSummary` / `days` 结构）云端胜出。

### 3.6 `mergeFromCloud(...)`（actor 方法，签名同 `replaceAll`）

```swift
func mergeFromCloud(
    profile: UserProfile,
    activePlan: TrainingPlan,
    strengthSessions: [WorkoutSession],
    runningRecords: [RunningWorkoutRecord],
    customExercises: [ExerciseDefinition],
    goalSpec: GoalSpec?
) {
    state.profile = profile                                       // 云端胜出
    state.activePlan = mergePlanPreservingCompletions(
        cloud: activePlan, local: state.activePlan)
    state.strengthSessions = mergeRecords(
        cloud: strengthSessions, local: state.strengthSessions)
    state.runningRecords = mergeRecords(
        cloud: runningRecords, local: state.runningRecords)
    state.customExercises = mergeCustomExercises(
        cloud: customExercises, local: state.customExercises)
    state.goalSpec = goalSpec                                     // 云端胜出
    // pendingEditEvents / editEventSeq 不动（EV1）
    recalculateDerivedProfile()
    try? writeStateToDisk()
    // 不调 onChange —— 与 replaceAll 一致，pull 不回声成 push
}
```

`replaceAll` 保留不动，文档注释补充"pull 路径已改用 `mergeFromCloud`，本方法仅保留给未来强制替换场景"。

### 3.7 `CloudSyncCoordinator.pull()` 改动

```swift
func pull() async {
    do {
        let snapshot = try await loader.load(userId: userId)
        await database.mergeFromCloud(           // 原 replaceAll
            profile: snapshot.profile,
            activePlan: snapshot.activePlan,
            strengthSessions: snapshot.strengthSessions,
            runningRecords: snapshot.runningRecords,
            customExercises: snapshot.customExercises,
            goalSpec: snapshot.goalSpec
        )
        lastErrorDescription = nil
    } catch {
        lastErrorDescription = "pull: \(error)"
    }
}
```

`start()` / `pull()` 文档注释更新：从"覆盖本地"改为"与本地合并（保留用户离线记录、丢弃 seed、单例云端胜出）"。

## 4. 异常点与 Corner Case

| # | 场景 | 处理 |
|---|---|---|
| M1 | 离线创建的 session/run（UUID id） | `mergeRecords` 本地-only 且 `isUserGeneratedID` → 保留；后续 push 上云 |
| M2 | seed session/run（`seed-*`） | 非 UUID id → 丢弃，云端替换（延续原始意图） |
| M3 | 同 id 冲突（云端 + 本地都有） | `updatedAt` 取新，平手云端；exercises/sets 随胜者 |
| M4 | 离线 `completePlannedSet` 打卡，同 plan.id | `mergePlanPreservingCompletions` 回填 `completedAt`/`linkedId` |
| M5 | 本地 seed 计划（`local-plan`）与云端计划 id 不同 | 云端整体胜出，seed 计划丢弃；其完成标记不回填（seed 计划本就该被替换） |
| M6 | profile 偏好离线改动 | 云端胜出，丢失；`timezone` 由 `reconcileDeviceTimezone()` 自愈 |
| M7 | goalSpec 离线改动 | 云端胜出；`goal_changed` edit event 因 EV1 幸存 |
| M8 | `pendingEditEvents` | 合并不触碰（EV1 延续） |
| M9 | pull 回声成 push | `mergeFromCloud` 不调 `onChange`，与 `replaceAll` 一致 |
| M10 | 残留别账户的本地 session/run | 极端情况同 id 冲突取 updatedAt 新者；可选防御：merge 前按 userId 过滤（本期不做，留作后续） |
| M11 | 合并后本地非计划表与云端不一致？ | 否——pull 对非计划表全量拉取，merge = 云端 ∪ 本地-only UUID，后续 push `deleteNotIn` 不会误删云端历史 |

## 5. 测试

`tests/cloud_pull_merge_test.swift`（独立 swiftc 可执行，仿 `cloud_mapper_roundtrip_test` / `local_state_decode_compat_test` 风格）：

1. **离线记录保留**：seed DB → 加 UUID session + UUID run + `custom-<uuid>` → `mergeFromCloud`（云 UUID session/run、不同 id 云计划、云 profile）→ 断言离线 session/run/custom 仍在；seed 替换；云 session/run 在；plan == 云计划；profile == 云 profile。
2. **updatedAt LWW**：同 id session，云端旧 → 本地胜；云端新 → 云端胜。
3. **seed 丢弃**：`seed-session-1` / `seed-run-1` / `local-plan` 合并后不在，云计划胜出。
4. **计划完成标记保留**：同 `plan.id`，本地 set 已完成、云端同 set 未完成 → 合并后保留；不同 `plan.id` → 不回填。
5. **goalSpec / profile 云端胜出**：等于入参。
6. **pendingEditEvents 不被触碰**：合并前后数量/内容不变。
7. **onChange 未触发**：装 flag-onChange，merge 后 flag 未置。

编译命令（写入文件头注释）：
```
swiftc -parse-as-library \
  PeakLog/Models/*.swift PeakLog/Localization/AppLanguage.swift \
  PeakLog/Support/WorkoutDateFormatter.swift \
  PeakLog/Services/LocalAppDatabase.swift \
  tests/cloud_pull_merge_test.swift -o /tmp/cpm && /tmp/cpm
```

回归：现有 `tests/*.swift` 全绿 + Xcode 编译零警告。

## 6. 实施顺序

1. [ ] `LocalAppDatabase.swift`：加 `mergeFromCloud` + 合并辅助 + `CloudMergeableRecord` + `isUserGeneratedID`。
2. [ ] `CloudSyncCoordinator.swift`：`pull()` 改调 `mergeFromCloud`，更新注释。
3. [ ] `tests/cloud_pull_merge_test.swift`：7 断言，`swiftc` 跑通。
4. [ ] 回归：现有 `tests/` 全绿。
5. [ ] Xcode 构建（iOS 26.5 / iPhone 17 Pro Max Simulator），`PEAKLOG_E2E=1` 跑 `CloudSyncE2ECheck`（可选）。
6. [ ] 日志 `docs/logs/2026-07-08-cloud-pull-merge-local.md`。
7. [ ] 询问是否提交 commit。
