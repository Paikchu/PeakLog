# Edge Function 发布与部署一致性 Runbook

> 适用对象：`backend/supabase/functions/` 下的所有 Edge Function，当前实际部署的只有 `generate-weekly-plan`。
> 关联：Issue #133、PR #130、`.github/workflows/backend.yml`、`backend/scripts/verify-deployed-function.mjs`。

## 1. 这份文档要解决的问题

周计划生成窗口（`isGenerationWindowOpen`）曾经被**直接热修在线上函数上**：线上 `generate-weekly-plan` v10 已经是"仅本地周日 20:00–23:59 开窗"的正确行为，而当时的 `main`（`12fc897`）里仍然是写反的 `weekday !== 0 || hour >= 20`。

这个状态的危险之处不在于"线上是错的"——线上当时是对的——而在于**没有任何机制能发现两者不一致**：

- 单元测试全绿，因为它测的是仓库里的代码；
- 线上行为正常，因为它跑的是热修后的代码；
- 于是任何一次例行的 `supabase functions deploy`（哪怕是为了发布一个完全无关的改动）都会静默地把错误逻辑重新覆盖回生产，而错误的表现要等到**下一个周日晚上**才可能被人察觉。

换句话说：**仓库不再是可安全部署的唯一事实源**。这份 runbook 和配套的校验脚本存在的唯一目的，就是让"线上跑的字节 = 某个确定 commit 的字节"这件事**可以被机器证明**，而不是靠记忆和默认假设。

窗口谓词本身的修复已经随 PR #130 合入 `main`（`8b56393` / 合并提交 `341b2a7`），谓词现在位于 `backend/supabase/functions/_shared/generationWindow.mjs`，由 `backend/tests/generationWindow.test.mjs` 覆盖。因此 Issue #133 的剩余部分是流程问题，不是代码问题。

## 2. 前置：CI 凭据配置

`.github/workflows/backend.yml` 的 `verify-deployment` job 需要两项配置，**没有配置时它会跳过校验并打一条 warning 注解**，而不是假装通过：

| 名称 | 类型 | 说明 |
| --- | --- | --- |
| `SUPABASE_ACCESS_TOKEN` | Repository **secret** | Supabase Management API 访问令牌（`sbp_…`）。只需要读权限；脚本没有任何写入/部署代码路径。 |
| `SUPABASE_PROJECT_REF` | Repository **variable** | 项目 ref。它本来就公开在每个 Function URL 里，不是凭据，所以用 variable 而不是 secret——`vars` 可以直接在表达式里读，`secrets` 不行。 |

在 GitHub 仓库的 Settings → Secrets and variables → Actions 里配置。

> 配置之前，`verify-deployment` 每次都会以"未校验"的形式通过。**它的绿色不代表线上和 `main` 一致**，只代表没人检查过。

## 3. 发布流程

### 3.1 从哪个 commit 部署

**只从 `main` 上一个已经通过 CI 的 commit 部署，并把这个 commit SHA 记下来。** 不要从功能分支、不要从带未提交改动的工作区、不要"就改这一行我直接改线上"。

```bash
git checkout main
git pull
git status --short          # 必须为空：工作区脏 = 部署的字节没有对应的 commit
RELEASE_SHA="$(git rev-parse HEAD)"
echo "$RELEASE_SHA"
```

确认这个 commit 上的 `Backend` workflow 是绿的（`gh run list --workflow=backend.yml --branch=main`）。

### 3.2 部署

```bash
supabase functions deploy generate-weekly-plan \
  --project-ref "$SUPABASE_PROJECT_REF" \
  --workdir backend
```

`--workdir backend` 是必须的：CLI 期望 `<workdir>/supabase/` 布局，本仓库的 Supabase 项目在 `backend/supabase/`。

### 3.3 部署后回读校验（不可跳过）

部署命令返回成功**只说明上传成功**，不说明上传的是你以为的那份代码。必须回读：

```bash
SUPABASE_ACCESS_TOKEN=sbp_… \
node backend/scripts/verify-deployed-function.mjs \
  --function generate-weekly-plan \
  --commit "$RELEASE_SHA" \
  --project-ref "$SUPABASE_PROJECT_REF"
```

脚本做的事：

1. 从 `$RELEASE_SHA` 的 git 对象库（不是工作区）读出该函数的入口文件，并沿**相对 import** 递归求出它的传递闭包——也就是 Supabase 实际打进 eszip 的那组仓库文件。这里刻意不用"函数目录 + 整个 `_shared`"的写死清单：写死的清单会在有人增删共享模块的那一刻失效，而那正是本文档要防的漂移形态。
2. `supabase functions download … --use-api` 把线上部署的源码解包下来（`--use-api` 走服务端解包，不需要本地 Docker）。下载落在临时目录，**不会覆盖仓库里的源文件**。
3. 逐文件 sha256 对比，报告三类差异：`missing`（commit 有、线上没有）、`extra`（线上有、commit 没有——遗留热修文件就是这一类）、`differs`（同名不同字节）。

