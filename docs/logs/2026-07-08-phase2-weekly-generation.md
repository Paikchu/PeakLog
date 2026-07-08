# Phase 2 落地日志: LLM 周计划生成主链路

关联:`docs/plans/2026-07-08-phase2-weekly-generation-plan.md`(方案)、`docs/architecture/adr-001-llm-weekly-plan-generation.md`(ADR-001)、`docs/logs/2026-07-08-phase1-edit-events-goalspec-generations.md`(前置 Phase 1)

## 范围

按方案第 7 节实施顺序完整落地:共享纯函数层 → 客户端两处小改 → RPC+migration → Edge Function 部署与 dry_run 迭代 → 首次真实生成 → 接通 cron → 失败演练与文档。用户在启动前拍板了四点(见方案 §8):DeepSeek 自行配置 key、生成绝不碰当前周/历史周(已落地为 C21 数据库级不变量)、休息日空动作+标题、全程零 UI 零交互。

## 后端:共享纯函数层(`backend/supabase/functions/_shared/`)

四个模块,`node --test` 与 Deno 运行时共用同一份源码(纯函数,不碰 `Deno.*`/网络):

- **`referenceWeight.mjs`**:double progression 算术——全达标 → barbell/machine/cable +2.5kg、dumbbell/kettlebell +2kg;连续两次未达标 → -10% deload;`loadType=bodyweight` → 建议加次数(+1 或 +2)而非加重(C18);无历史 → 保持。
- **`validator.mjs`**:动作 id 必须 ∈ 库(种子∪custom);周负荷钳制(有历史 ≤ 上次实际×1.10,无历史但有同名 e1RM 参考 ≤ 参考×0.9,否则不设上限);schema 校验(7 天连续日期、训练日数匹配 `daysPerWeek`、reps∈[1,30]、weighted 动作必须有重量)。钳制记 verdict 不算违规,结构性问题才进 repair loop。
- **`contextBuilder.mjs`**:装配 LLM 所需事实 JSON——依从率、按动作分组的达标历史(含 e1RM 序列,Epley 公式)、参考下一步重量、编辑事件摘要、GoalSpec 投影、动作库投影(135 条种子 + custom)。`buildExerciseHistory` 要求调用方传入按周从旧到新排序的行,内部反转为最近优先。
- **`llm.mjs`**:DeepSeek adapter(`deepseek-chat`,60s 超时,失败重试 1 次);`LlmError` 区分可重试(网络/5xx)与不可重试(缺 key/4xx/JSON 解析失败)。
- **`prompt.mjs`**:`PROMPT_VERSION='v1'` + system prompt(训练学原则、输出 JSON schema 契约)。

`backend/tests/*.test.mjs` 共 51 个用例全绿(`node --test tests/*.test.mjs`)。

## 后端:RPC 与调度基建

**`install_generated_plan(p_user_id, p_plan)`**(migration `20260708000013`):单事务写整周 `training_plan_days/exercises/sets`(`status='active'`),同事务惰性归档该用户 `week_start_date < 本周一` 的旧 active 计划(只改 `status`,不碰内容)。`SECURITY DEFINER`,仅 `service_role`。

**实施中发现并修复的真实安全缺陷**:首次应用后用 `information_schema.routine_privileges` 核查,发现 `anon` 角色持有该函数的 EXECUTE 权限——尽管迁移里写了 `REVOKE ALL ... FROM PUBLIC`。原因是该项目 public schema 新建函数会给 `anon` 一个默认授权,不经过 PUBLIC 继承,因此 `REVOKE ... FROM PUBLIC` 拦不住。这对一个信任 `p_user_id` 参数、内部无鉴权的 `SECURITY DEFINER` 函数而言,意味着未登录请求本可以为任意用户写入计划。修复两层:显式 `REVOKE ... FROM anon`,以及函数内部加 `auth.role() IS DISTINCT FROM 'service_role'` 检查作为纵深防御,即便未来某次迁移的授权语句又写错也不会静默复发。真实 HTTP 边界验证:匿名请求与已登录用户自己的 token 均返回 401/403。第二个 RPC(`check_generation_secret`)从一开始就应用了同样的模式,一次性验证通过,无需二次修复。

**`check_generation_secret(candidate)`**(migration `20260708000014`):cron→函数鉴权,读 Vault 存的 `generation_secret`,同样的 SECURITY DEFINER + `auth.role()` + 显式 REVOKE 模式。设计动机:MCP 没有设置 Edge Function secret 的工具,因此鉴权机制完全不依赖任何手工配置的函数环境变量——`generation_secret` 由迁移用 `vault.create_secret` + `gen_random_bytes` 自动生成,函数用自带的 service_role 客户端调用这个 RPC 校验请求头。用户全程唯一需要手动配置的只有 `DEEPSEEK_API_KEY`。

