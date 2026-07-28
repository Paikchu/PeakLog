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
- 新增 `20260728131750_cleanup_prematurely_generated_plans.sql`（已授权并应用，详见下文「清理迁移线上应用」）。
- 更正 `20260708000015_phase2_schedule_generation_cron.sql` 里失效的验证注释（仅注释，SQL 未动）。
- 更新 `docs/architecture/ai-plan-generation.md` 对窗口的描述。

## 验证

- 本地推演（模拟每小时 cron 跑满 5 周，UTC / Asia/Shanghai / America/Los_Angeles）复现上表：修复前每次都在周一 00:00 触发，修复后每次都在周日 20:00 触发，目标周恒为次日。
- 变异测试：把 `generationWindow.mjs` 的判断改回旧式，29 例中 14 例失败；改回后全绿。确认测试确实锁住了这个回归。
- `node --test backend/tests/*.test.mjs`：129/129 通过（新增前 100 例）。
- `deno check generate-weekly-plan/index.ts`：51 个类型错误，与 `main` 逐条一致（全部来自 supabase-js 未生成类型的 `never` 泛型，属既有问题），本次改动未新增任何一条。
- **未执行**：迁移 SQL 未实跑。本机 Docker daemon 未运行，无法 `supabase db reset` 或起本地 Postgres；SQL 仅经人工走查，CTE 内 `DELETE ... RETURNING` 采用 `WITH deleted AS (...) SELECT * FROM deleted` 这种语法上无歧义的写法。应用前需要一次真实执行验证。

## 线上验收（Edge Function，已授权部署）

项目 `fqyurmsuvtdafbnynurg`。部署前先比对了线上 v9 的 9 个文件，与 `main` 逐字节一致，无本地未同步的热修可能被覆盖。

- `supabase functions deploy generate-weekly-plan --project-ref fqyurmsuvtdafbnynurg`：v9 → v10，10 个文件（新增 `_shared/generationWindow.mjs`）。
- `verify_jwt` 保持 `true` 不变（线上原值；cron 以 `apikey` 头调用，实证可用）。未借修 bug 之机改动鉴权姿态。
- 回读线上 v10 全部 10 个文件，与本分支逐字节一致；线上判断确认为 `return weekday === 0 && hour >= 20;`。
- 冒烟：用 `net.http_post` 按 cron 完全相同的方式（Vault 取 secret，密钥不出库）调 `{"dry_run": true}` → HTTP 200 `{"results":[]}`。这证明**新增共享模块在运行时解析正常**（#70 那类 module-not-found 未复现）、鉴权链路通、函数无崩溃。
- 副作用核查：`plan_generations` 与 `training_plans` 在该次调用后 15 分钟内均新增 0 行；两条未来计划原样保留。调用时上海时间 Tue 21:08 正处于行为推断窗口内，但 `dry_run` 会跳过 `runInferenceSweep`，故未触发任何重排。

**这次冒烟不能证明窗口修好了**——今天是周二且两个账号都已持有 2026-08-03 的计划，返回空是「窗口关闭」和「幂等命中」共同决定的，二者无法区分。这正是本文档要更正的那条失效注释犯的错，不再重复。窗口的证据来自单测（含变异验证）与线上字节比对；真正的线上判别证据要等：**2026-08-03 周一 00:00（上海）不应再出现新计划**。

## 线上现状（只读盘点确认）

线上共 2 个账号，实测数据与推演完全吻合（账号标识与时区不落盘，仅记录足以支撑结论的聚合特征）：

| 账号 | 目标周 | 创建时刻（本地） | 判定 |
| --- | --- | --- | --- |
| A | 2026-07-20 | Mon 00:00 | 提前一周 |
| A | 2026-07-27 | Mon 00:00 | 提前一周 |
| A | 2026-08-03 | Mon 00:01 | 提前一周（未来周） |
| B | 2026-08-03 | Mon 23:00 | 提前一周（未来周） |

连续三周都精确落在本地周一 00:00/00:01（cron 为 `'0 * * * *'`），周日 20:00 从未产出过任何计划。

