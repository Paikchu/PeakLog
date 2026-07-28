# Supabase migration ledger repair runbook

> 关联 Issue：#131
> 对账工具：`backend/scripts/migration-ledger-audit.sh`
> 静态自检：`backend/scripts/migration-ledger-check.mjs`
> replay 验证：`backend/scripts/migration-ledger-replay.sh`
> 2026-07-29 的实测快照：`../logs/2026-07-29-migration-ledger-audit.md`

本文件是**执行手册**，不是背景说明。每一步都写清「做什么 / 为什么这么做 / 做错会怎样」。
凡是标了 **⚠️ 需单独审批** 的步骤，不得在未获得用户明确授权的情况下执行。

---

## 1. 这份 runbook 解决的是什么问题

Supabase 用 `supabase_migrations.schema_migrations` 这张表记账「哪些迁移跑过」，
主键是 14 位的 `version`。CLI 决定 `db push` 要执行什么，唯一依据就是
「仓库文件名前 14 位」减去「这张表里已有的 version」。

PeakLog 的历史里有一部分迁移不是通过 CLI 打上去的，而是通过 MCP `apply_migration`。
MCP 用**调用当刻的 UTC 时间戳**记账，仓库文件用的却是人工编的顺序号
（`20260707000009` 这种）。于是同一份 SQL 在两边留下了两个不同的 version：

```
仓库： 20260707000009_remove_chat_pipeline_add_custom_exercises.sql
线上： 20260707133225  remove_chat_pipeline_add_custom_exercises
```

CLI 看到的是「本地有一个没跑过的 `20260707000009`」，于是 `db push` 会**再跑一遍**。
如果那份 SQL 不是幂等的（`DROP TABLE`、`UPDATE`、`INSERT` 一律不是），就会破坏生产数据。
反过来，线上独有的迁移（`20260708022700_fix_install_generated_plan_grants`）在仓库里
根本不存在，任何从干净 checkout 重建的环境都会缺掉那条权限修复。

**修复的方向不是让 SQL 重跑一遍，而是让记账反映事实**：
`supabase migration repair` 就是官方为此提供的工具 —— 它只改 `schema_migrations` 这张
记账表，**不执行任何 SQL、不碰任何业务对象**。

```
supabase migration repair --status applied  <version>   # 往记账表插入/保留一条
supabase migration repair --status reverted <version>   # 从记账表删掉一条
```

理解这一点是安全执行本 runbook 的前提：repair 本身不改 schema。真正有风险的是
**判断错了该 repair 哪些** —— 把一条其实没跑过的迁移标成 applied，等于永久跳过它。

---

## 2. 开始之前：三条硬约束

1. **不得删除、改名或改写 `backend/supabase/migrations/` 下任何已存在的迁移文件。**
   （`AGENTS.md`：只新增迁移，不改写已部署迁移；Issue #131 上线与回滚一节：禁止先删除
   migration 文件。）删文件看起来能「让两边版本号对上」，但它同时销毁了唯一能证明
   「这份 SQL 到底是什么」的证据，之后再想审计就没有原件可比了。

2. **不得凭推测新增迁移文件。** 若要把线上独有的迁移补进仓库，正文必须逐字来自
   `supabase migration fetch` 取回的 ledger 记账内容，并经人工走读确认，
   不得凭函数名或 Issue 描述"复原"。（Issue 验收标准：不得伪造未核对内容。）

3. **每一步 repair 之前，先完成 §3 的备份。** repair 会永久改写 `schema_migrations`，
   改完就无法再取证「repair 前长什么样」。

---

## 3. 步骤 1：备份与取证（**必做，不可跳过**）

```bash
cd <repo>
export SUPABASE_PROJECT_REF=fqyurmsuvtdafbnynurg
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
ARCHIVE=~/peaklog-ledger-backup-$STAMP
mkdir -p "$ARCHIVE"

# 3.1 ledger 快照 + 两边 SQL 正文 + 自动判定表（脚本内部只读，见其文件头）
./backend/scripts/migration-ledger-audit.sh --out "$ARCHIVE/audit"

# 3.2 生产 schema dump（对账前基线）
cd backend && supabase db dump --linked -f "$ARCHIVE/prod-schema-before.sql" && cd ..

# 3.3 生产数据备份 —— repair 不改数据，但 §5 步骤 6 的 db push 会
#     ⚠️ 需单独审批：这一步会把整库数据落到本地磁盘，含用户数据，
#     存放位置与保留期限需用户明确同意。
# cd backend && supabase db dump --linked --data-only -f "$ARCHIVE/prod-data-before.sql"
```

