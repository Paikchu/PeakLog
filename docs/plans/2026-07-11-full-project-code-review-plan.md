# PeakLog 全项目代码审查计划

## 审查策略

- 固定 `origin/main..HEAD` 与工作区状态；以远端可见的 `eece9ed` 为 Issue 证据基线。
- 先读取开放 Issue 和 2026-07-08 历史审查结果，建立去重矩阵。
- 按领域并行审查，最后由主审查者逐条复核，避免把静态线索直接当成 Bug。

## 工作流

### 1. 基线与自动验证

- 记录 Swift/Xcode、Supabase CLI、Node/Deno 版本与可用性。
- 执行 iOS build/test、后端单元测试、迁移语法/重放检查、配置与密钥扫描。
- 汇总编译警告、失败测试和环境限制；失败项进入根因调查，不直接创建 Issue。

### 2. iOS 架构、逻辑与类型安全

- 检查依赖方向、组合根、服务协议、ViewModel 生命周期、错误传播与状态所有权。
- 审查 Swift Concurrency：Actor 隔离、`Task` 生命周期、取消、Sendable、刷新竞态与主线程工作量。
- 审查本地数据库、CloudMapper、同步合并/删除语义、日期时区、单位换算、Codable 向后兼容。
- 检查强制解包、静默默认值、字符串类型替代、ID 归属与跨模块契约。

### 3. Supabase 后端与安全

- 根据当前 Supabase changelog 与官方文档校验 RLS、RPC、`SECURITY DEFINER`、Cron 和 Data API 暴露规则。
- 顺序读取全部迁移，检查新库重放、回滚/兼容、外键、唯一约束、索引、触发器和权限。
- 对所有 exposed tables 建立 RLS/policy 矩阵；验证 `USING`/`WITH CHECK`、所有权谓词、函数执行权限和 `search_path`。
- 对照 Swift CloudRows/CloudMapper/PostgREST 请求与 SQL schema，检查字段、枚举、可空性与删除语义。
- 审查 Edge Function 输入验证、身份传递、模型调用、超时、重试、错误脱敏与资源上限。

### 4. UX 流程与可访问性

- 走查登录/登出、首次云拉取、离线编辑、前后台切换、冲突合并、训练开始/完成/撤销、计划编辑与历史回看。
- 检查 loading/error/empty 状态、破坏性操作确认、重复提交、导航返回、键盘、Dynamic Type、VoiceOver 和本地化。
- 只为可定位到代码根因并有明确用户影响的问题创建 Bug；纯设计建议单独标为 `P3` enhancement。

### 5. 独立复审与证据收敛

- 按 `superpowers:requesting-code-review` 模板派发独立 reviewer，提供基线 SHA、需求文档和全项目范围。
- 主审查者复验每项发现，排除已修复、重复、仅存在于未提交工作区或证据不足的问题。
- 将关联问题按共同根因合并，确定 `P0`—`P3`。

### 6. GitHub Issue 发布

- 通过 GitHub connector 再次搜索标题与关键符号，确保不重复。
- 每个确认问题单独创建详细 Issue；优先使用仓库已有 priority/type/area 标签。
- 创建后回读 Issue，确认正文、标签、链接与格式完整。

### 7. 交付与记录

- 新建 `docs/logs/2026-07-11-full-project-code-review.md`，记录范围、验证命令、发现、排除项与 Issue 映射。
- 输出按优先级排序的 Issue 链接、风险摘要、测试限制与建议修复顺序。

## 风险控制

- 当前工作区有用户未提交改动；审查不覆盖、不暂存、不还原这些文件。
- hosted Supabase 仅做只读检查；任何 SQL 写入、迁移、部署均不在本轮授权内。
- GitHub Issue 创建是外部写操作，只发布主审查者已复核的确认项。
- 全项目审查不能证明没有缺陷；交付会标明静态验证与运行时验证的边界。
