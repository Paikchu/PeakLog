# 修复日志：登录后云端拉取覆盖本地数据导致记录丢失（Issue #1）

- **日期**：2026-07-08
- **分支**：`codex/fix-cloud-pull-merge-local`
- **Issue**：https://github.com/Paikchu/PeakLog/issues/1（`[High] 登录后 pull() 整体覆盖本地数据导致记录丢失`）
- **对应文档**：`docs/requirements/2026-07-08-cloud-pull-merge-local.md`、`docs/plans/2026-07-08-cloud-pull-merge-local-plan.md`
- **代码审查报告**：`docs/logs/code-review-20260708.md` 优先修复清单 #2

## 背景

登录后 `CloudSyncCoordinator.start()` → `pull()` → `LocalAppDatabase.replaceAll(...)` 用云端快照**无条件整体覆盖**本地全部状态。用户在 DEBUG / local / 离线模式下创建的训练记录（力量 session、跑步记录、自定义动作、计划组完成标记、偏好/目标改动）登录瞬间丢失。原始设计意图是"先 pull 覆盖 seed/陈旧缓存避免 seed 上云"，但过度纠正，把合法离线用户数据也清掉。只有 `pendingEditEvents` / `editEventSeq` 因 EV1 设计幸存。

## 根因

- `CloudSyncCoordinator.swift:46-49, 67-82`：`pull()` 调 `replaceAll`，无本地→云端合并。
- `LocalAppDatabase.swift:1036-1052`：`replaceAll` 整体覆盖 `profile` / `activePlan` / `strengthSessions` / `runningRecords` / `customExercises` / `goalSpec`。

## 修复方案：本地保留式合并（mergeFromCloud）

新增 `LocalAppDatabase.mergeFromCloud(...)`（签名同 `replaceAll`），`pull()` 改调它。逐表合并策略：

| 表 | 策略 |
|---|---|
| `strengthSessions` / `runningRecords` | 云端为准；同 id 按 `updatedAt` 取新（平手云端）；保留本地-only 且为用户创建（UUID id）的行；丢弃 seed（非 UUID id）。 |
| `customExercises` | 云端为准；保留本地-only 用户创建（`custom-<uuid>`）；同 id 平手云端。 |
| `activePlan` | 云端结构胜出；`cloud.id == local.id` 时回填离线 `completedAt` / `linkedExerciseSetId`（完成单调）；不同 id 云端整体胜出。 |
| `profile` / `goalSpec` | 云端胜出（确认决策；timezone 由 `reconcileDeviceTimezone` 自愈）。 |
| `pendingEditEvents` / `editEventSeq` | 不动（EV1 延续）。 |

判据：`String.isUserGeneratedID`——剥去 `custom-` 前缀后 `UUID(uuidString:)` 可解析即用户创建，否则视为 seed/legacy 丢弃。合并辅助 `CloudMergeableRecord` 协议（`WorkoutSession` / `RunningWorkoutRecord` conform）、`mergeRecords`、`mergeCustomExercises`、`mergePlanPreservingCompletions`。

合并不触发 `onChange`（与 `replaceAll` 一致），pull 不会回声成 push。

## 改动文件

| 文件 | 改动 |
|---|---|
| `PeakLog/Services/LocalAppDatabase.swift` | 新增 `mergeFromCloud` + 合并辅助 + `CloudMergeableRecord` 协议 + `isUserGeneratedID`；`replaceAll` 文档注释补充说明。 |
| `PeakLog/Services/Cloud/CloudSyncCoordinator.swift` | `pull()` 改调 `mergeFromCloud`；`start()` / `pull()` 注释更新为"合并"语义。 |
| `tests/cloud_pull_merge_test.swift` | 新增逻辑测试（7 断言点）。 |
| `docs/requirements/2026-07-08-cloud-pull-merge-local.md` | 新增需求文档。 |
| `docs/plans/2026-07-08-cloud-pull-merge-local-plan.md` | 新增技术方案。 |

## 验证

- **单元测试 `tests/cloud_pull_merge_test.swift`**（`swiftc` 直跑，全绿）：
  1. 离线 UUID session/run/custom 合并后仍在；seed 行（`seed-session-1` / `seed-run-1` / `local-plan`）被丢弃；云 session/run/custom 在；plan/profile/goalSpec 云端胜出。
  2. 同 id `updatedAt` LWW：本地较新→本地胜；云端较新→云端胜。
  3. seed 计划 `local-plan` 被云计划替换。
  4. 同 `plan.id` 离线完成标记（`completedAt` / `linkedExerciseSetId`）保留，云计划结构字段仍胜出。
  5. 不同 `plan.id` 云端整体胜出，不回填完成标记。
  6. `pendingEditEvents` 合并前后不变（EV1）。
  7. `mergeFromCloud` 不触发 `onChange`（无 pull→push 回声）。
- **回归**：`plan_edit_event_recording_test`（9 events，replaceAll + EV1）、`cloud_mapper_roundtrip_test`、`local_state_decode_compat_test` 全绿，无回归。
- **Xcode 构建**：iOS 26.5 / iPhone 17 Pro Max Simulator 构建通过（见下方构建结果）。

## 已知限制 / 后续

- profile 偏好离线改动丢失（云端胜出，确认决策）；若需保留，后续加"离线脏标记"另立需求。
- `goalSpec` 状态云端胜出；`goal_changed` edit event 因 EV1 幸存，不阻断 Phase-2。
- 残留别账户的本地 session/run：合并按 id + updatedAt 处理；可选防御性按 userId 过滤（本期未做）。
