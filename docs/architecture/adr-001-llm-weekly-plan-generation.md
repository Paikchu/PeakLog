# ADR-001: LLM 驱动的每周训练计划自动生成

**Status:** Accepted
**Date:** 2026-07-07
**Deciders:** Max

## 1. Context

PeakLog 当前是纯本地运行的 iOS App:

- 所有数据(profile、当前周计划、力量训练、跑步记录、自定义动作)由 `LocalAppDatabase` 持久化在单个本地 JSON 文件中,没有任何数据同步到线上。
- 后端 Supabase 项目(`fqyurmsuvtdafbnynurg`)已有完整 schema 和已部署的 Edge Functions(`ai-workout-action`,含 DeepSeek key),但 App 端 Supabase SDK 已在 2026-04 的本地化迁移中移除,登录处于临时跳过状态。
- 计划生成目前是静态模板:修改 `fitnessGoalSummary` 时 `rebuildPlan` 套模板重建周计划,不参考任何历史数据。
- 已有可复用资产:`TrainingPlanSet.linkedExerciseSetId` 提供了"计划组 ↔ 实际训练组"的关联;`ExerciseRecommendationEngine` 编码了肌群恢复天数规则。

目标:系统自动为用户生成训练计划、自动预设动作重量,并根据用户的实际训练与对计划的修改逐周优化;考虑休息日与科学的渐进超负荷;检测到状态不好或突发情况时能动态调整。产品明确不做聊天界面——AI 在背后做事。

## 2. Decision

1. **计划按周一次性生成**:每周末由云端定时任务生成用户下一整周(7 天)的计划,而不是逐日生成。
2. **LLM 是唯一的决策者,确定性代码退居两块"薄层"**:
   - **ContextBuilder(LLM 调用前,确定性)**:把原始数据汇总成事实——每个动作的实际完成情况、达标率、e1RM 趋势、本周编辑事件流、依从率、GoalSpec,以及每个动作预先算好的"参考下一步重量"(LLM 可采纳可推翻)。
   - **Validator(LLM 调用后,确定性)**:只做安全校验,不做策略——动作名必须在动作库中、单周加重幅度钳制(≤ 上周实际的 110%)、schema 完整性、天数与 GoalSpec 一致。校验失败带违规项重新请求 LLM(repair loop)。
   - 训练学知识(分化、恢复、deload、渐进超负荷)全部放在 Agent 的 system prompt 中,改 prompt 即可升级,不需要发版。
3. **LLM 使用云端模型**(现有 DeepSeek Edge Function 通道,后续可换),不用端侧 Foundation Models 做生成主链路。
4. **生成链路整体放在服务端**:Supabase Edge Function + pg_cron 定时任务,生成结果写入 `training_plan_*` 表,客户端同步下来展示。客户端职责收敛为"展示 + 记录 + 同步"。本地 `rebuildPlan` 模板逻辑废弃。
5. **用户对计划的修改记录为事件流(`PlanEditEvent`)**:删/换/加动作、改重量次数,带时间戳逐条记录,而不是只保存修改后的结果。编辑事件是下一周生成的最重要原料。
6. **每份生成的计划带溯源(provenance)**:保存 prompt 上下文快照、模型与 prompt 版本。坏计划可定位原因,prompt 改动可对比效果。
7. **周中动态重排**:复用同一条生成 pipeline,scope 缩小为"本周剩余天"。触发来源两个:行为推断(当天完成率显著缩水/整天未训练,当晚自动重排)兜底,Today 页一键结构化输入("跳过今天/状态不好/时间有限")优先。不是聊天,是按钮级事件。
8. **主观反馈(RPE 等)本期不做**,但一键输入入口的设计为其预留扩展位。

## 3. Options Considered

### Option A: 确定性规则引擎为主,LLM 只做目标解析与文案

| Dimension | Assessment |
|-----------|------------|
| Complexity | 中(规则可测试,但规则集会持续膨胀) |
| Cost | 极低(几乎无 LLM 调用) |
| 可解释性/可复现性 | 高 |
| 扩展空间 | 低——策略写死在代码里,长尾场景(状态不好、出差、伤病)无法枚举 |

**Pros:** 数字绝对可靠;离线可用;免费。
**Cons:** 天花板低;每类新场景都要写代码发版;"教练感"弱。

### Option B: LLM 直接生成每日课表(无确定性层)