**pg_cron 调度**(migration `20260708000015`,部署验证后才应用,遵循"启用基建"与"打开流量"分两步的原则):`generate-weekly-plan-hourly`,`0 * * * *`,通过 `pg_net.http_post` 携带从 Vault 现读的 `x-generation-secret`。每小时一次足以覆盖所有时区的"周日 20:00 本地"窗口,函数内部自行判断是否到点。

## 后端:`generate-weekly-plan` Edge Function

`index.ts`(~480 行)+ 打包的 6 个 `_shared/*.mjs`(含从 `PeakLog/Resources/exercise_library.json` 生成的 `exerciseLibrary.mjs`,保持与客户端动作库一致,C12)。核心流程:鉴权(`x-generation-secret` 或 service_role JWT)→ 选人(全量模式按时区窗口 + 下周计划不存在;`user_id` 定点模式跳过窗口判断,供开发调试)→ ContextBuilder → LLM(带 repair loop)→ Validator → `install_generated_plan` / dry_run 写 `plan_generations(status='draft')`。

## 验证

**原则延续 Phase 0/1**:开发账号云端有真实训练数据,全程验证走 `dry_run` 优先、真实安装用 `user_id` 定点触发,不做整表清除。

1. **部署与鉴权边界**:真实 HTTP 测试——缺 `x-generation-secret` 头、错误密钥值均返回 `401`。
2. **dry_run 迭代(prompt v1 定稿)**:
   - 第一轮:`DEEPSEEK_API_KEY` 已配置但值无效,DeepSeek 返回真实 `401 Authentication Fails`——管线正确捕获并走 C2 fallback(`engine='fallback_repeat'`),正确写 `plan_generations(status='draft')`,未触碰 `training_plans`。这本身验证了失败兜底路径在真实故障下工作正常。
   - 用户更新 key 后第二轮:DeepSeek 真实返回,`engine='llm'`,`verdictCount=0`(结构与钳制全部通过,无需 repair)。人工评审输出:7 天结构正确、3 个训练日匹配 `daysPerWeek=3`、休息日空动作+标题、动作 id 全部有效、初学者保守起始重量、`coach_summary` 中文解说得体说明"第一周保守起步、不超过 10% 增幅"。判定 prompt v1 可用,未再迭代。
3. **首次真实安装**(`user_id` 定点,`dry_run:false`):`status='installed'`,`weekStartDate='2026-07-13'`,`archivedCount=0`(当时无早于当前周的旧 active 计划,符合预期)。SQL 核查:7 天/day_index/日期连续正确;逐动作逐组核对与 LLM 原始输出(`raw_response`)完全一致(曾误判一处"14 组 vs 期望 15 组"的差异,核实后是 LLM 当次真实只给 plank 开了 2 组而非 3 组,并非写入 bug)。当前周(`2026-07-06`)全程 `training_plan_exercises` 行数保持 3,未被触碰。
4. **客户端周一切换逻辑**(SQL 模拟 `CloudSnapshotLoader` 的确切过滤条件):`week_start_date <= 2026-07-08` 选中 `2026-07-06`(当前周);`week_start_date <= 2026-07-13` 选中 `2026-07-13`(下周)——确认零"激活"状态机、纯日期驱动的自动切换按设计工作。
5. **C21 硬约束专项验证**(方案 §6-4 要求的必做项):直接调用 `install_generated_plan` 分别传入当前周(`2026-07-06`)和过去一周(`2026-06-29`)的 `weekStartDate`,两次均触发 `RAISE EXCEPTION`(`23514 refusing to install a plan for the current or a past week`),事务整体回滚;事后核查 `training_plans` 仍精确是 2 行(当前周+已安装的下周),当前周 `training_plan_days` 行数未变——确认该不变量在数据库层真实生效,不依赖调用方是否算对目标周。
6. **C5 重复生成幂等演练**:对已有下周计划的用户再次触发(`dry_run:false`),函数返回 `status='skipped', reason='plan already exists for target week'`;核查 `plan_generations` 行数未增加(跳过判断发生在任何 LLM 调用之前,不浪费 API 成本),`training_plans` 无重复行。
7. **窗口关闭时的 cron 式调用**:不带 `user_id` 的全量调用(模拟 cron 触发),当天是周三,返回 `results: []`——确认时区窗口判断在真实数据库全体用户上正确生效为空操作,无 LLM 调用、无写入。

## 遗留 / 下一步

- pg_cron 已挂载并激活(`jobid=1`,`0 * * * *`),但截至本次实施完成时尚未经历一次真实的"周日 20:00 自动触发"的完整无人值守运行——下一个周日需要人工核查一次 `cron.job_run_details` 与该用户的 `plan_generations`/`training_plans`,确认自动化路径与本次人工定点触发路径行为一致。
- Phase 2 明确不做的部分(周中动态重排、自由文本目标解析、指标看板、独立教练周报 UI、多 LLM 投票)见方案 §1"明确不做",留给 Phase 3。
- `DEEPSEEK_API_KEY` 目前是项目级 Edge Function secret(所有函数共享),如未来接入第二个需要不同 LLM 凭证的函数需注意隔离。
