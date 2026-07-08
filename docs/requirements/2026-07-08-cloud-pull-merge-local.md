# 修复：登录后云端拉取覆盖本地数据导致记录丢失（Issue #1）

## 背景

GitHub Issue #1（`[High] 登录后 pull() 整体覆盖本地数据导致记录丢失`）报告：用户在 DEBUG / local / 离线模式下创建的训练记录，一旦登录即被云端快照整体替换而丢失。

根因在 `CloudSyncCoordinator.start()` → `pull()` → `LocalAppDatabase.replaceAll(...)`：登录后无条件用云端快照覆盖本地全部状态，没有任何本地→云端的合并。原始设计意图是"先 pull 覆盖 seed/陈旧缓存，避免后续 push 把非云端行（seed、非 UUID id）推上去"——意图正确，但过度纠正，把合法的离线用户数据也一并清掉。详见 `docs/logs/code-review-20260708.md` 优先修复清单 #2。

## 需求

1. 登录首次拉取云端数据时，**保留用户在离线 / DEBUG local 模式下创建的训练记录**，包括：
   - 力量训练 session（含其 exercises / sets）
   - 跑步记录（running records）
   - 自定义动作（custom exercises）
2. **丢弃 seed 数据**：本地种子行（`local-plan` / `seed-session-1` / `seed-run-1` / `plan-day-N` / `plan-ex-N` / `plan-set-N` / `local-user` 等非 UUID id）继续由云端真理替换——延续原始"pull-first 覆盖 seed"意图，避免 seed 污染云端。
3. **同 id 冲突按 `updatedAt` 取新**（仅 `WorkoutSession` / `RunningWorkoutRecord` 有时间戳）：云端与本地同 id 时，以 `updatedAt` 较新者为准，平手取云端。
4. **保留离线计划组完成标记**：当本地计划 id 与云端计划 id 相同时，离线状态下用 `completePlannedSet` 打的完成标记（`completedAt` / `linkedExerciseSetId`）不被云端未完成状态覆盖（完成是单调的，任一侧已完成即视为完成）。本地为 seed/local 计划（id 不同于云端）时，云端计划整体胜出。
5. **单例状态云端胜出**：`profile`（含偏好）与 `goalSpec` 状态以云端为准。离线偏好改动会丢失，但 `timezone` 由登录后 `reconcileDeviceTimezone()` 自愈，其余偏好可重设；`goalSpec` 的 `goal_changed` 编辑事件因 EV1 已幸存，不阻断 Phase-2 学习闭环。
6. **不破坏既有不变量**：`pendingEditEvents` / `editEventSeq` 不被合并触碰（EV1 延续）；合并不触发 `onChange`（避免 pull 回声成 push）。
7. **Agent-native 约束边界**：合并逻辑为确定性数据层代码（云同步冲突解决无法交给 prompt 控制），不在 AGENTS.md "不硬编码条件 / 不表达式匹配"约束范围内（该约束针对 AI/Agent 行为层）。

## 验收方案

- **单元测试（`tests/cloud_pull_merge_test.swift`，`swiftc` 直跑）** 覆盖：
  1. 离线创建的 UUID session / run / custom 动作在 `mergeFromCloud` 后仍在；seed session / run 被云端替换；云端 session / run 在；plan == 云计划；profile == 云 profile。
  2. 同 id session：云端 `updatedAt` 较旧 → 本地胜出；云端较新 → 云端胜出。
  3. seed 行（`seed-session-1` / `seed-run-1` / `local-plan`）合并后不在，云计划胜出。
  4. 同 `plan.id` 下离线完成的 `planSet`，合并后 `completedAt` / `linkedExerciseSetId` 保留；不同 `plan.id` → 云端胜出、不回填。
  5. `goalSpec` / `profile` 等于入参（云端胜出）。
  6. `pendingEditEvents` 合并前后数量/内容不变（EV1）。
  7. 合并不触发 `onChange`（避免回声 push）。
- **回归门**：现有 `tests/*.swift` 全绿（`cloud_mapper_roundtrip_test` / `local_state_decode_compat_test` / `plan_edit_event_recording_test` 等）+ Xcode 编译零警告。
- **端到端（可选，DEBUG-only `PEAKLOG_E2E=1`）**：local 模式建一条 running record → 登录 → 记录仍在本地且已上云（独立 client 读回）。
- **模拟器手动验证（iPhone 17 Pro Max, iOS 26.5）**：DEBUG local 模式创建力量 session + 跑步记录 + 改偏好 → 登录 → 训练记录与 custom 动作仍在 → 云端确认已同步 → 登出再登入幂等不丢、不重复。
