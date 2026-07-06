# 移除生产服务层 Mock 类型计划

- 查引用：全局搜索三个 Mock 类型，确认无生产调用。
- 加边界测试：检查 `PeakLog/Services` 不声明 `MockProfileService`、`MockWorkoutService`、`MockTrainingPlanService`。
- 删除声明：从三个服务文件移除 Mock 包装类或别名。
- 保留真实服务：不改 `Local*Service` 协议实现。
- 验证：运行边界测试，执行 iOS Simulator 构建。
- 记录：在 `docs/logs` 写入本次需求完成日志。
