# Issue #63 保存失败不应关闭 Sheet

- 根因：`GoalSpecEditorScreen`、`AddPlanExerciseSheet`、`DailyRecordSheet` 的 `async` 回调返回 `Void`；ViewModel 捕获并吞掉服务错误，Sheet 无法区分成功与失败，任务完成后无条件 `dismiss()`。
- 范围：将保存契约改为 `async throws`；ViewModel 仅在成功后更新状态并返回结果；Sheet 负责保存中状态、失败 inline error、重复提交保护，成功才关闭。
- 不改动：`LocalAppDatabase` transaction 实现、数据库 schema、Supabase 迁移。
- 测试：先以失败 ProfileService 写 RED 测试证明保存错误需向上传播；GREEN 后运行该 XCTest、相关 ViewModel 测试和 iOS 26.5 iPhone 17 Pro Max 全量测试。
- 风险：调用方需处理新的 throwing API；网络错误文本直接展示系统 localizedDescription，未引入新本地化 key。
