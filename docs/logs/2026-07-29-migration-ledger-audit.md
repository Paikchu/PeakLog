# Migration ledger 只读对账快照（2026-07-29）

> 关联 Issue：#131（Supabase Database：本地与远端 migration 历史分叉，无法安全自动部署）
> 关联 runbook：`../architecture/supabase-migration-ledger-repair.md`
> 采集工具：`backend/scripts/migration-ledger-audit.sh`

本文件是一次**点时快照**，不是流程文档。它存在的理由是：Issue #131 的验收标准要求
「保留对账前 ledger 与 schema dump」，而 repair 一旦执行，`supabase_migrations.schema_migrations`
的内容就被永久改写、无法再回头取证。所以在动任何一条 repair 之前，先把两边 ledger 的
**真实内容**（不是版本号列表，是 SQL 正文）落盘存档一次。

采集全程只读，执行过的命令逐条列在文末「附录 A」。

---

## 1. 采集环境

| 项 | 值 |
|---|---|
| 采集时间（UTC） | 2026-07-28T18:42:11Z |
| 仓库基线 | `341b2a7`（`origin/main`） |
| 线上项目 | `fqyurmsuvtdafbnynurg`（PeakLog，Canada Central） |
| Supabase CLI | 2.75.0 |
| 仓库迁移数 | 22 |
| 线上 ledger 版本数 | 22 |

## 2. 结论摘要

| 类别 | 数量 | 含义 |
|---|---|---|
| 两边同版本号 | 11 | 通过 CLI 正常 `db push` 的部分，无需处理 |
| 仅本地（local-only） | 11 | 其中 **10 份是时间戳错位**（同一份 SQL 换了 version 跑过），**1 份真的没跑过** |
| 仅远端（remote-only） | 11 | 其中 **10 份是同一批时间戳错位的对面**，**1 份是仓库彻底缺失的线上独有迁移** |

> Issue 正文记的是「10 个 local-only / 12 个 remote-only」。本次实测是 11 / 11，差异有据可查：
> `20260728140000_normalize_profile_timezone` 是 Issue 提交后才合进 `main` 的新迁移（local-only +1），
> `20260728131750_cleanup_prematurely_generated_plans` 在 Issue 提交后已被以相同 version 记入线上 ledger
> （remote-only −1，两边同版本号 +1）。**分叉在持续扩大**，这正是需要 CI 门禁的原因。

### 2.1 关键发现（按重要性）

1. **`20260708022700_fix_install_generated_plan_grants` 是线上独有、仓库完全没有的迁移。**
   它把 `install_generated_plan(uuid, jsonb)` 的 `anon` EXECUTE 权限显式 REVOKE 掉，并在函数体内
   加了 `auth.role() = 'service_role'` 的纵深防御。这是一条 **安全修复**，也是「干净 checkout
   无法重建生产权限状态」这句话最实际的例子。
   好消息：仓库的 `20260708000013` 已经包含了这两处修复的**最终态**（见 §3.2），所以从干净库
   replay 得到的结果与生产一致；坏消息：ledger 上没有任何东西能证明这一点，只能靠正文比对。

2. **「注释里自称经 MCP 应用」不是可靠信号。** 仓库里只有 8 份迁移写了 `via MCP`
   （见 §3.1 的 `MCP` 列），但实际发生时间戳错位的有 10 份 ——
   `20260708000016_phase3_replan_schema_and_rpc`、`20260711000017_cross_tenant_plan_integrity`、
   `20260711100944_lock_pr_refresh_helpers` 三份没写任何 MCP 说明，却同样是以别的 version 跑上线的。
   **判定必须以正文比对为准，不能以注释为准。**