`supabase db dump` 会在容器里跑 `pg_dump`，**即使目标是线上项目也需要本地 Docker
守护进程在运行**（否则报 `failed to inspect docker image`）。
`supabase migration list` / `fetch` 不需要 Docker。

产出确认清单（缺任何一项都不要往下走）：

- [ ] `$ARCHIVE/audit/migration-list.txt` —— repair 前的 ledger 原样输出
- [ ] `$ARCHIVE/audit/remote-mirror/supabase/migrations/*.sql` —— 线上记账的 SQL 正文
- [ ] `$ARCHIVE/audit/diffs/` —— 同名配对的正文差异
- [ ] `$ARCHIVE/prod-schema-before.sql` —— 生产 schema 基线

> `remote-mirror/` 与 `prod-schema-before.sql` **不要提交进仓库**：前者是未经审计的
> 线上正文，把它塞进 `backend/supabase/migrations/` 正是约束 2 禁止的事。

---

## 4. 步骤 2：逐条判定（这是全流程唯一需要动脑的地方）

`ledger-report.md` 会给出机器判定，但**机器判定只是分级，最终结论必须由人给出**。
下面是判定规则本身 —— 换一个时间点重跑对账时，照这套规则重新推一遍，不要照抄
2026-07-29 的结论。

### 4.1 remote-only：线上有、仓库没有的 version

| 情形 | 依据 | 处置 |
|---|---|---|
| A. 仓库存在**同名**文件，正文归一化后一致 | `diffs/<version>.diff` 为空 | 同一份 SQL 换了时间戳跑过 → 本地 version 标 `applied`，远端 version 标 `reverted` |
| B. 仓库存在同名文件，但正文不同 | `diffs/<version>.diff` 非空 | 逐行走读 diff。**先判断差异是不是「仓库文件已经包含了后续修复的最终态」** —— 若线上是「有缺陷版 + 修复版」两条，而仓库压成了一份最终态文件，属于 1:N 合并关系，见 §4.3 |
| C. 仓库**没有**同名文件 | `diffs/<version>_<name>.remote.sql` | 见 §4.2 |

### 4.2 情形 C：仓库缺失的线上独有迁移，怎么补进仓库

**不能**直接把 `remote-mirror` 里的文件 `cp` 进 `backend/supabase/migrations/` 就完事 ——
那等于把未经审计的内容当成仓库的事实来源。正确顺序是：

1. **审计正文**：打开 `diffs/<version>_<name>.remote.sql`，逐条语句确认它做了什么、
   为什么做、是否仍然是期望的状态。特别注意 `GRANT`/`REVOKE`/RLS —— 这类语句
   看不出副作用，但错一个角色就是权限漏洞。
2. **和生产实际状态互证**：光看 SQL 不够，要确认它的效果**现在**还在生产上。
   例如一条 `REVOKE ... FROM anon` 可能后来被别的迁移覆盖掉了。用只读查询验证，
   典型探针见 §4.4。
3. **判断是否真的需要新增文件**：如果仓库里已有**另一份**迁移的最终态覆盖了这条
   线上独有迁移的全部效果（这正是 2026-07-29 快照里 `20260708022700` 的情况 ——
   `20260708000013` 已含其全部内容），那么**新增一份文件反而会让干净 replay
   重复执行同一段 SQL**。这种情况下不新增文件，只在 repair 时把该 version 标
   `reverted`，并在那份"最终态"文件里补一条注释指明合并关系。
   判断标准：**从干净库 replay 仓库全部迁移，能否得到与生产相同的对象状态？**
   —— 这个问题用 §6 的 replay 脚本回答，不靠推理。
