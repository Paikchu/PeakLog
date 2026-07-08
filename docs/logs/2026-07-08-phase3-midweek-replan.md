# Phase 3 落地日志: 周中动态重排

关联:`docs/plans/2026-07-08-phase3-midweek-replan-plan.md`(方案)、`docs/architecture/adr-001-llm-weekly-plan-generation.md`(ADR-001 决策 #7/#8)、`docs/logs/2026-07-08-phase2-weekly-generation.md`(前置 Phase 2)

## 范围

按方案第 7 节实施顺序完整落地:migration+RPC → RPC live 验证 → 纯函数层扩展 → Edge Function 扩展 → 客户端 revision guard → 客户端一键 UI → 首次真实重排 → 行为推断接入+演练+文档。用户在启动前拍板了四点(方案 §8):三个一键信号全做、行为推断本期一并做(收窄为"整天零完成")、一键即改无预览确认、自由文本目标解析不并入本期。

## 后端:schema 与 RPC(migration `20260708000016`)

- **`plan_generations` 加 `kind`/`trigger`/`signal` 列**:区分 `weekly` 与 `replan` 生成;`trigger ∈ {user_tap, inference}`;`signal ∈ {skip_today, low_energy, time_limited}`。既有行 `kind` 回填 `weekly`,语义正确(C33)。
- **`training_plans` 加 `revision int NOT NULL DEFAULT 0`**:乐观锁计数器,重排时服务端 `+1`,客户端只读作为"服务端是否已重排"的判据。
- **`replan_plan_days(p_user_id, p_plan_id, p_days, p_expected_revision)` RPC**:单事务替换当前周若干"可重排天"的内容。SECURITY DEFINER,仅 service_role(沿用 Phase 2 的双层防护:显式 REVOKE anon/authenticated/PUBLIC + 函数内 `auth.role()` 检查——这次一开始就带上,`information_schema.routine_privileges` 核查确认 anon 无授权,无需二次修复)。

**C31 硬性不变量(数据库级,每个目标天独立复核)**:每个目标天必须 `plan_date >= 今天`(用户时区)且该天现存 sets 中不存在任何 `completed_at IS NOT NULL` 或 `linked_exercise_set_id IS NOT NULL` 的行。校验在"变更前"一次性对所有天做完,任一不满足即 `RAISE EXCEPTION` 回滚整个事务——绝不半程重排。乐观锁:`revision != p_expected_revision` → 拒绝(读取时 `FOR UPDATE` 锁行,并发重排串行化)。day 行 id 保留(只更新 title/focus,不删 day 行),避免客户端本地引用悬空;只删该天的 exercises/sets 并重插。

## 后端:纯函数层扩展(`_shared/`)

- **`validator.mjs`**:抽出 `clampDayExercises`(动作库校验、reps 范围、weighted 必须有重量、周负荷钳制)为两个 validator 共用,保证周生成与重排在"什么算不安全"上永不漂移。新增 `validateReplanDays(plan, targetDates, context)`:不再校验"恰好 7 天/daysPerWeek",改为"输出天集合 == 期望天集合"(无缺、无多、无重),安全校验完全复用。
- **`contextBuilder.mjs`**:新增 `summarizeCurrentWeekDays`(当前周逐天概览 + 每天是否已有完成组)和 `buildReplanContext`(在 `buildContext` 基础上叠加 `replan.{signal, targetDates, currentWeekOverview}`,`weekStartDate` 用当前周而非下周)。
- **`prompt.mjs`**:新增 `REPLAN_SYSTEM_PROMPT` + `REPLAN_PROMPT_VERSION='replan-v1'` + `buildReplanUserMessage`。独立 prompt 而非周生成的变体开关——任务形态差异足够大,合并会让模型把重排当成新的一周。含三信号的差异化指令(skip→休息日、low_energy→减量、time_limited→压缩至~30min)。

node 测试从 51 增至 65(新增 `validateReplanDays` 6 例、`summarizeCurrentWeekDays`/`buildReplanContext` 5 例、`prompt.test.mjs` 3 例),全绿。

## 后端:Edge Function 扩展(同一 `generate-weekly-plan`)

- **`mode: 'replan'`**:缺省 `weekly`,既有行为完全不变。
- **双路径鉴权**:`weekly` 只认 `x-generation-secret`(永不认用户 JWT——客户端永远不能触发周生成);`replan` 认 secret(运维/cron 的行为推断路径)**或**目标用户自己的 `Authorization: Bearer <JWT>`(一键路径,`auth.getUser` 解析后 uid 必须等于 `user_id`,否则 403)。
- **频控**:`plan_generations` 今日 `kind='replan'` 计数 ≥ 3 → 429,检查在任何 LLM 调用/计划查询之前。
- **重排管线**:复用 `fetchSharedFactInputs`(与周生成同一份事实装配)→ `buildReplanContext` → `generateAndValidateReplan`(repair ≤2)→ `replan_plan_days` RPC。**失败兜底与周生成不同(C24)**:repair 耗尽仍失败 → **保持原计划不动**,只写 `status='failed'` 溯源行,没有"硬造一个计划"的 fallback——原计划本身就是合法状态。
- **一键 scope**:`user_tap` 只针对今天;例外(C22)——`low_energy` 在今天已训练时自动落到明天,`skip_today`/`time_limited` 今天已训练则前端置灰+函数 no_op。
- **行为推断 scope(§3.3)**:`inference` 只重排今天**之后**的天(今天已过去,不改今天)。
- **乐观锁重试(C25)**:RPC 返回 revision mismatch 时,重读当前 revision 再试一次,再失败放弃(绝不半程写入)。
- **Agent 编辑事件(§3.2)**:重排成功后对每个被改动的天写一条 `plan_edit_events`(`source='agent'`, `event_type='agent_replan_day'`, payload 含 signal/trigger/title/动作清单)。best-effort:失败只记日志,不回滚已提交的重排。下周日的周生成上下文因此能看到完整的"用户发信号 → Agent 如何响应"链。
- **行为推断接入 cron**:既有 hourly cron 的全量 sweep(无 `user_id`、非 dry_run)在周生成之后追加 `runInferenceSweep`——对每个处于本地 21:00–23:00 且"今天是训练日且零完成且今日尚无重排"的用户,跑一次 `trigger='inference'` 重排。窗口窄(每用户每天至多命中约 2 次),配合"今日已重排"闸门收敛为至多 1 次。触发闸门(missed training day)在 sweep 层,不污染一键路径。

## 客户端

- **revision guard(§4.2,本期客户端重头)**:`TrainingPlan`/`TrainingPlanRow` 加 `revision`(向后兼容 decode:旧缓存缺键 → 0)。`TrainingPlanRow.encode` **刻意省略 revision**——merge-duplicates upsert 下省略列在冲突时被保留,故客户端 push 永不覆盖服务端 revision。`CloudSyncCoordinator.performPush` 推送前先做一次轻量单列探测(`select=revision`);服务端 revision 与本地基线不一致(说明上次 pull 后服务端重排过)→ **先 `pull()`-merge 再推**,否则子表 `deleteNotIn` 会物理删掉重排产生的新行、悄悄回退用户刚看到的调整(§4.3,这是 Phase 2 C9 的严重化版本,不可作为已知行为接受)。`mergePlanPreservingCompletions` 采纳 `cloud.revision` 作为新基线。
- **一键 UI**:`ReplanSignal` 模型(rawValue 对齐服务端);`PlanReplanService`(带用户 JWT 的 Function POST,返回 `replanned/noChange/failed` 结构化 outcome);`CloudSyncController.requestReplan`(取 token → 调 service → 成功后 `pull()` 刷新);`TodayWorkoutScreen` 在概览下方加"调整今天"菜单(三选项,`skip_today`/`time_limited` 在今天已有完成组时置灰),点击后先本地记录 `day_signal`(`source='user'`,即使函数失败也进学习闭环)再调用,成功刷新 Today、失败轻提示"计划保持不变"。全程无预览确认(一键即改)。

## 验证

**真实数据保护(硬规则不变)**:开发账号当前周有真实计划(`0c5eeb44`,唯一一天 2026-07-08「自定义训练」11 动作)。

1. **RPC live 验证(Task 2)**:一个显式事务包住全部断言、以 `ROLLBACK` 收尾(合成夹具与 revision 自增均不落库)。9 项断言全过:非当前周计划拒绝、过去天拒绝、已完成组的天拒绝、revision 不匹配拒绝;成功路径替换目标天 + revision 0→1 + `replannedDates` 正确;真实 2026-07-08 天动作数保持 3。事务外复核 revision=0、合成夹具 0 行。
2. **纯函数**:`node --test` 65/65。
3. **鉴权边界(live)**:replan 无 secret 无 JWT → 401、非法 signal → 400、缺 user_id → 400、weekly 无 secret → 401。
4. **dry_run 迭代(replan-v1 定稿)**:三信号各跑一次,人工评审——`time_limited` 把 11 动作压到 2 个(卧推+绳索下压)标题「快速训练」、`skip_today` 产出「休息日」空动作、`low_energy`/inference 行为符合预期;inference 在"只有今天一天"时正确 no_op。
5. **首次真实重排(Task 3,数据安全做法)**:不改用户真实的今天,而是往真实计划里插一个合成的**未来**天(2026-07-09)→ 跑真实 `trigger='inference'` 重排(`dry_run:false`)→ 全面 SQL 核查:真实 2026-07-08 天 md5 指纹写前写后逐字节相同(`33dc532b…`)、合成天被替换(标题→「腿部训练」、day id 稳定不变、动作换新)、revision 0→1、`agent_replan_day` 事件正确写入(source=agent、trigger=inference、动作清单)、溯源行 `kind=replan/trigger=inference/status=active` → 清理:删合成天(级联)、revision 归零、删测试溯源与 agent 事件 → 收尾核查账号恢复到测试前状态(1 天、revision 0、0 溯源、指纹不变)。
6. **失败演练**:C27 频控——连发 replan 至第 3 次起返回 `rate_limited: daily replan limit (3) reached`;C25 乐观锁——RPC 层 revision 不匹配拒绝(Task 2 已验)+ 函数层重读重试一次(代码);C24——重排 LLM 失败时**不兜底**、原计划不动、只写 failed 溯源(设计保证:RPC 仅在 `generation.ok` 时调用;Phase 2 的坏 key dry_run 已验证 LLM 失败被优雅捕获)。
7. **客户端回归**:`xcodebuild build` 全绿。

## 遗留 / 下一步

- **模拟器端到端一键走查**未做:在真实 Today 页点一键信号会对开发账号真实的"今天"计划触发真实重排(改真实数据),需在受控/可恢复前提下由人工在模拟器执行;后端全链路与数据安全已充分验证,UI 为直白 SwiftUI 且编译通过。
- **pre-existing 缺陷(与 Phase 3 无关)**:`tests/cloud_pull_merge_test.swift` 的 `testPlanCompletionPreservedWhenSamePlanId` 在干净 `main`(commit b637e5e)上已失败——`mergeFromCloud` 里 `sanitizePlanCompletionLinks` 会清掉 linkedExerciseSetId 尚未同步进 session 的离线完成标记,与 Issue #1 的"离线完成应存活"矛盾。已开独立 task 单独修,不阻塞本期。
- **行为推断真实无人值守运行**尚未经历一次真正的晚间窗口自动触发(开发账号当前周只有今天一天,inference 恒 no_op);需要一个有未来训练日的周来实测。
- Phase 3 明确不做:RPE 量表、自由文本目标解析(与重排正交,单独排期)、指标看板。
