## 第一性原理与协作方式

> 适用范围：本项目（PeakLog）内的协作，不是跨项目的通用规则。

- 第一性原理思考始终生效，不分场景：从原始需求和问题本身出发拆解，拒绝经验主义和路径盲从——不要因为“上次/惯例是这么做的”就照搬，先问这是不是当前问题的最短路径。不假设用户的目标已经完全清晰；目标模糊时停下来讨论，不要脑补细节后直接执行。
- **「直接执行 / 深度交互」两段式输出，只用于讨论技术方案或需求的场合**——即用户在提需求、做技术选型、定架构/实现路径、定修复计划这类存在多种可行路径、需要做取舍的场合。判断标准：这次回复背后是否在"选了一条路径而不是另一条"或"对一个模糊的要求做了解读"；如果是，就要有深度交互。
  - **直接执行**：按用户当前的要求和逻辑，给出任务结果。
  - **深度交互**：基于底层逻辑对用户的原始需求做审慎挑战，包括但不限于：这是否是 XY 问题（用户要的手段是否偏离了真实目标）、当前路径有什么弊端、有没有更优雅的替代方案。没有实质性质疑时如实说明“未发现更优路径”，不要为了凑格式硬找问题。
- **机械性执行不套用两段式格式**，直接给结果即可：运行命令、汇报状态、转述后台任务结果、确认/执行已经明确的操作（如合并已谈妥的 PR、push、跑测试）、纯信息查询。这些场合没有"路径可选"，强行分两段是凑格式。
- 与本文件其他流程条款的关系：这是技术讨论场景下的默认思考方式，其他章节里“直接执行、不要反问”一类的具体流程约定（如「Issue Fix 流程」收到修复请求直接给清单）不是对本节的豁免——清单/计划本身就是把方案摊开给用户核对、可被推翻的载体，产出清单这个动作仍然是技术方案讨论,深度交互要在同一次回答里给出，而不是省略。

## 项目目标

- 构建个人健身助手：按 7 日周期，依据训练历史和健身目标生成后续训练计划；相邻训练日错开主要肌群。
- 记录训练数据、个人 PR，以及力量、有氧、自重等训练模式。
- 支持用户通过对话修改页面内容，包括添加记录、更新偏好和调整训练计划。

## 目录

- `PeakLog/`：iOS App 源码；包含 Views、ViewModels、Models、Services、Localization、Theme 和 Resources。
- `PeakLog/Services/Cloud/`：iOS 侧 Supabase 数据访问、同步、映射、快照加载与云端状态。
- `PeakLog/Services/Auth/`：iOS 侧 Supabase Auth、会话持久化与认证状态。
- `PeakLogTests/`：XCTest 覆盖的 iOS 单元测试。
- `tests/`：可独立运行的 Swift 回归与契约测试。
- `tools/exercise-media/`：动作库与演示动画的生成脚本与输入数据；`PeakLog/Resources/` 下的 `exercise_library.json`、`exercise_details.json`、`ExerciseMedia/` 都是生成物，改动作库请改这里的输入再重跑，勿直接编辑生成物。媒体版权属 Gym visual，署名不可移除，详见该目录 README。
- `backend/supabase/`：Supabase 后端源码和 CLI 配置。
- `backend/supabase/config.toml`：本地 Supabase 项目配置与 Auth Provider 配置；不得写入密钥。
- `backend/supabase/migrations/`：Postgres Schema、RLS、RPC、触发器、Storage 与定时任务迁移；只新增迁移，不改写已部署迁移。
- `backend/supabase/functions/`：Supabase Edge Functions；每个函数独立目录并以 `index.ts` 为入口。
- `backend/supabase/functions/_shared/`：多个 Edge Function 复用的 prompt、LLM、校验、上下文与数据访问模块。
- `backend/tests/`：Edge Function 共享模块、提示词和数据库安全边界的 Node 测试。
- `docs/architecture/`：系统架构、业务流、ADR 与 API 契约。
- `docs/requirements/`、`docs/plans/`、`docs/logs/`：已确认需求、实现计划和交付记录。

## 工程原则