4. **若确需新增**：用 `supabase migration new <name>` 生成一个**新的、递增的**时间戳，
   把审计过的正文贴进去，文件头写清「本文件内容来自线上 ledger version `<旧 version>`
   的记账正文，于 `<日期>` 审计确认」。**不要复用线上那个 version 当文件名** ——
   仓库的版本号必须严格递增（`migration-ledger-check.mjs` 会强制这条），
   而线上 version 通常落在历史中段。新文件的语句必须写成幂等形式
   （`CREATE OR REPLACE` / `IF NOT EXISTS` / 可重复执行的 `REVOKE`），
   因为它在生产上会被标成 applied 而**永远不会真的执行**，只在干净环境里跑。

### 4.3 情形 B 的特例：1 份仓库文件 = N 条线上迁移

线上先跑了有缺陷的版本、随后又跑了修复版，而仓库把两步合成一份"最终态"文件时，
会表现为：仓库文件与线上第一条 DIVERGED，且差异内容**恰好等于**线上第二条的全文。

处置：把 **N 条线上 version 全部**标 `reverted`，把那 1 份仓库文件的 version 标 `applied`。
成立的前提是「仓库文件的最终态 == 生产当前状态」，必须用 §4.4 的探针验证，
不能只看 diff 对得上。

### 4.4 local-only：仓库有、线上没有的 version —— 「真没跑过」还是「换时间戳跑过」

这是最容易判错、代价也最大的一类：判成 "repair applied" 而实际没跑过 → 那段 SQL
被永久跳过，schema 缺对象；判成 "push" 而实际跑过 → 非幂等 SQL 重复执行，可能毁数据。

按顺序走这三层证据，**任何一层给出否定结论就停下来人工裁决**：

1. **同名配对**：`remote-mirror` 里有没有同名（去掉版本号前缀后相同）的迁移？
   有 → 属于 §4.1 情形 A/B，是 repair 候选，不是 push 候选。
   没有 → 继续。

2. **schema 实际对象探针**（决定性）：把这份迁移会创建的对象列出来，
   直接查生产的系统目录确认它们**在不在**。全部不在 → 真的没跑过。
   全部都在 → 以别的方式跑过（可能是手工 SQL），需人工确认后按 repair 处理。
   部分在 → **最危险的情况**，说明它半途失败过；停下来单独处理，不要 push 也不要 repair。

   ```sql
   -- 只读探针模板：函数 / 触发器 / 表 / 列 / RLS policy 是否存在
   select
     (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = '<函数名>')            as fn_exists,
     (select count(*) from pg_trigger
       where tgname = '<触发器名>' and not tgisinternal)                  as trg_exists,
     (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = '<表>'
         and column_name = '<列>')                                       as col_exists,
     (select count(*) from pg_policies
       where schemaname = 'public' and policyname = '<policy 名>')       as policy_exists;
   ```

   函数体是否已含某处修改，用 `prosrc` 片段判定：

   ```sql
   select position('<修改后才有的独有片段>' in p.prosrc) > 0
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = '<函数名>';
   ```

3. **schema dump 交叉验证**：在 `$ARCHIVE/prod-schema-before.sql` 里 `grep` 同一批对象名。
   两条独立路径（系统目录 / pg_dump 输出）得到一致结论，才算证据充分。

> 查询只取对象存在性与函数体片段。**不要 `select` 任何用户数据行，不要读取
> `vault.decrypted_secrets`。** 需要确认某个 secret 是否存在时，查
> `select count(*) from vault.secrets where name = '<名字>'`，只看行数。

### 4.5 判定结论落盘

把结论写成一张表存档（可直接沿用 `ledger-report.md` 并人工订正），格式：

| 版本 | 类别 | 判定 | 依据（可复现的命令/文件） | 动作 |
|---|---|---|---|---|

**没有"依据"列的行不许执行。**

---

## 5. 步骤 3：执行 repair（⚠️ 全部需单独审批）

### 5.0 前置门槛

- [ ] §3 的备份产物齐全
- [ ] §4 的判定表每行都有依据
- [ ] 用户已逐条确认判定表
- [ ] 选在无 cron 触发的时间窗执行：`20260708000015_phase2_schedule_generation_cron.sql`
      装了每小时触发的 pg_cron 任务，repair 期间它仍会跑。repair 不改 schema，
      理论上互不影响，但 §5 步骤 6 的 `db push` 会 —— 那一步务必避开整点前后。

### 5.1 顺序原则

