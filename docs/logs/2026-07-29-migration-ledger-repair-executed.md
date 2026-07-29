# Migration ledger repair 执行记录（2026-07-29）

对账依据见 `2026-07-29-migration-ledger-audit.md`（只读阶段）；修复流程见
`../architecture/supabase-migration-ledger-repair.md`。本文记录**实际对生产库执行了什么**，
关闭 Issue #131。

项目：`fqyurmsuvtdafbnynurg`。执行前 main 为 `ddd9a4f`。

## 1. 结果

`supabase migration list --linked` 现在**零单边版本**——本地与远端逐行一一对应。
生产 schema 只多了 `20260728140000` 带来的对象，无任何计划外变更。

## 2. 执行前备份（先于任何写入）

留在 `~/PeakLog-ledger-backup-20260729-100314/`：

| 文件 | 内容 |
| --- | --- |
| `migration-list-before.txt` | 修复前的 local/remote ledger 快照 |
| `schema-before.sql` | 修复前生产 schema dump（1969 行） |
| `migration-list-after.txt` | 修复后 ledger |
| `schema-after.sql` | 修复后 schema dump |

Issue #131 要求「保留对账前 ledger 与 schema dump」，这两份就是回滚基线。**未删除任何
migration 文件**。

## 3. 核实：凭什么敢说这 10 对是同一份 SQL

对每一对拉取线上 `supabase_migrations.schema_migrations.statements` 的归一化 md5
（空白折叠后），与本地文件对比：

| 类别 | 数量 | 结论 |
| --- | --- | --- |
| 归一化后逐字节相同 | 2 | `phase3_replan_schema_and_rpc`、`cross_tenant_plan_integrity` |
| 仅差一行 `-- Applied to fqyurmsuvtdafbnynurg … via MCP.`（58 字符 + 换行 = 59） | 5 | 去掉该行后 md5 **全部命中** |
| 仅注释多寡不同，SQL 语句逐字相同 | 2 | `phase2_schedule_generation_cron`（同一个 `cron.schedule`、同一个 publishable key）、`lock_pr_refresh_helpers`（线上多两行说明注释） |
| 正文实质不同 | 1 | 见下 |

唯一实质差异是 `phase2_generation_rpc_and_scheduling_extensions`（本地 8199 / 线上 5826）：
**仓库把后来的热修折叠回了这一份**。线上是分两步跑的——`20260708022602` 建立 RPC，
`20260708022700_fix_install_generated_plan_grants` 补上 `REVOKE … FROM anon` 与
`auth.role() IS DISTINCT FROM 'service_role'` 的函数内检查；仓库的
`20260708000013` 一步到位，已包含这两者（见该文件第 59 行与 157–159 行）。

**路径不同，最终态相同**，所以把远端那条独有记录标记为 reverted 不是在丢弃任何东西：
它的效果由仓库里的 `20260708000013` 完整覆盖，干净 replay 会重建出同样的结果。

## 4. `20260728140000_normalize_profile_timezone` 是真的从未应用

不是记账问题，是实打实的缺口。执行前查生产 `pg_proc`：

```
install_generated_plan  ✓
replan_plan_days        ✓
resolve_timezone        ✗ 不存在
```

也就是说该文件注释里声称「`resolve_timezone()` 与
`isCrossRuntimeSafe()` 应用同一条规则，两个运行时按构造达成一致」的那条保证，
在线上一直**不成立**：`GMT+8`、`PST` 这类值仍可以写进 `profiles.timezone`，让 Edge Function
与 RPC 落到不同的日历周。

## 5. 实际执行的写操作（按顺序，共三步）

```bash
# 步骤 1 —— 把 10 份「已跑过但时间戳不同」的本地版本登记为 applied
supabase migration repair --status applied \
  20260707000009 20260707000010 20260707000011 20260708000012 20260708000013 \
  20260708000014 20260708000015 20260708000016 20260711000017 20260711100944

# 步骤 2 —— 移除 11 条重复/已被仓库覆盖的远端记录
supabase migration repair --status reverted \
  20260707133225 20260707145931 20260707152623 20260707173215 20260708022602 \
  20260708022700 20260708023343 20260708025841 20260708111927 20260711090822 20260711100505

# 步骤 3 —— 应用唯一真正待执行的迁移
supabase db push --include-all
```

