# 移除生产服务层 Mock 类型

- 需求：从生产服务层移除 `MockProfileService`、`MockWorkoutService`、`MockTrainingPlanService`。
- 背景：三者无生产调用，继续放在 `PeakLog/Services` 会让运行服务和假数据支撑职责混在一起。
- 范围：只移除生产服务层声明；保留 `LocalProfileService`、`LocalWorkoutService`、`LocalTrainingPlanService`、`EmptyTrainingPlanService` 的现有行为。
- 非范围：不重构 Preview 数据源，不引入新的测试替身，不改训练记录业务行为。
- 风险：隐藏引用会在编译或全局搜索中暴露；当前全局搜索未发现生产调用。
- 验收：`PeakLog/Services` 不再包含这三个 Mock 名称。
- 验收：边界测试 `service_layer_mock_boundary_test` 通过。
- 验收：iOS 主 scheme 构建通过。