**先标 applied，再标 reverted。** 因为 `applied` 是插入记账、`reverted` 是删除记账；
反过来做会出现一个中间状态：某份 SQL 在两边都不记账，此时任何人跑 `db push`
都会真的重跑它。先插后删则任何时刻都至少有一条记账覆盖着这份 SQL。

### 5.2 命令模板

```bash
cd backend

# 一次一条，每条之后立刻 `supabase migration list --linked` 复核，不要批量执行。
# 批量执行的问题不是速度，是出错时无法定位是哪一条把状态带偏的。

# (a) 把仓库版本号标成已应用
supabase migration repair --status applied  <本地 version>

# (b) 把线上错位的版本号标成已回滚
supabase migration repair --status reverted <线上 version>

# (c) 复核
supabase migration list --linked
```

### 5.3 逐条执行表（按 §4 判定填写；下表结构取自 2026-07-29 快照，执行前必须重新对账）

| 序 | 命令 | 前置检查 | 复核 |
|---|---|---|---|
| 1 | `repair --status applied <local>` | diff 为空 / 探针确认对象存在 | list 中该行 Local 与 Remote 两列都出现该 version |
| 2 | `repair --status reverted <remote>` | 步骤 1 已复核通过 | list 中该 remote version 消失 |
| … | 每一对重复 | | |
| N | 1:N 合并关系的那组：先 applied 仓库 version，再依次 reverted **全部** 线上 version | §4.3 已验证最终态一致 | list 中只剩仓库 version |

### 5.4 步骤 6：把真正没跑过的迁移推上去（⚠️ 需单独审批，且这一步会**真的执行 SQL**）

repair 只处理记账。经 §4.4 判定为「真没跑过」的迁移，必须用 `db push` 真正执行：

```bash
cd backend
supabase db push --dry-run    # 先看它打算执行哪些 —— 必须与判定表完全一致
supabase db push
```

**`--dry-run` 输出里出现任何一条不在判定表里的 version，立即停止**，说明 repair 没做全。

涉及 DDL / RLS / GRANT 的迁移单独审批、单独执行、单独验证，不要和其它迁移一起 push。
push 之后按该迁移自己的验收点做冒烟测试（例如
`20260728140000_normalize_profile_timezone` 的验收点写在文件第 148-154 行：
「an authenticated client can still update its own profiles.timezone」）。

---

## 6. 步骤 4：干净 replay 验证（闭环，**repair 之后必做**）

ledger 对齐只让两边的**版本号列表**相同，它并不能证明「按仓库文件重放一遍能得到生产
那套对象」—— 历史上既有 MCP 直接改库，也有只存在于线上的权限修复，这些都不体现在
版本号上。所以必须再跑一次真正的 replay 并逐行比 schema：

```bash
cd <repo>
# 1) 导出生产 schema（只读）。注意：不要加 --schema，与脚本默认口径保持一致。
cd backend && supabase db dump --linked -f /tmp/prod-schema.sql && cd ..

# 2) 在本地容器上从零 replay 全部迁移并比对
./backend/scripts/migration-ledger-replay.sh --baseline /tmp/prod-schema.sql
```

脚本只操作 `--local`（Docker 里的一次性 Postgres），不会连线上，也不会执行
`db push` / `migration repair` / `db reset --linked`。

**两侧 dump 必须用同一组参数。** 给一侧加了 `--schema public` 而另一侧没加，
比对结果里会混进十几行纯属参数差异的噪声（`CREATE EXTENSION` 段、extension 自带
对象的 GRANT 会被 `--schema` 过滤掉），真正的差异被掩盖。脚本默认两侧都不传 `--schema`。

### 6.1 差异怎么读

比对已归一化掉几类必然不同、且与「schema 是否一致」无关的内容：pg_dump 版本横幅、
`\restrict` 指令、`SET`/`set_config` 会话前导、以及**属主**（托管库是 `supabase_admin`，
本地容器是 `postgres`）。属主被整体归一成 `<owner>`，所以**属主正确性不在本比对的
覆盖范围内**，需单独用 `\dp` / `pg_proc.proacl` 核对 —— 这是刻意的取舍，不是遗漏。

剩下的差异按这三类归因，**只有第三类才是真问题**：

1. **平台托管的扩展**：`hypopg`、`index_advisor`（线上由 Supabase advisor 装的）、
   `pg_graphql`（本地栈默认装的）等，不来自任何迁移，两边天然不同。
