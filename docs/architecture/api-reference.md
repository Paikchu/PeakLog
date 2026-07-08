# PeakLog 接口文档

## 1. 通用说明

- iOS 客户端本身**不调用任何 Edge Function**;所有读写通过 `SupabaseDataClient`(`PeakLog/Services/Cloud/`)直连 PostgREST(`rest/v1/<table>`),不经 supabase-swift SDK。唯一的 Edge Function(`generate-weekly-plan`,Phase 2)是纯服务端到服务端调用(pg_cron → 函数 → RPC),客户端从不感知它的存在,只被动读取它写入的表。
- 认证走 GoTrue REST 端点（`SupabaseAuthProvider`），邮箱密码登录；Apple 登录待接入（需 Apple Developer 账号）。
- 所有请求携带 publishable key（`apikey` 头）+ 当前用户 JWT（`Authorization: Bearer`），行级安全（RLS）按 `auth.uid()` 隔离，服务端是唯一的授权真相源。
- Today、History、Profile 的 UI 读写路径经由 `LocalAppDatabase`（本地优先），`CloudSyncCoordinator` 负责登录后的全量拉取与本地变更的后台推送；接口契约的关键点是**表级 RLS 策略**，不是传统意义上的 REST 端点契约。

## 2. 写入语义与陷阱（先读，避免重蹈覆辙）

给某张表设计 RLS 策略前，必须想清楚客户端会用哪个动词写它——这三条踩坑经验（Phase 0/1）都源于动词与策略不匹配：

| 场景 | 现象 | 正确设计 |
|---|---|---|
| 表已有触发器建好首行，只给 `SELECT`/`UPDATE` 策略（如 `profiles`） | 客户端 `upsert`（本质 `INSERT ... ON CONFLICT`）→ `403 RLS violation` | 改用 `PATCH`（`SupabaseDataClient.update`），按主键定点更新 |
| 表主键是合成 `id`，但唯一约束在别的列上（如 `user_preferences` 唯一于 `user_id`） | upsert 按主键找不到冲突 → 插入新行 → 撞唯一键 `409` | 同上改 `PATCH`；或设计新表时让**主键本身**就是天然去重键（`user_goal_specs` 的 PK 直接是 `user_id`） |
| 表只给 `INSERT`+`SELECT`（append-only，如 `plan_edit_events`） | 客户端 `upsert`（`ON CONFLICT DO UPDATE`）在 Postgres 里即便不触发真实冲突也**需要 UPDATE 权限** | 用 `Prefer: resolution=ignore-duplicates`（`ON CONFLICT DO NOTHING`），只需 INSERT 权限，且对重试幂等 |

**另一个不直观的地方**：对没有匹配策略的 `UPDATE`/`DELETE` 请求，PostgREST/Postgres 不会返回 403——会返回 **`204`（成功，但 0 行受影响）**，因为 RLS 让该请求在服务端根本"看不见"任何可改的行。验证"这张表真的不可篡改"时，必须实际读回行内容确认没有变化，不能只看 HTTP 状态码。

## 3. 核心表一览（PostgREST 直连，RLS 隔离到 `auth.uid()`）