3. **`generation_secret` 这个 vault secret 在两边 ledger 里都没有创建记录，但生产上确实存在。**
   仓库 `20260708000013` 末尾有一段 `IF NOT EXISTS ... vault.create_secret(...)` 的 DO 块，
   而线上 `20260708022602` 的记账正文里没有它；线上 `20260708023343` 只是**读取**这个 secret。
   实测 `select count(*) from vault.secrets where name='generation_secret'` = 1。
   即：这个 secret 是在任何被记账的迁移之外被创建的。由于 DO 块带 `IF NOT EXISTS` 守卫，
   它在两个方向上都是幂等的（干净 replay 会创建，对生产重放是 no-op），**不构成 repair 障碍**，
   但它是「MCP 直接改库不留痕」的又一个证据，值得在 runbook 里单独记一笔。

4. **`20260728140000_normalize_profile_timezone` 是唯一真正没跑过的迁移。** 实测生产上
   `public.resolve_timezone`、`public.normalize_profile_timezone`、
   触发器 `profiles_normalize_timezone` 三者全部**不存在**（计数均为 0），
   `prod-schema.sql` 里也搜不到这些名字。它是 `db push` 候选，不是 repair 候选。

---

## 3. 本地 ledger 清单（`backend/supabase/migrations/`）

`MCP` 列 = 文件头注释是否自称「Applied to … via MCP」。
`对账` 列 = 本次实测判定（见 §4 的判定依据）。

| # | version | 文件 | MCP | 一句话作用 | 对账 |
|---|---|---|---|---|---|
| 1 | `20260318000001` | `_schema.sql` | 否 | PeakLog 基础 Schema | 两边一致 |
| 2 | `20260318000002` | `_triggers.sql` | 否 | 触发器函数 | 两边一致 |
| 3 | `20260318000003` | `_storage.sql` | 否 | Storage Buckets | 两边一致 |
| 4 | `20260320000004` | `_exercise_prs.sql` | 否 | `exercise_prs` 个人纪录表 | 两边一致 |
| 5 | `20260321000005` | `_conversation_pending_actions.sql` | 否 | 对话待确认动作表 | 两边一致 |
| 6 | `20260324000006` | `_training_plans.sql` | 否 | 训练计划三级表结构 | 两边一致 |
| 7 | `20260401000007` | `_running_workouts.sql` | 否 | 有氧/跑步训练记录 | 两边一致 |
| 8 | `20260402000008` | `_training_plan_exercise_load_type.sql` | 否 | 计划动作负重类型 | 两边一致 |
| 9 | `20260707000009` | `_remove_chat_pipeline_add_custom_exercises.sql` | **是** | 下线 chat 时代链路，保留训练核心 | 时间戳错位 → `20260707133225` |
| 10 | `20260707000010` | `_add_exercise_library_fields_to_exercises.sql` | **是** | 记录动作库 slug 与负重类型 | 时间戳错位 → `20260707145931` |
| 11 | `20260707000011` | `_add_exercise_id_to_training_plan_exercises.sql` | **是** | 计划动作保留库 slug | 时间戳错位 → `20260707152623` |
| 12 | `20260708000012` | `_phase1_events_goalspec_generations.sql` | **是** | Phase 1：GoalSpec、编辑事件流、生成溯源 | 时间戳错位 → `20260707173215` |
| 13 | `20260708000013` | `_phase2_generation_rpc_and_scheduling_extensions.sql` | **是** | Phase 2：`install_generated_plan` RPC + pg_cron/pg_net | 时间戳错位 → `20260708022602`（**正文不同**，见 §3.2） |
| 14 | `20260708000014` | `_phase2_check_generation_secret_rpc.sql` | **是** | `check_generation_secret` 校验 RPC | 时间戳错位 → `20260708023343` |
| 15 | `20260708000015` | `_phase2_schedule_generation_cron.sql` | **是** | 每小时 pg_cron 触发生成 | 时间戳错位 → `20260708025841` |
| 16 | `20260708000016` | `_phase3_replan_schema_and_rpc.sql` | 否 | Phase 3：周中重排 schema + RPC | 时间戳错位 → `20260708111927` |
| 17 | `20260711000017` | `_cross_tenant_plan_integrity.sql` | 否 | 清理归属不一致的历史行 + 完整性约束 | 时间戳错位 → `20260711090822` |
| 18 | `20260711100944` | `_lock_pr_refresh_helpers.sql` | 否 | 锁定 PR 刷新辅助函数权限 | 时间戳错位 → `20260711100505` |
| 19 | `20260715145641` | `_add_cardio_training_plan.sql` | 否 | 有氧计划字段 | 两边一致 |
| 20 | `20260715164521` | `_add_cardio_link_index.sql` | 否 | 有氧关联索引 | 两边一致 |
| 21 | `20260728131750` | `_cleanup_prematurely_generated_plans.sql` | **是** | 清理生成窗口反转期间产出的错误计划 | 两边一致（MCP 这次用了同一个 version） |
| 22 | `20260728140000` | `_normalize_profile_timezone.sql` | 否 | `profiles.timezone` 写入归一化触发器 | **线上没跑过 → push 候选** |

