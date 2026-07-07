# Phase 1 落地日志: 编辑事件流 + GoalSpec + 生成溯源基建

关联:`docs/plans/2026-07-08-phase1-edit-events-goalspec-plan.md`(方案)、`docs/architecture/adr-001-llm-weekly-plan-generation.md`(ADR-001)

## 范围

按方案第 7 节实施顺序完整落地:后端三表 → 客户端模型与事件记录收口 → 同步集成(含 SY1/SY2 修复) → GoalSpec 录入 UI → 测试与 live 验证 → 文档。用户在启动前拍板了三点:完成组不计入编辑事件、GoalSpec 保留全部七个字段(含 `experience`/`focusAreas`)、事件软上限 5000 丢最旧可接受。

## 后端(migration `20260708000012_phase1_events_goalspec_generations.sql`,已应用到 `fqyurmsuvtdafbnynurg`)

三张新表,已用 SY5 核对法(全表列名 vs Swift DTO 逐字段核对)确认零漂移:

- **`user_goal_specs`**:PK 即 `user_id`(不是独立 id)。这个设计决策直接吸取 Phase 0 的两个教训——避开了 `profiles`(无 INSERT 策略)和 `user_preferences`(唯一键≠PK)分别踩过的坑,upsert 的冲突键天然就是 PK。
- **`plan_edit_events`**:只有 INSERT+SELECT 策略,刻意不给 UPDATE/DELETE——不可篡改由 RLS 在服务端强制。`source` 字段(user/agent/system)为 Phase 2 预留:Agent 改计划时必须标记 `agent`,否则学习信号自我污染。
- **`plan_generations`**:客户端只有 SELECT,刻意不给 INSERT/UPDATE——写入方是 Phase 2 的服务端生成函数(service_role)。

## 客户端

- **新模型**:`GoalSpec`/`GoalObjective`/`ExperienceLevel`(Models/GoalSpec.swift)、`PlanEditEvent`/`PlanEditEventType`/`PlanEditEventSource`(Models/PlanEditEvent.swift)、`JSONValue`(Models/JSONValue.swift,jsonb 载荷的最小递归 JSON 表示)。
- **`LocalAppState` 扩展**:`goalSpec: GoalSpec?`、`pendingEditEvents: [PlanEditEvent]`、`editEventSeq: Int64`,全部 `decodeIfPresent` 向后兼容。
- **事件记录收口**:在 `LocalAppDatabase` 内部(唯一的 mutation 收口)为 `addPlannedExercises`/`deletePlannedExercise`/`addPlannedSet`/`deletePlannedSet`/`updatePlannedSet`/`reorderPlannedExercises`/`updateFitnessGoalSummary`/新增的 `updateGoalSpec` 各自记录对应事件;`completePlannedSet` **不**记录(执行数据已由 `completedAt`/`linkedExerciseSetId` 完整承载)。
- **`armCloudSync(userId:onChange:)` 替代 `setOnChange`**:钩子安装与事件记录开关合一,且在 arm 时丢弃 `userId` 不匹配的残留事件(EV9 防护)。
- **`updateGoalSpec` 不重建计划**:区别于 `updateFitnessGoalSummary` 的旧行为,结构化目标变更不触发 `rebuildPlan`(G4)。

## 同步集成与两个架构修复

- `CloudRows`/`CloudMapper` 新增 `GoalSpecRow`/`PlanEditEventRow` 双向映射;`CloudPushBundle`/`LocalDataSnapshot` 相应扩展。
- 事件表用 `insertIgnoringDuplicates`(`Prefer: resolution=ignore-duplicates`)而非 upsert——`plan_edit_events` 只有 INSERT 权限,`ON CONFLICT DO UPDATE` 需要 UPDATE 权限即便从不触发冲突;`DO NOTHING` 只需 INSERT。
- **SY1 修复(本期发现的真实缺陷)**:`training_plans` 不再进入 `deleteNotIn` 剪除清单——原实现会在每次计划轮换后的推送中删掉上一周的计划,Phase 2 的学习闭环将失去全部历史原料。
- **SY2 修复**:三张计划子表(days/exercises/sets)的剪除与**拉取**都加上 `plan_id=eq.<活跃计划>` 范围限定——否则轮换后归档周的子行会在下次拉取时被错误拼进 `activePlan`。`CloudSnapshotLoader` 相应改为先拉 `training_plans` 拿到活跃 id,再并发拉取 scoped 的子表。

## GoalSpec 编辑 UI