| 表 | 客户端可用动词 | 说明 |
|---|---|---|
| `profiles` / `user_preferences` | SELECT, UPDATE | 由 `handle_new_user` 触发器建首行；客户端只能 `PATCH` |
| `workout_sessions` / `exercises` / `exercise_sets` | ALL（own） | 力量训练三层聚合，`CloudMapper.pushBundle` 统一 upsert + `deleteNotIn` 对账 |
| `running_workouts` | ALL（own） | 跑步记录 |
| `training_plans` / `_days` / `_exercises` / `_sets` | ALL（own） | 周计划四层聚合。**`training_plans` 本身永不被客户端剪除**（历史周计划只增不删）；三张子表的推送剪除与拉取均 scoped 到当前活跃 `plan_id`，避免归档周数据串进 `activePlan` |
| `custom_exercises` | ALL（own） | 用户自定义动作库 |
| `user_goal_specs` | ALL（own），**PK = `user_id`** | 结构化训练目标（Phase 1）。主键即用户 id，upsert 冲突键直接命中，不会重蹈 `profiles`/`user_preferences` 的坑 |
| `plan_edit_events` | **仅 INSERT + SELECT** | 计划编辑事件流（Phase 1），append-only。无 UPDATE/DELETE 策略——不可篡改由服务端强制。`source` 字段区分 `user`/`agent`/`system`，Phase 2 起服务端写入必须标 `agent` |
| `plan_generations` | **仅 SELECT** | 计划生成溯源（Phase 1 建表，Phase 2 起真实写入）。客户端无写权限，写入方是 `generate-weekly-plan` Edge Function（`service_role`，绕过 RLS） |
| `user_stats` / `exercise_prs` | 仅 SELECT | 派生数据，由数据库触发器维护，客户端不写 |

## 4. `generate-weekly-plan` Edge Function（Phase 2，服务端到服务端，客户端不调用）

详细设计见 ADR-001 与 `docs/plans/2026-07-08-phase2-weekly-generation-plan.md`；本节只记录接口契约。

- **触发方**：`pg_cron`（每小时 `0 * * * *`，migration `20260708000015`），或手工定点触发（开发/调试用）。**没有任何客户端触发路径**——用户全程零 UI、零交互（方案 §4.2 / §8）。
- **鉴权**：请求头 `x-generation-secret` 必须匹配 Vault 中的 `generation_secret`（经 `check_generation_secret` RPC 校验）；否则 `401`。函数自身也接受 service_role JWT 调用。普通用户 JWT 一律 401。
- **请求体**：`{ dry_run?: boolean, user_id?: uuid, force?: boolean }`
  - 省略 `user_id`：全量模式，遍历所有用户，按各自 `profiles.timezone` 判断是否处于"周日 20:00 本地时间之后、下周计划尚不存在"的窗口。
  - 指定 `user_id`：定点模式，跳过时间窗口判断，直接对该用户跑一次（开发/调试/手工补跑用）。
  - `dry_run: true`：跑完整链路（ContextBuilder → LLM → Validator）但只写 `plan_generations(status='draft')`，**不写** `training_plan_*`。
  - `force: true`：跳过"下周计划已存在"的跳过检查（配合先手工删除，谨慎使用）。
- **响应**：`{ results: [{ userId, status, weekStartDate, engine?, planId?, archivedCount?, verdictCount?, error?, reason? }] }`，每用户独立一条，互不影响。`status` 取值：`installed`（真实写入）/ `dry_run`（试跑写入 draft）/ `skipped`（下周计划已存在）/ `error`。`engine` 取值：`llm`（DeepSeek 成功）/ `fallback_repeat`（C2 兜底，复制本周结构）。
- **数据流**：ContextBuilder（纯函数，读云表）→ LLM adapter（DeepSeek，`_shared/llm.mjs`）→ Validator（钳制/repair loop，`_shared/validator.mjs`）→ `install_generated_plan(user_id, plan)` RPC（单事务写入 + 惰性归档旧周）→ 写 `plan_generations` 溯源行。
- **硬约束（C21）**：`install_generated_plan` 在数据库层强制目标周严格晚于该用户当前周，不满足直接 `RAISE EXCEPTION` 回滚整个事务——独立于上游函数的日期计算是否正确，任何路径都不可能碰到当前周或历史周的计划内容与执行数据。

## 5. 后续维护

- 接口字段变更（新增列、改约束）时，同步本表并在对应 migration 里写清楚 RLS 设计意图（尤其是"为什么这张表不给某个动词"），下一个人不会重新踩坑。
- 新增跨表能力前，先跑一遍"全表列名 vs Swift DTO 逐字段核对"（详见 `docs/logs/2026-07-07-phase0-cloud-sync-verification-fixes.md` SY5），DTO 与 schema 漂移是本项目实际发生过的 bug 类别。
