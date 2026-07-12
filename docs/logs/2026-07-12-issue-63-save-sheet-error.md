# Issue #63 修复记录

- 根因：保存回调为 `async -> Void`，ViewModel 吞掉持久化异常，Sheet 无条件 dismiss，用户输入丢失。
- 修复：GoalSpec、计划动作、训练记录保存回调改为 `async throws`；失败保持草稿与 Sheet，显示 inline 错误并禁用重复提交；成功才 dismiss。
- RED：新增 `SaveSheetErrorHandlingTests.testGoalSpecSavePropagatesFailureToKeepSheetOpen`，在旧 API 下编译失败（`Void` 无法转换为 `GoalSpec`）。
- GREEN：修复后目标测试 build-for-testing 通过；实际 test run 受 iPhone 17 Pro Max Simulator 启动/安装卡住，未取得 XCTest 运行结果。
- 未触碰 `LocalAppDatabase` transaction。