`GoalSpecEditorScreen`(Views/Profile/):目标类型/训练经验单选 chips,器械/重点部位多选 chips,天数/时长步进器,备注 `TextEditor`。首次打开(从未存过结构化目标)时把旧的自由文本 `fitnessGoalSummary` 预填进备注(G1)。`ProfileScreen.goalSection` 新增入口行,`ProfileViewModel` 新增 `loadGoalSpec`/`saveGoalSpec`。`ProfileServiceProtocol` 新增 `fetchGoalSpec`/`updateGoalSpec`,同步更新了唯一的 mock 实现(`tests/localization_manager_test.swift` 的 `RecordingProfileService`)。

## 验证

**原则延续 Phase 0 教训**:开发账号云端有用户真实训练数据(1 计划/3 动作/11 组/1 次训练记录),全程验证只做定点行操作,不对该账号做任何 `keepIds: []` 整表清除。

1. **Schema/DTO 核对(SY5)**:三张新表列名与 Swift DTO 逐字段核对,零漂移。
2. **逻辑测试**(swiftc,均 passed):
   - `tests/goal_spec_mapping_test.swift`:校验边界(1–7 天、15–240 分钟)+ GoalSpec↔Row 双向映射 + 未知枚举值安全回退默认值。
   - `tests/plan_edit_event_recording_test.swift`:7 种 mutation 各自产生正确的事件类型与 payload(含 before/after 快照校验);`completePlannedSet` 不产生事件;`client_seq` 严格递增且唯一;`replaceAll` 保留 pending 事件(EV1);`armCloudSync` 换账号丢弃异主事件(EV9)。
   - `tests/local_state_decode_compat_test.swift` 新增用例:剥离 `pendingEditEvents`/`editEventSeq` 键的老文件正常加载、默认值正确、序号从 0 重新计数(SY4)。
   - `tests/cloud_mapper_roundtrip_test.swift`(Phase 0 遗留测试,因签名变更而破损)已修复并扩展覆盖 goalSpec/编辑事件的完整往返。
3. **Live 真实网络验证**(真实登录 + 真实 RLS):
   - `plan_edit_events`:插入带标记事件 → 读回 → 尝试 UPDATE/DELETE 均返回 `204`(**不是** 403——PostgREST 对无匹配策略的 UPDATE/DELETE 静默 0 行成功,而非报错;必须核查行内容才能确认真正未被修改,已核查确认行完全未变)→ 用 MCP(service_role)定点清理。
   - `user_goal_specs`:同一账号 upsert 两次不同的值 → 确认单行、第二次的值生效、全程无 409/403,验证了 PK=user_id 的设计。
   - `plan_generations`:客户端 insert 确认 `403 RLS violation`(SY6)。
   - **SY1/SY2 端到端**(最关键的一项):用 MCP 造一个 `status=archived` 的假历史计划 + day/exercise/set(打了 `ARCHIVED_TEST_MARKER` 标记)→ 用真实 `CloudSyncCoordinator` 对当前登录账号跑一次真实 `pull()`——确认拉下来的 `activePlan` 只有真实的活跃计划(1 天 3 动作),不含归档标记(SY2 拉取范围限定生效)→ 再跑一次真实 `requestPush()`——事后核查:归档计划及其全部子行原封不动存活(SY1 生效,`total_plans` 仍为 2),用户真实的活跃计划数据也分毫未变 → 清理假数据。
   - 收尾核查全部相关表(`plan_edit_events`/`user_goal_specs`/`plan_generations` 均 0 行,活跃计划保持 1/1/3/11)确认账号状态与用户真实使用后的状态完全一致。
4. **全量回归**:`xcodebuild build`/`test` 全绿;额外扫描确认没有其他独立 `tests/*.swift` 脚本因本次签名变更而静默失效(`xcodebuild test` 不会跑到这些脚本,必须逐一手工核实)。
5. **真实 UI 交互验证**(computer-use 操作 Simulator,DEBUG 本地模式):`GoalSpecEditorScreen` 完整走查——单选/多选 chips、步进器、G1 预填备注全部正确渲染与交互;保存后 Profile 导航行即时反映新目标类型;关闭重开编辑器确认全部七个字段(目标类型/天数/时长/器械/部位/经验/备注)精确持久化。

## 遗留 / 下一步

- 事件软上限 5000 丢最旧的具体计数逻辑做了代码审查但未做大规模压力测试(需要连续 5000+ 次 mutation,权衡后判断风险低、跳过)。
- 下一步进入 ADR-001 Phase 2:服务端 ContextBuilder → LLM → Validator 生成管线,消费本期建好的 GoalSpec / 编辑事件流 / 计划溯源三张地基表。
