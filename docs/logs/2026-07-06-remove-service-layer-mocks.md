# 移除生产服务层 Mock 类型

- 已移除 `PeakLog/Services/ProfileService.swift` 中的 `MockProfileService`。
- 已移除 `PeakLog/Services/WorkoutService.swift` 中的 `MockWorkoutService`。
- 已移除 `PeakLog/Services/TrainingPlanService.swift` 中的 `MockTrainingPlanService` 别名。
- 保留本地真实服务实现，运行路径继续使用 `Local*Service`。
- 新增 `tests/service_layer_mock_boundary_test.swift`，防止 Mock 类型回到生产服务层。
- 未改动现有 Preview 数据模型。
