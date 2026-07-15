# 统一训练选择器与有氧 RPE 精简交付记录

- 分支：`codex/unified-training-picker`，隔离 worktree 实施。
- “添加训练计划”直接进入“选择运动”；原力量选择器保留搜索、推荐、多选和自定义动作，有氧作为分类提供跑步、骑行、椭圆机、爬楼机。
- 有氧计划新增、手动记录、完成表单、计划卡、记录卡和历史展示均移除 RPE；力量组级 RPE 未改动。
- 新有氧草稿、完成记录、周计划生成与重排输出的兼容 RPE 均写入 `nil`；旧 RPE 字段仍可解码和云同步。
- 未知有氧类型从本地 JSON 解码时回退为跑步，避免单条未来类型导致整个本地状态重置。
- `CardioPlanCompletionTests` 2/2 通过；相关 Swift 合约、模型、草稿、事件、映射与本地状态兼容测试通过；后端 54/54 通过；iOS Simulator 构建通过。
- 完整 XCTest 套件三次卡在首个 `AuthStateManagerTests` 测试宿主启动；针对本次范围的 `CardioPlanCompletionTests` 单独运行正常，无断言失败。
- 用户随后授权线上部署；`20260715145641_add_cardio_training_plan` 已应用，7 个计划有氧列、2 个记录列、7 条约束、2 个有氧感知 RPC 与两张表 RLS 均核验通过。
- Advisor 发现新增关联外键缺少覆盖索引，已新增并部署 `20260715164521_add_cardio_link_index`；对应性能告警已清除。
- `generate-weekly-plan` 已发布为 v9，状态 `ACTIVE`、`verify_jwt=true`；线上包包含 `v3-cardio-no-rpe`/`replan-v3-cardio-no-rpe`，无凭证探测由网关返回 401。
- `install_generated_plan` 与 `replan_plan_days` 仅 `service_role` 可执行，`anon` 与 `authenticated` 均无执行权限；Advisor 未报告这两个 RPC 的安全问题。
- PR review 修复：力量卡追加有氧后合并提交；未完成力量卡阻止保存；未知计划有氧类型回退跑步；恢复肌群 chip 再次点选清除；力量-only 选择器恢复“选择动作”，统一选择器使用“选择运动”；删除三项无引用本地化键。