- 保持 Agent 原生：由 prompt、工具调用与结构化输出驱动决策；不以硬编码条件或表达式匹配替代模型判断。
- Agent 方案先调研当前最佳实践；涉及模型能力、工具调用或 Supabase AI 能力时，使用官方资料验证。
- iOS 与 Supabase 的契约同时演进：Schema、RLS、Edge Function、客户端模型和错误状态必须一致。
- iOS target 跑 **Swift 6 language mode**，且 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`——App 里**没写隔离标注的声明默认是 `@MainActor`**（Issue #137）。由此有三条常踩的规则：
  - `nonisolated` 只作用于它所在的那一个声明。给类型加了 `nonisolated` **不会**传染到它的 `extension`；DTO / 纯模型的 `init(from:)`、`Equatable`、静态工具方法写在 extension 里时，extension 自己也要写 `nonisolated`，否则会变成主线程隔离，跨 actor 解码直接编译不过。
  - 会被后台 actor 或 `async let` 用到的类型（cloud DTO、service 协议、纯函数工具）显式写 `nonisolated`（协议再按需 `: Sendable`），不要依赖推断。
  - 需要跨并发域共享可变状态时用锁把它包起来（仓库既有写法：`NSLock` + `@unchecked Sendable`），不要用 `nonisolated(unsafe)` 压制诊断——那只是关掉检查，不是让它安全。
- 仓库源码保持零 Swift 告警：CI（`.github/workflows/ios.yml`）会扫 `xcodebuild` 日志，`PeakLog*/` 下出现任何 warning 即判失败。
- 不提交密钥、Service Role Key、用户数据或本地配置；通过环境变量、Secrets 或 Keychain 注入。
- 默认在功能分支开发。只有通过本地验收、PR 审查且获得合并授权后，才合并到 `main`。

## 收尾产物

- 功能完成且验收通过后，询问是否需要创建 commit 与 PR。

## 需求开发流程

1. **需求对齐**：复述目标、目标用户、验收标准和不做的范围；列出不明确处、数据影响、权限影响及失败路径。信息不足时一次只确认一个会改变方案的关键问题。
2. **需求文档确认**：以产品视角把已对齐的范围、交互、数据变化与验收方案写入 `docs/requirements/<日期>-<主题>.md`；用户确认后进入技术设计。
3. **现状与可行性检查**：定位 iOS 页面、状态流、Supabase 表/RLS/Storage/Edge Function 和已有测试；确认是否需要迁移、是否涉及线上数据，以及可回滚方式。
4. **开发计划确认**：以技术负责人视角将改动文件、数据契约、迁移顺序、Edge Function 部署、测试矩阵、模拟器验收步骤和风险写入 `docs/plans/<日期>-<主题>.md`；用户确认计划后再实施。
5. **分支与实施**：从最新 `main` 创建功能分支。先完成数据迁移和 RLS，再实现或更新 Edge Function，最后接入 iOS；每一步保留可独立验证的状态。仅在用户已授权且变更可回滚时部署 Supabase 线上资源。
6. **本地验证**：运行相关单元测试、集成测试和构建；用 iOS 26.5 的 iPhone 17 Pro Max Simulator 覆盖主路径、空态、网络失败、权限拒绝、重复提交及迁移后兼容性。
7. **变更交付**：同步更新受影响的 `docs/` 文档和交付日志，整理实际验证结果、未覆盖风险和部署状态。完成后询问是否需要创建 commit 与 PR。
8. **创建 PR**：获得确认后提交清晰、范围单一的 commit，推送分支并创建面向 `main` 的 PR；PR 描述关联需求、Schema/RLS 影响、部署步骤、验证证据和回滚方式。
9. **Code Review 与合并**：审查 diff、测试结果、权限边界、数据迁移安全性和 iOS 错误处理；修复所有阻塞意见并重新验证。用户授权后合并 `main`，确认 CI 通过与线上状态正常。

## Issue Fix 流程

收到「修复 issue #a #b #c…」（或类似指令）时，**不要先反问，直接产出一份修复清单**（见下方「修复清单」格式），按下面的分诊与分组方法编好批次；用户确认范围后再进入并行实施。清单本身就是第 3 步的修复计划确认物料。

1. **Issue 分诊**：拉取每个 Issue 的当前标题、Label、正文（复现条件、位置、修复建议）。按 Priority Label 排序：`P0 Critical` → `P1 High` → `P2 Medium` → `P3 Low`；同优先级内按代码区域归类（iOS View / ViewModel / Service / Model、Supabase Schema / RLS / Edge Function）。
2. **现状核实（先于分组）**：Issue 描述的文件路径、行号、代码片段可能已随 `main` 演进而漂移或失效——**分组前先用 grep/Read 核实每个 Issue 涉及的代码现状**，记录：位置是否漂移、问题是否已被之前的修复顺带解决（若已解决，直接标记为「验证后关闭」，不进入实施批次）、实际涉及的文件清单。
3. **批次分组（分组即分并行任务）**：
   - 计算每个 Issue 实际改动会涉及的文件集合，构建「Issue × 文件」矩阵。
   - **文件集合有交集的 Issue 必须分进同一个 Track**（同一分支/同一 worktree/同一 PR），避免两个 agent 同时改同一份 Swift 文件。
   - 文件集合无交集的 Issue 之间互相独立，各自或合并成尽量少、粒度合理的 Track。
   - 若两个 Issue 的“自然”修复方案会撞同一个文件（例如都想改同一个 ViewModel），优先选择能避免交集的实现层——例如把其中一个改到 View 层的本地 `@State`、而不是 ViewModel，使两个 Track 保持零交集；只有确实无法避免时才把它们合并进同一 Track。
   - `Localizable.xcstrings` 等 JSON 资源文件例外：多个 Track 都可能追加新 key，只要 key 不同 Git 通常能自动合并，不必强制合并 Track，但要在清单里标注「共享文件，可能需 rebase」。
   - 每个 Track 标注：包含哪些 Issue、主要改动文件、与其他 Track 的冲突关系（无交集 / 共享 xcstrings 需 rebase / 需在某 Track 合并后才能改）。
4. **修复计划确认**：把分组结果连同每个 Issue 的根因证据、最小修复范围、回归风险、测试方案，写成「修复清单」发给用户确认；涉及 Supabase 线上变更的 Issue 额外说明部署影响。用户确认范围后再动手。
5. **并行实施**：
   - 一个 Track = 一个 git worktree = 一个分支 = 一个 agent = 一个 PR。
   - 给每个 agent 的任务描述必须包含：涉及 Issue 编号与原始描述、需要先核实的现状（文件是否已漂移）、具体修复方案、明确的 out-of-scope 边界（“不要动 X，那是 Issue #Y 的范围，避免和另一个 Track 打架”）、验证步骤（build + 相关测试 + 必要时模拟器手测）、Git/PR 要求（新分支、`Fixes #N` 关联对应 Issue、不自行合并）。
   - 多个 Track 并行跑 `xcodebuild test` 时，遵守「并行 Worktree 下 xcodebuild test 卡顿排查」一节：先确认 `Simulator.app` 常驻，`xcodebuild test` 本身在 host 级别串行执行，不要多个 Track 同时跑测试。
