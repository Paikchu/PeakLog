# 有氧训练计划交付记录

## 实现范围

- B 范围：跑步、骑行、椭圆机、爬楼机。
- 周计划条目支持力量/有氧判别；有氧目标按类型保存时长、可选距离和可选 RPE。
- Today 使用独立有氧卡片与完成表单；有氧不进入力量专注训练的组数流程。
- Today 的添加入口支持选择力量或有氧；四种有氧均可手动加入今日计划，并按类型填写目标指标。
- 手动添加会记录完整 `exercise_added` 事件，保留活动类型、时长、距离和 RPE，供后续计划生成上下文使用。
- 手动记录与历史卡片按活动类型展示；椭圆机和爬楼机不接收距离。
- 完成计划有氧时，实际记录与计划关联在一次本地持久化事务中写入；重复完成被拒绝。
- 生成器、重排上下文与 RPC 支持有氧；完成过力量或有氧的日期都禁止重排。

## 验证证据

- `git diff --check`：通过。
- `jq empty PeakLog/Localizable.xcstrings`：通过。
- `node --test backend/tests/*.test.mjs`：99/99 通过。
- `swift tests/cardio_plan_ui_contract_test.swift`：通过。
- `plan_edit_event_recording_test`：通过，覆盖手动有氧新增事件载荷。
- `cloud_pull_merge_test`：通过，覆盖离线有氧完成标记与关联记录在云拉取后的保留。
- `cardio_model_test` 与 `cloud_mapper_roundtrip_test`：通过。
- iOS Simulator 通用构建：`BUILD SUCCEEDED`。
- `CardioPlanCompletionTests`：手动添加与完成流程 2/2 通过。
- `TodayWorkoutFocusFlowTests`、`TodayWorkoutLiveSessionTests` 与此前有氧定向用例：11/11 通过。
- 构建产物已安装并启动于 iPhone 17 Pro Max / iOS 26.5；主界面完成云端拉取并正常渲染，运行日志无崩溃。

## 未执行与风险

- 完整 XCTest 套件仍在基线首个 `AuthStateManagerTests.testConcurrentExpiredTokenRequestsUseOneRefresh` 启动后无输出；定向 11 项测试在同一模拟器正常通过，按仓库环境排查规则终止了卡住的 host 进程。
- Docker Desktop 未运行，未执行本地 `supabase db reset`；迁移通过静态契约测试，但尚未在本地 Postgres 应用。
- 未执行人工模拟器视觉验收、离线重启流程及中英文大字号逐项检查。
- migration 与 Edge Function 改动仅存在本地；未部署 Supabase，未创建 commit 或 PR。