### 3.1 时间戳错位对照表（10 对）

正文比对方法见 §4.1。9 对归一化后逐字节相同，1 对不同。

| 迁移名 | 本地 version | 线上 version | 正文比对 |
|---|---|---|---|
| `remove_chat_pipeline_add_custom_exercises` | `20260707000009` | `20260707133225` | IDENTICAL |
| `add_exercise_library_fields_to_exercises` | `20260707000010` | `20260707145931` | IDENTICAL |
| `add_exercise_id_to_training_plan_exercises` | `20260707000011` | `20260707152623` | IDENTICAL |
| `phase1_events_goalspec_generations` | `20260708000012` | `20260707173215` | IDENTICAL |
| `phase2_generation_rpc_and_scheduling_extensions` | `20260708000013` | `20260708022602` | **DIVERGED** |
| `phase2_check_generation_secret_rpc` | `20260708000014` | `20260708023343` | IDENTICAL |
| `phase2_schedule_generation_cron` | `20260708000015` | `20260708025841` | IDENTICAL |
| `phase3_replan_schema_and_rpc` | `20260708000016` | `20260708111927` | IDENTICAL |
| `cross_tenant_plan_integrity` | `20260711000017` | `20260711090822` | IDENTICAL |
| `lock_pr_refresh_helpers` | `20260711100944` | `20260711100505` | IDENTICAL |

> 注意时间顺序：本地 `20260708000012` 对应的线上 version 是 `20260707173215`，
> 比本地 `20260707000011` 对应的 `20260707152623` 晚、却比本地编号看起来「早一天」。
> 人工顺序号与真实执行时刻之间没有单调关系，这是 `migration-ledger-check.mjs`
> 强制版本号严格递增那条规则的直接动因。

### 3.2 唯一一处正文差异：`phase2_generation_rpc_and_scheduling_extensions`

本地 `20260708000013` 比线上 `20260708022602` 多出三块内容（`-` 表示线上缺失）：

```diff
-  IF auth.role() IS DISTINCT FROM 'service_role' THEN
-    RAISE EXCEPTION 'install_generated_plan may only be called by service_role'
-      USING ERRCODE = 'insufficient_privilege';
-  END IF;
...
-REVOKE ALL ON FUNCTION install_generated_plan(uuid, jsonb) FROM anon;
...
-DO $$
-BEGIN
-  IF NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'generation_secret') THEN
-    PERFORM vault.create_secret(...);
-  END IF;
-END $$;
```

前两块**正是线上独有迁移 `20260708022700_fix_install_generated_plan_grants` 的内容**。
也就是说线上的历史是「先跑了有漏洞的版本 `022602`，再跑修复 `022700`」两步；
仓库把两步压成了一份文件的最终态（该文件第 4-6 行的注释也是这么写的：
“Applied … via MCP (as two migrations, since a security issue was caught and fixed live … this
file represents the corrected end state, not the intermediate one)”）。

第三块（vault secret）见 §2.1 第 3 条。

**因此这不是「正文不一致需要人工裁决」，而是「1 份仓库文件 = 2 份线上迁移」的合并关系**，
repair 时要把 `20260708022602` 和 `20260708022700` **一起**标 reverted，
把 `20260708000013` 标 applied。runbook §4 步骤 5 单独写了这一条。