| Dimension | Assessment |
|-----------|------------|
| Complexity | 低(实现最快) |
| Cost | 中(每天每用户一次调用) |
| 可靠性 | 低——进阶算术漂移、幻觉动作、同输入不同输出 |
| 扩展空间 | 高 |

**Pros:** 最灵活;实现最少。
**Cons:** 重量数字不可靠会直接伤害训练安全与信任;不可复现,难以调试"为什么排了这个计划"。

### Option C(选定): LLM 决策 + 前后两块确定性薄层,按周生成

| Dimension | Assessment |
|-----------|------------|
| Complexity | 中 |
| Cost | 低(每用户每周 1 次调用 + 少量周中重排) |
| 可靠性 | 高——算术由代码预计算,输出经 Validator 钳制 |
| 扩展空间 | 高——策略全在 prompt,薄层不含训练学 |

**Pros:** 兼得灵活性与数字可靠性;计划可溯源可复现;成本可忽略。
**Cons:** 需要维护 ContextBuilder/Validator 两块代码;依赖网络与云端(离线时无法生成,但计划提前一晚生成好,实际影响小)。

### 其他已决策的子选项

- **端侧 Foundation Models vs 云端 LLM**:选云端。端侧受 Apple Intelligence 设备条件限制、解析质量不稳,且生成链路在服务端后端侧调用更自然。
- **逐日生成 vs 周骨架+日微调 vs 整周一次性生成**:选整周一次性生成。与现有 `TrainingPlan`(7 天)数据模型吻合,用户可预览整周,周中变化用事件触发的重排覆盖。

## 4. Trade-off Analysis

核心取舍是**把 LLM 的自由度限制在"策略"层,把"数字"层交给代码**:

- LLM 拿到的是预计算的事实与参考值,输出的是结构化整周计划(JSON schema + 每动作 reasoning 字段);它可以决定 deload、换动作、压缩课表,但不需要自己做加法。
- Validator 是安全网不是策略层:它挡住幻觉动作和离谱加重,但绝不改写 LLM 的编排意图。
- 由此,"系统逐渐优化"不依赖任何模型训练:信号(编辑事件、达标情况、依从率)进入下一次生成的上下文,坏输出被钳制,prompt 迭代靠溯源数据评估。

## 5. Consequences

**变容易的:**

- 新场景(伤病、器械受限、出差)只需扩展上下文与 prompt,不写规则代码。
- 每份计划可回答"为什么是这个重量"——参考值来自确定性计算,采纳与否有 reasoning。
- 教练周报(Agent 每次生成/调整附带的人话理由)自然产出,替代聊天成为"AI 在背后做事"的可见面。

**变难/新增的负担:**

- **云同步与登录成为硬前置**(Phase 0):生成在服务端,数据必须在线上。
- 客户端要把所有计划编辑改为事件记录(`PlanEditEvent`)。
- 需要维护 prompt 版本与生成溯源数据。
- 离线时无法触发重排(已生成的周计划仍可离线查看与执行)。

**需要回头看的:**

- 冷启动(第一周)质量:只有 GoalSpec 没有历史,起始重量策略是"宁低勿高,让用户往上改",第一周编辑率预期很高,需观察第二周是否显著下降。
- 三个北极星指标:**依从率**(按计划完成的组占比)、**编辑率**(随周数下降 = 系统在变好)、**进阶速度**(主项 e1RM 斜率)。Agent 周复盘与产品评估共用这三个数。
- DeepSeek 的 structured output 质量;必要时更换模型只影响 Edge Function 内一处调用。

## 6. Action Items

1. [x] **Phase 0 — 登录 + 云同步**(关键路径,详见 `docs/plans/2026-07-07-phase0-auth-sync-plan.md`;落地日志 `docs/logs/2026-07-07-phase0-*.md`)
2. [x] **Phase 1 — 事件与溯源基建**:客户端 `PlanEditEvent` 记录;后端 `plan_edit_events`、`plan_generations` 表;GoalSpec 模型与录入 UI(日志 `docs/logs/2026-07-08-phase1-edit-events-goalspec-generations.md`)
3. [x] **Phase 2 — 周生成主链路**:ContextBuilder + 生成 Edge Function + Validator + repair loop + pg_cron 周日晚任务(日志 `docs/logs/2026-07-08-phase2-weekly-generation.md`)
4. [x] **Phase 3 — 周中动态重排**:行为推断触发 + Today 页一键输入触发(日志 `docs/logs/2026-07-08-phase3-midweek-replan.md`)
5. [ ] 指标看板:依从率/编辑率/进阶速度的最小统计(另立项,未排期)