6. **验收与 PR**：每个 Issue 在其 Track 内单独复现验证并覆盖回归路径；PR 描述包含根因、修复说明、测试证据、`Fixes #N`；若某个 Issue 核实后发现已不成立，直接在 Issue 上留言说明依据并关闭，不必进 PR。
7. **Review（合并前必做，不能只看 agent 摘要）**：
   - `gh pr view <N> --json mergeable,mergeStateStatus,statusCheckRollup,reviewDecision` 确认无冲突、CI（若有）通过。
   - `gh pr diff <N>` 通读实际 diff——agent 的文字总结可能遗漏边界情况，必须亲自过一遍代码逻辑，重点看：单位/时区/本地化等易错点是否真的按方案处理、有没有遗留的重复实现未同步修、删除的 key/符号是否还有其他引用点（`grep` 确认）。
   - 有疑问就现场追加检查（如另 `grep` 一遍受影响的调用点），不要因为“测试通过”就跳过代码走读。
8. **合并**：逐个 `gh pr merge <N> --merge`（保持仓库现有的 merge commit 风格，不要擅自改成 squash/rebase）；worktree 分支删不掉是预期行为（分支仍被 worktree 占用），不算失败。合并后用 `gh issue view <N> --json state` 确认关联 Issue 已自动关闭；若干 PR 之间有共享文件，按合并顺序逐个确认下一个 PR 仍然 `MERGEABLE`，出现冲突时该 PR 自行 rebase 后再合并。
9. **收尾**：记录残余风险、未覆盖场景、后续事项；提示用户本地 `main` 落后 origin 时可执行 `git pull`，并说明遗留的 worktree 是否需要清理。

### 修复清单格式

收到修复请求时，用下面结构给出（可以是消息里的 Markdown，不必强制落盘成 `docs/plans/` 文件，除非用户要求或批次较大值得留档）：

```md
## 修复清单（<日期>）

现状核实：<列出与 Issue 原始描述不符的地方,例如行号漂移、已被其他修复覆盖>

优先级排序：P0 → ... → P3（本批次范围内的 Issue 编号）

Track A — <一句话概括>
  Issues: #x #y
  主要文件: <路径列表>
  冲突关系: <与其他 Track 的关系>

Track B — ...

冲突矩阵：<有共享文件的 Track 两两说明>
执行顺序建议：<第一波并行 / 第二波 / 需要等前面合并后才能做的部分>
```

## 并行 Worktree 下 xcodebuild test 卡顿排查