## 4. 判定依据（为什么敢说「跑过」/「没跑过」）

Issue 明确要求「不得伪造未核对内容」，所以每一条判定都必须落到可复现的证据上。
本次用了三层证据，**不接受「看名字像」这种判断**：

### 4.1 层一：线上 ledger 存的 SQL 正文（决定性）

`supabase_migrations.schema_migrations` 除了 version 还存了 `statements[]` —— 即当初真正提交给
数据库的 SQL 本身。`supabase migration fetch --linked` 把它重建成文件。这不是推测，是数据库
自己的记账。比对时做了两处**保守**归一化，且只用于分级、不替代人工走读完整 diff：

- 去掉注释行与空行：仓库文件带中文说明头，ledger 里存的是提交正文，注释差异是必然噪声。
- 把 `;;` 收敛成 `;`、丢弃孤立的 `;` 行：ledger 按语句数组存储，CLI 重建文件时会给每条语句
  补一个分隔符，于是原本就以 `;` 结尾的语句变成 `;;`。这是 CLI 的序列化伪影，不是 SQL 差异；
  不抹平的话 10 对全会被判成 DIVERGED，真正需要看的那一对会淹没在噪声里。

### 4.2 层二：生产 schema 实际对象（用于 local-only 的「跑没跑过」）

对 `20260728140000_normalize_profile_timezone`，直接查生产的系统目录（只读 SELECT）：

| 探针 | 期望（若已应用） | 实测 |
|---|---|---|
| `pg_proc` 中 `public.resolve_timezone` | 1 | **0** |
| `pg_proc` 中 `public.normalize_profile_timezone` | 1 | **0** |
| `pg_trigger` 中 `profiles_normalize_timezone` | 1 | **0** |

`prod-schema.sql`（1969 行）里 `grep -c resolve_timezone` 同样为 0，两条独立路径互证。
→ 判定：**真的没跑过**，属于 `supabase db push` 范畴。

### 4.3 层三：生产函数体（用于确认 remote-only 的效果是否已在最终态里）

| 探针 | 实测 |
|---|---|
| `install_generated_plan` 的 `prosrc` 含 `may only be called by service_role` | **true** |
| `vault.secrets` 中 `name='generation_secret'` 行数 | **1** |

→ 判定：`20260708022700` 的效果**已经是生产的当前状态**，且与仓库 `20260708000013` 的最终态一致。
所以「新增一份内容等价的仓库迁移文件」这件事在本例中**不需要新增文件**（仓库已含最终态），
只需要在 repair 时把该 version 标 reverted。runbook §4 步骤 5 给了完整推理与替代方案。

> 注：查询只取对象存在性、函数体片段与 secret 的**行数**，全程未读取任何 secret 明文、
> 未读取任何用户数据。

## 5. 干净 replay 验证（本地容器，未触碰线上）

`./backend/scripts/migration-ledger-replay.sh --baseline <prod-schema.sql>`，
在 Docker 里起一个一次性 Postgres，`supabase db reset --local --no-seed` 从零重放全部 22 份迁移，
再把结果与 §1 导出的生产 dump 比对。

**结果：22 份迁移在干净库上全部执行成功**（这本身就排除了"某份迁移在空库上跑不通"这一类风险），
归一化后与生产 dump 的差异 92 行，**全部可归因，无一处不可解释**：

| 差异 | 方向 | 归因 |
|---|---|---|
| `hypopg`、`index_advisor` 扩展 | 仅生产有 | Supabase advisor 装的平台扩展，不来自任何迁移 |
| `pg_graphql` 扩展 | 仅本地有 | 本地 Supabase 栈默认装的，不来自任何迁移 |
| `public.resolve_timezone`、`public.normalize_profile_timezone`、触发器 `profiles_normalize_timezone` 及其 GRANT/REVOKE（约 45 行） | 仅 replay 有 | 就是 §2.1 第 4 条那份尚未 push 的 `20260728140000` |