## 遗留数据评估

已被提前生成的 `training_plans` 行**必须删除才能重新生成**，标记状态没有用：`selectDueUsers` / `generateForUser` 按 `(user_id, week_start_date)` 查询且不带 status 过滤，`install_generated_plan` 会直接 `RAISE 'a plan for week % already exists'`，`idx_training_plans_active_week` 也是不分 status 的唯一索引。

但**不清理也会自愈**，只是多降级一周：

- 修复部署后的那个周日 20:00：下周计划已被提前生成 → 幂等命中 → 仍用那份陈旧计划（基于上上周数据）。
- 之后的周一 00:00：窗口已关闭，不再提前生成。
- 再下一个周日 20:00：目标周无计划 → 正常生成。**从此恢复正常。**

任意时刻云端最多只存在一份被提前生成的未来计划（周一 00:00 生成 N+1 后，本周剩余 tick 的目标周都是 N+1，幂等命中），所以清理范围最多一行/用户。清理迁移的取舍：换回一周的计划质量，代价是万一紧接着的那个周日生成失败，用户当周没有新计划（LLM 失败有 `fallback_repeat` 兜底，真正的风险只有 cron/函数完全没跑）。

迁移的三重保守条件见文件头注释：仅未来周（对齐 C21）、仅「早于目标周本地周日 00:00 创建」（合法生成落在周日 20:00–23:59，差 20 小时以上；提前生成差约 7 天）、且无任何完成/关联/用户编辑痕迹（客户端 `week_start_date <= today` 过滤决定未来计划对用户不可见，此条实际恒真，属兜底）。因此该迁移在任意时刻应用都安全，重跑幂等。

## 清理迁移线上应用（已授权）

先以只读方式跑了迁移中完全相同的选择条件——同时验证 SQL 可执行（本机 Docker 未起，此前只有人工走查）与命中集合：正好 2 行，均为 2026-08-03 周，各 7 天 / 12 个动作 / 30–36 组，零完成痕迹。

应用后核对：

- 目标 2 行已删除；级联干净——`training_plan_days` / `_exercises` / `_sets` 残留均为 0。
- 对应的 2 行 `plan_generations` **保留**，溯源链未断（`plan_id` 无外键，如设计预期）。
- 当前周（2026-07-27）两个账号的计划**原样未动**，含其中一个账号已完成的 1 组——C21 语义得到尊重。
- 未来周计划数归 0；`training_plans` 由 7 行降为 5 行。
- 幂等复核：再跑一遍选择条件返回 0 行。

远端记录版本为 `20260728131750`，本地文件已同名对齐（本仓库既有的本地/远端版本号漂移不再叠加）。

**应用顺序**：Edge Function（v10，窗口已关）先，迁移后。反过来的话，被删的行会在下一个整点被仍然开着的 Mon–Sat 窗口重新提前生成。

### 清理迁移的两个已知局限（Review 指出，属实）

1. **谓词范围偏宽**：条件 2「早于目标周本地周日 00:00 创建」能挡住 cron 的提前生成，但**挡不住定点触发**——用开发用的 `{user_id, force}` 端点在周中为下周手工生成的计划，同样是未来周、同样早于那个周日、同样因客户端隐藏未来周而无人碰过，因此会被一并删除。本仓库历史上就有这样一行（2026-07-13 周的计划，创建于 Wed 2026-07-08 10:56，Phase 2 上线时人工触发），只是它已成历史周、被条件 1 排除。
   本次应用之所以安全，靠的不是谓词本身，而是**应用前逐行只读核对**（确认命中的正好是那 2 行、创建时刻均为本地周一）。这一步不是可选的：任何环境重放此迁移前都必须先跑一遍只读盘点。

