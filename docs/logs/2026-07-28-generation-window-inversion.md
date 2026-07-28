# 周计划生成窗口判断反了：修正为「仅本地周日 20:00–23:59」

## 缺陷

`generate-weekly-plan/index.ts` 的窗口判断写成了设计意图的**否定**：

```ts
return weekday !== 0 || hour >= 20;   // 等价于 !(weekday === 0 && hour < 20)
```

即「除了周日 20:00 之前，任何时刻都开窗」，而不是「周日 20:00 之后才开窗」。

窗口只是判断的一半，另一半是目标周——`nextMondayString` 从 `now` 推导「下周一」。两者叠加后的稳态：

| 本地时刻 | 目标周 | 结果 |
| --- | --- | --- |
| 周 N 周一 00:00 | 周 N+1 的周一 | **生成**（周 N 刚开始，零训练数据） |
| 周 N 周二–周六 | 周 N+1 的周一 | 幂等检查命中，no-op |
| 周 N 周日 20:00 | 周 N+1 的周一 | 幂等检查命中，**no-op** |

每份计划都提前整整一周生成，永远看不到它本该响应的那一周，架空了 ADR-001 的核心前提（「依据本周实际训练与编辑事件生成下一整周计划」）。真正的周日 20:00 那一跑从来没有产生过任何计划。

宽窗口也无法当作「补生成」机制：`install_generated_plan` 的 C21 硬约束禁止写入当前周或历史周，所以周一到周六的 tick 在结构上不可能补上漏掉的那一周——它只会把下下周提前做出来。合法的补跑只有当晚剩下的整点（20/21/22/23 四次）。

## 改动

- 新增 `_shared/generationWindow.mjs`：把 `localWeekdayAndHour` / `isGenerationWindowOpen` / `isInferenceWindowOpen` / `nextMondayString` / `thisMondayString` / `localDateString` 从 `index.ts` 提取为纯函数模块（沿用 `_shared/timezone.mjs` 的既有做法），使每小时 cron 最关键的判断可以离线单测，而不是一周只能观察一次。
- 判断修正为 `weekday === 0 && hour >= 20`。
- `index.ts` 改为 import，删除本地副本；行为推断扫描（`runInferenceSweep`）不受影响——它在 `selectDueUsers` 之外调用，仍是每日 21:00–22:59 的独立闸门。
- 新增 `backend/tests/generationWindow.test.mjs`（29 例）。
- 新增 `20260728120000_cleanup_prematurely_generated_plans.sql`（**尚未应用，待授权**）。
- 更正 `20260708000015_phase2_schedule_generation_cron.sql` 里失效的验证注释（仅注释，SQL 未动）。
- 更新 `docs/architecture/ai-plan-generation.md` 对窗口的描述。

## 验证

- 本地推演（模拟每小时 cron 跑满 5 周，UTC / Asia/Shanghai / America/Los_Angeles）复现上表：修复前每次都在周一 00:00 触发，修复后每次都在周日 20:00 触发，目标周恒为次日。
- 变异测试：把 `generationWindow.mjs` 的判断改回旧式，29 例中 14 例失败；改回后全绿。确认测试确实锁住了这个回归。
- `node --test backend/tests/*.test.mjs`：129/129 通过（新增前 100 例）。
- `deno check generate-weekly-plan/index.ts`：51 个类型错误，与 `main` 逐条一致（全部来自 supabase-js 未生成类型的 `never` 泛型，属既有问题），本次改动未新增任何一条。
- **未执行**：迁移 SQL 未实跑。本机 Docker daemon 未运行，无法 `supabase db reset` 或起本地 Postgres；SQL 仅经人工走查，CTE 内 `DELETE ... RETURNING` 采用 `WITH deleted AS (...) SELECT * FROM deleted` 这种语法上无歧义的写法。应用前需要一次真实执行验证。

## 遗留数据评估

已被提前生成的 `training_plans` 行**必须删除才能重新生成**，标记状态没有用：`selectDueUsers` / `generateForUser` 按 `(user_id, week_start_date)` 查询且不带 status 过滤，`install_generated_plan` 会直接 `RAISE 'a plan for week % already exists'`，`idx_training_plans_active_week` 也是不分 status 的唯一索引。

但**不清理也会自愈**，只是多降级一周：

- 修复部署后的那个周日 20:00：下周计划已被提前生成 → 幂等命中 → 仍用那份陈旧计划（基于上上周数据）。
- 之后的周一 00:00：窗口已关闭，不再提前生成。
- 再下一个周日 20:00：目标周无计划 → 正常生成。**从此恢复正常。**

任意时刻云端最多只存在一份被提前生成的未来计划（周一 00:00 生成 N+1 后，本周剩余 tick 的目标周都是 N+1，幂等命中），所以清理范围最多一行/用户。清理迁移的取舍：换回一周的计划质量，代价是万一紧接着的那个周日生成失败，用户当周没有新计划（LLM 失败有 `fallback_repeat` 兜底，真正的风险只有 cron/函数完全没跑）。

迁移的三重保守条件见文件头注释：仅未来周（对齐 C21）、仅「早于目标周本地周日 00:00 创建」（合法生成落在周日 20:00–23:59，差 20 小时以上；提前生成差约 7 天）、且无任何完成/关联/用户编辑痕迹（客户端 `week_start_date <= today` 过滤决定未来计划对用户不可见，此条实际恒真，属兜底）。因此该迁移在任意时刻应用都安全，重跑幂等。

## 待办

- 应用前先跑只读盘点（见 PR 描述），确认线上实际有几行、`created_at` 是否符合「提前一周」的特征。
- 迁移与 Edge Function 的线上应用需要用户授权（AGENTS.md §5）。部署顺序：先部署 Edge Function（关窗），再应用清理迁移——顺序反了会让刚清掉的行在下一个整点被重新提前生成。