也就是说：**排除平台托管的扩展后，唯一的 schema 差异恰好等于唯一一份未 push 的迁移。**
这是「仓库能重建生产 public schema」这句话目前能拿到的最强证据 ——
但它**不能替代 repair 后的复验**：ledger 目前仍是分叉的，只要 ledger 没对齐，
下一次 `db push` 依然会重跑 10 份非幂等 SQL。

> 方法论订正（本次采集中发现并已修入脚本）：第一遍比对时 baseline 用的是不带参数的
> `supabase db dump --linked`，而 replay 侧用了 `--schema public`，两边 dump 口径不同 ——
> 加了 `--schema` 的一侧会丢掉 `CREATE EXTENSION` 段和 extension 自带对象
> （如 `moddatetime`）的 GRANT，凭空多出 17 行纯属参数差异的噪声
> （`ALTER PUBLICATION supabase_realtime OWNER TO postgres`、4 条 `moddatetime` GRANT 等）。
> `migration-ledger-replay.sh` 的 `--schemas` 默认值已从 `public` 改为空，两侧口径对齐。

## 6. 存档产物

以下文件在采集时生成，**未提交进仓库**（`prod-schema.sql` 属于线上快照，
`remote-mirror/` 属于未经审计的线上正文——把它们提交进 `backend/supabase/migrations/`
正是 Issue 禁止的「伪造未核对内容」）。执行 repair 前请按 runbook §3 重新生成一份并妥善保存：

```
<out>/local-ledger.tsv                        仓库迁移清单
<out>/remote-ledger.tsv                       线上 ledger 清单
<out>/migration-list.txt                      `supabase migration list --linked` 原样输出（对账前快照）
<out>/remote-mirror/supabase/migrations/*.sql 线上 ledger 记账的 SQL 正文（22 份）
<out>/diffs/<version>.diff                    同名配对的正文差异
<out>/diffs/20260708022700_fix_install_generated_plan_grants.remote.sql
<out>/prod-schema.sql                         生产 schema dump（1969 行，对账前快照）
<out>/ledger-report.md                        自动生成的判定表
```

---

## 附录 A：本次执行过的全部线上命令（逐条，全部只读）

| # | 命令 | 性质 |
|---|---|---|
| 1 | `supabase projects list` | 只读，列项目 |
| 2 | `supabase migration list --linked` | 只读，读 ledger |
| 3 | `supabase migration fetch --linked --workdir <一次性镜像目录>` | 只读，读 ledger 的 `statements[]`；`--workdir` **刻意指向仓库外的临时目录**，避免把未审计正文写进 `backend/supabase/migrations/` |
| 4 | `supabase db dump --linked -f <out>/prod-schema.sql` | 只读，`pg_dump --schema-only` |
| 5 | 一条 `SELECT`（`pg_proc` / `pg_trigger` / `vault.secrets` 计数 + `prosrc` 片段判定） | 只读 |

§5 的 replay 只跑在**本地 Docker 容器**（`supabase start` / `supabase db reset --local`），
不在上表内 —— 它与线上项目零交互。

**未执行**（且本 PR 的任何脚本都不会执行）：`supabase db push`、`supabase migration repair`、
`supabase db reset --linked`、任何 DDL/DML、任何 MCP 写调用
（`apply_migration` / `deploy_edge_function` / `create_branch` / `merge_branch` …）。

## 附录 B：复现本次采集的最短命令

```bash
cd <repo>
export SUPABASE_PROJECT_REF=fqyurmsuvtdafbnynurg
./backend/scripts/migration-ledger-audit.sh --out /tmp/ledger-audit
# 退出码 0 = 已对齐；1 = 仍有分叉；3 = 缺凭据/连不上（**不是通过**）
```

`supabase db dump` 与 `supabase db reset --local` 都在容器里跑 `pg_dump`/Postgres，
**即使目标是线上项目也需要本地 Docker 守护进程在运行**（本次采集第一遍因 Docker 未启动而失败，
报 `failed to inspect docker image`）。`supabase migration list/fetch` 则不需要 Docker。
