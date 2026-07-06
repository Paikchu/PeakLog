# 收缩 WorkoutService 动作级编辑 API

- 移除 `WorkoutServiceProtocol.updateExerciseName` 和 `WorkoutServiceProtocol.deleteExercise`。
- 移除 `LocalWorkoutService`、`MockWorkoutService`、`LocalAppDatabase` 中对应实现。
- 清理 XCTest 和源码级测试里的 stub 方法。
- 当前保留的真实工作流：编辑 set、增加 set、删除最后一组、更新 RPE、创建力量/跑步记录。
- 不恢复动作级改名/整项删除 UX；如果后续需要完整记录编辑器，再作为独立需求设计。