2. **删除不可回滚**：`DELETE` 会级联掉整棵计划树，而 `plan_generations` 并不保证能还原——`engine='fallback_repeat'` 且 LLM 从未成功时 `raw_response` 可能为空。这与 AGENTS.md「仅在变更可回滚时部署线上资源」存在张力。
   **本次应用恰好可回滚**：事后核实两行的 `plan_generations` 均为 `engine='llm'`，`raw_response` 完整（9,087 / 10,474 字符），解析后为 `{days:[7 天], coachSummary}`，即 `buildInstallPlan` 的原始输入，可据此重建并重新 `install_generated_plan`。但这是这两行的运气，不是迁移的设计保证。
   后续若再做同类删除，应先落一份可还原的快照（或改为可逆的隔离表），而不是依赖溯源表恰好完整。

## Review 反馈处理（PR #130）

1. **失效文件名**：cron 迁移注释指向 `20260728120000_...`，但该文件后来被重命名为 `20260728131750_...`。已更正。
2. **损坏时区会拖垮整个扫描**：`profiles.timezone` 是无 CHECK 约束的 `varchar(64)`，而 `Intl.DateTimeFormat` 对无法识别的名字抛 `RangeError`；`selectDueUsers` / `runInferenceSweep` 的 for 循环没有 per-profile try/catch，所以**一行损坏数据会让整个小时扫描 500 中断**，其他用户当次全部不生成。已本地复现确认（三个 profile、中间一个 `Asia/Shanghi` 拼错 → 只处理了 1 个用户就整体抛出）。

   修法：在 `generationWindow.mjs` 加 `resolveTimezone()`，无法识别的值回落 UTC 并按值去重 `console.warn` 一次——与调用方既有的 `profile.timezone || "UTC"` 默认、以及清理迁移的 `COALESCE(..., 'UTC')` 保持一致。注意 `PST` 这类 Intl 能解析的旧别名不受影响（有测试锁定），否则真实用户会被换错时钟。

   新增 4 例测试（含「这些值确实会让 Intl 抛」的前置断言、以及模拟 `selectDueUsers` 循环形状的用例）。变异验证：去掉 guard 后 33 例中 2 例失败。

   **补充一轮（Review 再次指出，属实且更严重）**：只在 `generationWindow.mjs` 加 guard 不够，单独看甚至更糟——窗口判断不再抛之后，损坏 profile 会**更深地**走进扫描：`isInferenceWindowOpen` 按 UTC 返回 true → `inferenceGateOpen` 过完几道 DB 检查 → `localDayUtcRange`（`timezone.mjs`，未加 guard）才抛，仍是整个扫描 500，只是位置更靠后。已复现确认。
   最终修法按 Review 建议**在 profile 边界归一化**：导出 `resolveTimezone()`，把 `index.ts` 四处读取 profile 时区的地方（`selectDueUsers` / `runInferenceSweep` / `generateForUser` / `replanForUser`）的 `profile.timezone || "UTC"` 全部换成 `resolveTimezone(profile.timezone)`，这样包括 `timezone.mjs` 在内的所有下游 helper 拿到的都是已校验值。补 2 例测试分别锁住「原始坏值确实仍会让 `localDayUtcRange` 抛」和「归一化后所有下游 helper 都安全」。

   线上现状：两个 profile 均为合法的 `Asia/Shanghai`，该 guard 当前是 no-op，**无紧急性**。

   **第三轮（Review 再次指出，属实）**：JS 侧堵完之后，`install_generated_plan` / `replan_plan_days` 两个 RPC 仍**自行重读** `profiles.timezone`，且只 `coalesce(NULL, 'UTC')`、不处理非法值，`now() AT TIME ZONE v_user_timezone` 会抛 `22023`。已在线上验证：`select now() at time zone 'Asia/Shanghi'` → `ERROR 22023: time zone "Asia/Shanghi" not recognized`。
   后果比修复前更隐蔽：扫描不再中断，该用户的周生成会**跑完整条 LLM 链路**，最后才被 RPC 拒绝；因为计划始终不存在，之后每个周日整点都会重复一次注定失败且计费的生成，该用户永远拿不到计划。
   修法**不是加第四道 guard**，而是让列本身可信：新增 `20260728140000_normalize_profile_timezone.sql`——`resolve_timezone()`（STABLE，用固定时间戳探针；**当时的判据「接受与 RPC 完全相同的取值集合、含 `PST8PDT` 这类缩写」已被下方第四轮推翻，勿照此理解现行代码**）+ `profiles` 上的 `BEFORE INSERT OR UPDATE OF timezone` 触发器 + 一次性修复存量行。JS 侧 guard 保留作纵深防御。
   为何不用 CHECK 约束：Postgres 禁止 CHECK 中使用子查询，而合法性只能查 `pg_timezone_names` / `AT TIME ZONE` 机制，二者都非 IMMUTABLE。
   **该迁移尚未应用，等待授权。** 线上 0 行非法时区，当前为潜在缺陷而非现网故障。
   Review 又在该迁移上指出两点，已修：(a) 漏了本仓库的函数权限锁定约定（`REVOKE ... FROM PUBLIC/authenticated/anon` + `GRANT ... TO service_role`）——该约定源自 Phase 2 的真实事故，public schema 新建函数默认带 `anon` EXECUTE，缺了会让 `resolve_timezone` 变成 PostgREST 上的 `/rpc/resolve_timezone`；已核实线上其余 RPC 的 `anon_can_execute` 均为 false，本函数会是唯一例外。(b) `EXCEPTION WHEN OTHERS` 过宽，已收窄为 `invalid_parameter_value OR invalid_datetime_format` 静默回落，其余错误类先 `RAISE WARNING` 再回落（不因意外错误类阻断用户的 profile 写入，但不让它无声消失）。
   **第四轮（Review 指出，属实，且比其举例更严重）**：我原本刻意让 SQL 用 `AT TIME ZONE` 而非查 `pg_timezone_names`，理由是「接受与 RPC 完全一致的取值集合」——这个理由是错的。`profiles.timezone` 被**两个运行时**读取，要保证的是二者的**交集**，不是与其中之一对齐。实测：

   | 取值 | Intl | Postgres `AT TIME ZONE` |
   | --- | --- | --- |
   | `GMT+8` | 拒绝 | 接受，POSIX 语义 = UTC-8 |
   | `PST` | 接受 → UTC-7（含 DST） | 接受 → UTC-8（固定） |

   `GMT+8` 让两层差 8 小时；`PST` 更糟——**两边都接受且静默给出不同结果**，任何一侧都不报错。都足以让 Edge Function 与 RPC 落在不同日历周，表现为 C21 拒绝或计划生成到错误的周。两个问题值恰好都是 `pg_timezone_names` 里没有的。
   修法是**两个运行时共用同一条规则**：Area/Location 形态（或纯 `UTC`/`GMT`）+ 各自运行时接受。`isCrossRuntimeSafe()` 与 `resolve_timezone()` 实现同一判据，二者按构造一致而非靠巧合。刻意比任一运行时都严格（连 `PST8PDT` 这种两边其实一致的旧式写法也拒绝），因为 iOS `TimeZone.current.identifier` 只会产出 Area/Location 标识符，不损失任何真实取值。已对 14 个候选值逐一比对 JS 与 SQL 结果，**全部一致**。
   同时更正了我此前一条**错误的测试**：它断言 `PST` 应被原样保留，实际上那正是会让两个运行时分叉的取值。

   应用时的**必做冒烟**：确认 authenticated 客户端仍能更新自己的 `profiles.timezone`（触发器函数的 EXECUTE 权限 Postgres 只在 CREATE TRIGGER 时检查，但本迁移尚未在任何环境执行过）。

## 待办

- 2026-08-02（周日）20:00 上海时间：确认两个账号各自生成 2026-08-03 的新计划，且 `plan_generations.context_snapshot` 含 7/27–8/2 的实际训练数据。
- 2026-08-03（周一）00:00 上海时间：确认**没有**新计划出现——这是窗口修复唯一的线上判别证据。
- 顺带发现（本次范围外）：远端存在迁移 `20260708022700_fix_install_generated_plan_grants`，仓库 `backend/supabase/migrations/` 下没有对应文件。