步骤 1、2 只改 `supabase_migrations.schema_migrations` 记账表，**不执行任何 SQL**，
schema 零变化。步骤 3 是唯一真正的 DDL。

**顺序不可调换**：先 repair 再 push。反过来 `db push` 会把 11 个 local-only 版本全部当成
待执行，重跑已经跑过的非幂等 SQL。

### 步骤 3 的数据影响：0 行

推送前实测：`profiles` 共 2 行，均为 `Asia/Shanghai`，三项校验（Area/Location 形状、
`pg_timezone_names` 成员、`AT TIME ZONE` 探针）全过。迁移里那段一次性修复
`UPDATE` 因此命中 0 行，实际输出与预测一致：

```
NOTICE: normalize_profile_timezone: repaired 0 pre-existing profile row(s)
```

## 6. 冒烟测试

迁移文件自己写明：「this migration has not been executed anywhere yet (no local
Postgres available), so "an authenticated client can still update its own
profiles.timezone" is a required smoke test when it is applied.」——照做了。

**函数行为**（全部符合设计）：

| 输入 | 输出 | 说明 |
| --- | --- | --- |
| `Asia/Shanghai` | `Asia/Shanghai` | 合法 IANA，保留 |
| `GMT+8` | `UTC` | POSIX 形式，Postgres 接受但 Intl 拒绝 → 挡下 |
| `PST` | `UTC` | 两个运行时都接受但偏移差一小时 → 挡下 |
| `PST8PDT` | `UTC` | 一致但属 legacy 形式 → 按设计仍挡下 |
| `Asia/Shanghi`（拼写错误） | `UTC` | |
| `NULL` | `UTC` | |

**authenticated 写入路径**（在事务内做、末尾 `RAISE` 强制回滚，线上数据未被改动）：

```
SMOKE: rows_updated=1 normalized_to=UTC
```

`rows_updated=1` 证明触发器函数上的 `REVOKE` 不会阻断普通客户端更新自己的
profile——即迁移作者的判断（EXECUTE 在 `CREATE TRIGGER` 时检查，而非每次触发时）成立。
`normalized_to=UTC` 证明触发器确实生效，把 `GMT+8` 归一化了。回滚后复查
`profiles` 仍为 2 行 `Asia/Shanghai`，与执行前一致。

## 7. schema 变更（before/after dump 实测差异）

只有这些，没有别的：

- `CREATE OR REPLACE FUNCTION public.resolve_timezone(text)` + `COMMENT`
- `CREATE OR REPLACE FUNCTION public.normalize_profile_timezone()`
- `CREATE OR REPLACE TRIGGER profiles_normalize_timezone BEFORE INSERT OR UPDATE OF timezone ON profiles`
- 两个函数的 `REVOKE ALL … FROM PUBLIC` + `GRANT … TO service_role`

## 8. 回滚

**步骤 3（DDL）** —— 影响面是两个新函数加一个触发器，没有数据变更（0 行被改），所以回滚是：

```sql
DROP TRIGGER IF EXISTS profiles_normalize_timezone ON profiles;
DROP FUNCTION IF EXISTS public.normalize_profile_timezone();
DROP FUNCTION IF EXISTS public.resolve_timezone(text);
```

再 `supabase migration repair --status reverted 20260728140000`。注意回滚后
`profiles.timezone` 重新失去校验，第 4 节那个跨运行时分歧会回来。

**步骤 1、2（记账）** —— 用 `migration-list-before.txt` 反向 repair 即可，schema 本来就没被碰过。

**不要**用「删掉 migration 文件」的方式回滚（Issue #131 明确禁止）。

## 9. 残留

- CI 的 `migration-ledger` workflow 目前仍是 skip：仓库没有配
  `SUPABASE_ACCESS_TOKEN` / `SUPABASE_PROJECT_REF` / `SUPABASE_DB_PASSWORD`。
  门禁代码已在 main 上，配好 secret 即可生效——在那之前 ledger 再次分叉不会被自动发现。
- 干净 replay 与生产 schema 的逐行 diff 未做（需本地 Postgres 容器）。本次是按
  「线上 ledger 存的 SQL 正文」逐份核对的，证据层级见审计文档第 4 节。