退出码：

| 码 | 含义 | 应对 |
| --- | --- | --- |
| 0 | 线上字节与该 commit 完全一致 | 记录发布日志，完成 |
| 1 | 检测到漂移 | 走第 4 节 |
| 2 | **没能完成校验**（参数错、令牌缺失、CLI/网络失败、commit 不存在） | 修复环境后重跑；**绝不能当成 0 处理** |

`2` 和 `0` 被刻意分开：**"没看"不等于"看了没问题"**，把两者混为一谈正是 Issue #133 能潜伏这么久的原因。

CI 里同样的校验可以手动触发：Actions → Backend → Run workflow，填 `verify_commit`（默认当前 HEAD）与 `verify_function`。

### 3.4 记录发布

在 `docs/logs/<日期>-<主题>.md` 里记下：部署的 commit SHA、Management API 返回的线上 version 号、校验结果（脚本输出可直接粘贴）。

这条记录不是形式主义——第 4 节的回滚**依赖它**：回滚目标定义为"上一份已验证的部署"，没有记录就没有回滚目标。

## 4. 校验失败与回滚

### 4.1 第一原则

> **发现漂移时，绝对不要用"当前 checkout 出来的东西"直接覆盖上去把校验弄绿。**

漂移意味着线上有一份没人知道来源的代码。它可能是一次热修（线上比仓库新，覆盖 = 丢失修复，这正是 Issue #133 的情形），也可能是一次失败/部分完成的部署（线上比仓库旧）。**在判明方向之前覆盖，等于用一个未知换另一个未知。**

### 4.2 先判明方向

```bash
node backend/scripts/verify-deployed-function.mjs \
  --function generate-weekly-plan --commit "$RELEASE_SHA" \
  --project-ref "$SUPABASE_PROJECT_REF" \
  --dump-dir ./deployed-snapshot          # 保留下载下来的线上代码

diff -ru backend/supabase/functions ./deployed-snapshot/supabase/functions
```

看 diff 的**语义方向**，而不只是"有没有差异"：

- 线上有仓库缺失的**行为修复** → 线上更新。走 4.3。
- 线上是仓库某个更旧 commit 的内容 → 部署落后。走 4.4。
- 线上有仓库完全没有的文件（`extra`） → 手工上传的残留。走 4.3，且在把它的意图并回仓库之前不要部署。

`--dump-dir` 拿到的快照可以用 `--deployed-dir` 离线重复比对，不必反复访问线上：

```bash
node backend/scripts/verify-deployed-function.mjs \
  --function generate-weekly-plan --commit <任意 commit> \
  --deployed-dir ./deployed-snapshot/supabase/functions
```

配合 `git log` 二分，可以直接定位"线上这份到底对应哪个 commit（如果有的话）"。

### 4.3 线上比仓库新（有热修）

1. **先把线上的修复变成 `main` 上的 commit**（带测试），走正常 PR 流程。Issue #133 里这一步就是 PR #130。
2. 合入后从新的 `main` commit 重新部署（3.2），再校验（3.3）。
3. 校验通过后，`main` 重新成为唯一事实源，漂移解除。

**在第 1 步完成之前不要部署任何东西。** 此时任何一次部署都会抹掉线上那份唯一存在的修复。

### 4.4 线上比仓库旧 / 部署损坏，需要回滚

Supabase 不提供"把线上回退到 version N"的命令，**回滚 = 从上一份已验证的 commit 重新部署一次**：

```bash
LAST_GOOD_SHA=<第 3.4 节发布记录里最近一次校验通过的 SHA>

git checkout "$LAST_GOOD_SHA"
supabase functions deploy generate-weekly-plan \
  --project-ref "$SUPABASE_PROJECT_REF" --workdir backend

SUPABASE_ACCESS_TOKEN=sbp_… \
node backend/scripts/verify-deployed-function.mjs \
  --function generate-weekly-plan --commit "$LAST_GOOD_SHA" \
  --project-ref "$SUPABASE_PROJECT_REF"     # 必须返回 0

git checkout main
```

针对本 issue 的硬性约束（来自 Issue #133）：

