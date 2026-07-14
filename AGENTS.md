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

1. **Issue 分诊**：按 Priority Label 排序：`P0 Critical` → `P1 High` → `P2 Medium` → `P3 Low`。标题不写优先级；每个 Issue 记录复现条件、影响范围、关联模块和可验证的修复标准，询问本轮要处理的范围。
2. **根因定位**：在改动前稳定复现问题，检查 iOS 日志、Supabase 日志、RLS 策略、迁移历史和 Edge Function 版本；区分客户端、数据、权限、网络与并发问题。
3. **修复计划确认**：说明根因证据、最小修复范围、回归风险、测试方案和是否需要线上 Supabase 变更。用户确认后开始修复。
4. **并行实施**：仅将无共享文件、无共享迁移和无部署依赖的 Issue 放入独立 worktree 并行处理；涉及同一数据契约或同一 Edge Function 的修复串行处理。
5. **验收与 PR**：每个 Issue 单独复现验证并覆盖回归路径；创建关联 Issue 的 PR，记录根因、修复、验证证据和迁移/部署影响。
6. **审查与合并**：完成 code review、CI 和模拟器验收后，逐个合并已获授权的 PR 到 `main`；合并后关闭 Issue，并记录残余风险或后续事项。

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