多个 worktree/agent 并行跑 `xcodebuild test` 时，本机沙箱环境会出现两类间歇性失败，根因是 `Simulator.app` 的 GUI 进程默认不常驻，且模拟器启动服务（`SBMainWorkspace`）按 host 而非按模拟器隔离：

1. **快速失败**：`Simulator device failed to launch ... SBMainWorkspace ... Busy ("Application failed preflight checks")`，几十秒内报错。触发条件是两个 `xcodebuild test` 进程在相近时间启动同一个 bundle id，哪怕用的是不同模拟器 UDID。
2. **无限期卡死**：不报错，日志停在某个测试用例 "started" 后再无输出，可能卡几十分钟。**卡住的通常是整个测试套件里第一个执行的用例**——卡点在"app 启动/attach test host"这一步，不是该测试自身的代码逻辑问题；不要因为卡在某条并发测试上就误判该测试有并发 bug，先排除环境因素。

**排查步骤：**

1. 判断是真卡死还是仍在编译：`ps -o pid,etime,stat,command -p <xcodebuild PID>`，看 `ELAPSED` 是否远超正常编译+测试耗时；日志（`| tee` 出的文件）若几分钟无新增行，视为卡死。
2. 确认 `Simulator.app` 是否常驻：`ps aux | grep "Simulator.app/Contents/MacOS/Simulator"`；不在则 `open -a Simulator` 并等待其常驻后再重试。
3. 确认没有并发争抢：`xcrun simctl list devices booted` 与 `ps aux | grep xcodebuild`，若发现多个模拟器或多个 `xcodebuild test` 进程同时存在，先让它们排队而不是同时跑。
4. 确认卡死后直接 `kill -9` 该 `xcodebuild` 进程，清空残留模拟器/进程，重新确认 `Simulator.app` 仍在跑，再重试；不要无限等待同一个卡死进程恢复。

**避免复发：**

- 开始并行任务前先手动 `open -a Simulator` 一次并确认常驻。
- 每个 `xcodebuild test` 调用固定加 `-parallel-testing-enabled NO -disable-concurrent-destination-testing`，并指定一个已 boot 好的具体模拟器 UDID，禁止 Xcode 自动生成并行 clone。
- 多个 worktree 并行改代码没问题，但**实际执行 `xcodebuild test` 的那一步在 host 级别串行**，同一时刻全局只跑一个测试进程。

## Code Review 模板

```md
## 审查范围

- PR：#<编号>
- 关联需求 / Issue：#<编号>
- 变更摘要：<一句话说明>

## 审查结论

- 结论：Approve / Request changes / Comment
- 阻塞项：<无 / 关联 Issue Priority Label、文件路径、行号、问题、建议修复>
- 非阻塞项：<无 / 问题与建议>

## iOS 检查

- [ ] 状态流、并发隔离和主线程更新正确。
- [ ] 空态、加载态、错误态、重复操作和离线场景可用。
- [ ] iPhone 17 Pro Max Simulator 已覆盖主路径与回归路径。
- [ ] 相关单元测试、回归测试和构建通过。

## Supabase 检查

- [ ] 迁移只新增，具备向前兼容性与回滚方案。
- [ ] RLS、RPC、Storage 和 Edge Function 的用户归属校验正确。
- [ ] 未暴露 Secret、Service Role Key 或用户数据。
- [ ] 已验证部署步骤、失败处理和线上影响。
```

## GitHub Issue 模板

```md
## 标题

<模块>：<用户可感知的问题或目标>

> 标题不得包含 `P0`、`P1`、`P2` 或 `P3`；优先级仅使用 GitHub Label 标记。

## 元数据

- Priority Label：`P0 Critical` / `P1 High` / `P2 Medium` / `P3 Low`
- Labels：<Priority Label>、<类型>、<模块>
- 类型：Bug / Feature / Tech Debt / Security
- 模块：iOS / Supabase Database / RLS / Edge Function / Sync / Auth
- 影响版本：<版本号或 commit>

## 背景与影响

<谁在什么场景下受到什么影响；量化范围或说明未知。>

## 复现步骤

1. <前置条件>
2. <操作>
3. <操作>

## 实际结果

<可观察到的结果、错误信息、日志或截图。>

## 预期结果

<正确结果。>

## 验收标准

- [ ] <可验证行为>
- [ ] <回归场景>
- [ ] iOS / Supabase 测试或模拟器验证证据已附上。

## 排查线索

- 相关代码：<路径、类、函数或迁移>
- 相关日志 / 请求 ID：<链接或脱敏内容>
- 数据与权限影响：<无 / 表、RLS、RPC、Storage、Edge Function>

## 上线与回滚

- 部署步骤：<无 / migration、function deploy、App 发布>
- 回滚方案：<无 / 具体命令或恢复策略>
```