2. **尚未 push 的迁移**：replay 侧多出的对象，应当**逐一对得上**判定表里标为
   「待 push」的那些迁移。对不上就是判定表漏了东西。
3. **其它任何差异**：说明生产上存在仓库无法重建的对象（手工 DDL、未记账的 MCP 改动）。
   回到 §4.2 走「审计 → 互证 → 补迁移」流程。

---

## 7. 前滚方案（forward fix）

repair 之后如果发现某条判定错了，**不要试图"撤销" repair**，而是前滚：

| 错判 | 症状 | 前滚动作 |
|---|---|---|
| 把没跑过的标成了 applied | replay 比对显示生产缺对象；或线上功能报 `undefined function`/缺列 | 新增一份**幂等**迁移，内容为该 SQL 的可重复执行版本（`CREATE OR REPLACE`、`ADD COLUMN IF NOT EXISTS`），`db push` 上去。不要 `repair --status reverted` 再 push 原文件 —— 原文件多半不幂等 |
| 把跑过的标成了 reverted（然后被 push 重跑） | 非幂等语句报错（重复主键、`DROP` 不存在的对象），或数据被覆盖 | 立即停止 push；按 §8 恢复数据；再补一份幂等迁移把 schema 补齐 |
| 漏标了一条线上独有 version | `migration list` 仍有 remote-only 行；CI 门禁 fail | 回到 §4.2 补审计，按 §5 追加一条 repair |

前滚永远优于回滚：`schema_migrations` 是全局单表，回滚它等于让所有环境的认知一起倒退。

---

## 8. 回滚方案（rollback）

**先明确各步骤的可逆性**，不要笼统地说"能回滚"：

| 动作 | 可逆性 | 回滚方式 |
|---|---|---|
| `migration repair --status applied` | **完全可逆**，不改 schema | `migration repair --status reverted <同一 version>` |
| `migration repair --status reverted` | **完全可逆**，不改 schema | `migration repair --status applied <同一 version>` |
| 新增仓库迁移文件（未 push） | 完全可逆 | git revert |
| `db push`（执行了 DDL） | **不可逆** | 只能靠新的迁移前滚（§7）；结构性破坏靠 §8.1 恢复 |
| `db push`（执行了 DML，如数据清理） | **不可逆** | 只能靠 §8.1 的 PITR / 数据备份恢复 |

### 8.1 数据层恢复

生产项目开启了 Supabase 的自动备份 / PITR 时，走 Dashboard 的 Point-in-Time Recovery，
恢复点选在执行 §5.4 `db push` **之前**。⚠️ 这是破坏性操作，需单独审批，
且会丢失恢复点之后的全部写入。

无 PITR 时，只能用 §3.3 的 `--data-only` dump 恢复，同样会丢失 dump 之后的写入。
**这正是 §3.3 不能跳过的原因。**

### 8.2 ledger 层恢复

`$ARCHIVE/audit/migration-list.txt` 是 repair 前的完整 ledger 快照。
按它把每一条被改动的 version 用相反的 `--status` repair 回去即可完全还原 —— repair
不改 schema，所以这一层的回滚是干净的、无副作用的。

---

## 9. 防复发

1. **CI 门禁**：`.github/workflows/migration-ledger.yml`
   - 无条件跑 `migration-ledger-check.mjs`（命名格式、版本号合法性、唯一性、严格递增），
     不需要任何凭据，fork PR 也跑。
   - 配置了 Supabase secret 时额外跑 `migration-ledger-audit.sh`，
     local-only / remote-only 非空即 fail。
   - **没有 secret 时是 skip，不是 pass** —— 日志里会明确说明"未验证"，
     绝不给出一个绿色的假信号。
2. **禁止再用 MCP `apply_migration` 打生产**。要打生产就走 `supabase db push`，
   让 CLI 用仓库文件名当 version 记账。确实需要 MCP 时，**先** `supabase migration new`
   生成文件、提交，**再**用同一个 version 调 MCP，两边版本号才对得上。
3. **迁移文件头写清应用方式与时间**，但**不要把它当判定依据** ——
   2026-07-29 的快照里有 3 份迁移实际经 MCP 应用却没写任何说明，判定必须以正文比对为准。
