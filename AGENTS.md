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

1. **Issue 分诊**：拉取并按 High → Low 排序 Issue；为每个 Issue 记录复现条件、影响范围、优先级、关联模块和可验证的修复标准，询问本轮要处理的范围。
2. **根因定位**：在改动前稳定复现问题，检查 iOS 日志、Supabase 日志、RLS 策略、迁移历史和 Edge Function 版本；区分客户端、数据、权限、网络与并发问题。
3. **修复计划确认**：说明根因证据、最小修复范围、回归风险、测试方案和是否需要线上 Supabase 变更。用户确认后开始修复。
4. **并行实施**：仅将无共享文件、无共享迁移和无部署依赖的 Issue 放入独立 worktree 并行处理；涉及同一数据契约或同一 Edge Function 的修复串行处理。
5. **验收与 PR**：每个 Issue 单独复现验证并覆盖回归路径；创建关联 Issue 的 PR，记录根因、修复、验证证据和迁移/部署影响。
6. **审查与合并**：完成 code review、CI 和模拟器验收后，逐个合并已获授权的 PR 到 `main`；合并后关闭 Issue，并记录残余风险或后续事项。