- 回滚目标必须是**行为上确实是"仅周日 20:00–23:59 开窗"的那一份**。校验脚本只保证"字节 = 某个 commit"，不保证"那个 commit 的业务逻辑是对的"——所以回滚目标必须同时满足：在发布记录里校验通过，**且** `git show <sha>:backend/supabase/functions/_shared/generationWindow.mjs` 里的谓词是 `weekday === 0 && hour >= 20`。
- **禁止用 `main@12fc897` 覆盖线上。** 那个 commit 里的谓词是写反的（`weekday !== 0 || hour >= 20`），部署它会让下周计划在周一凌晨提前生成、拿不到本周真实训练数据，而真正的周日 20:00 那次运行会因为"计划已存在"变成永久空转。`12fc897` 之后的 `main`（`341b2a7` 起）已包含 PR #130 的修复，不受此限制。

### 4.5 回滚的时间敏感性

生成窗口一周只开一次。如果漂移是在**周日 20:00 之前**发现的，按上面流程处理即可；如果是在窗口期间或之后发现的，注意 `install_generated_plan` 的 C21 约束——它拒绝写入当前周或过去的周，所以**错过的那一周无法靠补跑找回**，只能等下一个周日。这不是脚本的缺陷，是约束的正确行为；处理时应据此判断是否需要人工干预用户的当周计划。

## 5. 这套机制覆盖什么、不覆盖什么

**覆盖：**

- 线上函数源码与某个确定 commit 的逐字节一致性（含遗留文件、缺失文件）。
- 干净 checkout 下的 Node 测试与 Deno 打包（`.github/workflows/backend.yml` 的 `tests` / `bundle`）。
- 相对 import 闭包的正确性：新增/删除共享模块会自动进入比对范围，无需维护清单。

**不覆盖（已知残余风险）：**

- **远程依赖的版本漂移。** `index.ts` 引用 `https://esm.sh/@supabase/supabase-js@2`，是一个浮动的 major 范围。仓库文件逐字节相同，不代表两次部署解析到的 `supabase-js` 小版本相同。要消除这一项需要把远程依赖钉到确定版本或引入 import map + lockfile，是独立的改动。
- **Edge Function 的运行时环境。** Secrets（如 `DEEPSEEK_API_KEY`）、`config.toml` 的函数级配置、Vault 里的 generation secret 都不在比对范围内。
- **数据库侧。** 迁移、RPC（`install_generated_plan` / `replan_plan_days`）、pg_cron 调度不由这个脚本校验。
- **部署与校验之间的时间窗。** 校验证明的是"运行这条命令的那一刻线上是这份字节"。任何人在此之后手工改线上，都要等下一次校验才会被发现。定期（例如每周日 20:00 之前）跑一次 `workflow_dispatch` 可以把这个窗口压到可接受范围。

## 6. 首次启用时的预期结果

线上当前的 v10 是**手工热修**产物，而仓库已经把窗口谓词重构进了 `_shared/generationWindow.mjs`。两者行为一致，但字节几乎肯定不同——**所以第一次跑校验一定会报 DRIFT，这是正确的**。

正确的收敛顺序是：

1. 确认 `main` 上的谓词是 `weekday === 0 && hour >= 20`（PR #130 已合入）且 `Backend` workflow 绿；
2. 按 3.2 从该 commit 部署一次；
3. 按 3.3 校验，必须得到 0；
4. 按 3.4 记录，这条记录成为后续所有回滚的第一个"已验证部署"基线。

在第 3 步返回 0 之前，`main` 都还不是唯一事实源，Issue #133 也不算真正关闭。

### 6.1 第一次跑之前要先确认下载布局（待带凭据验证）

脚本的纯逻辑部分（import 闭包求解、三类差异的判定与退出码）已由
`backend/tests/verifyDeployedFunction.test.mjs` 覆盖，并用「本地构造一份线上快照」的方式端到端跑通了 0 / 1 / 2 三条路径。但**有一件事在没有 Supabase 凭据的情况下无法验证**：`supabase functions download --use-api` 把 eszip 解包成什么目录结构。

脚本假定它写出的是 `<workdir>/supabase/functions/` 下、与仓库同构的相对路径（即 `generate-weekly-plan/index.ts` 与 `_shared/*.mjs`）。如果 CLI 实际把共享模块摊平或换了前缀，第一次校验会把**所有**文件同时报成 `missing` + `extra`——那是布局不匹配，不是真的漂移。

所以第一次运行时用 `--dump-dir` 先看一眼实际结构：

```bash
node backend/scripts/verify-deployed-function.mjs \
  --function generate-weekly-plan --commit "$RELEASE_SHA" \
  --project-ref "$SUPABASE_PROJECT_REF" --dump-dir ./deployed-snapshot
find ./deployed-snapshot/supabase/functions -type f
```

**判据**：如果差异是"每个文件都既 missing 又 extra，且路径互为改写"，先修脚本里的路径映射；只有在两侧路径集合能对上之后，剩下的差异才是真正的字节漂移。这一步做完并记录一次成功的校验之后，本节即可删除。
