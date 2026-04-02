# 2026-04-02 历史页 / 今日页 / 聊天气泡计划卡 本地化清理实现日志

## 本次目标
- 对历史页、今日页、聊天里的计划卡做一轮系统性本地化清理
- 统一固定文案与参数化文案的写法
- 把新历史页完成记录组件一并纳入 `Localizable.xcstrings`

## 范围评估
- backend：未修改
- iOS App：已修改

## 核心改动
### 1. 增加本地化辅助层
- 新增 `PeakLog/Support/LocalizedPlanText.swift`
- 统一承接以下高频格式化文案：
  - `Week of`
  - 已完成组数
  - 周计划摘要
  - 跑步摘要
  - 历史页完成训练摘要
  - 计划状态标签
  - 周几标签

### 2. 历史页收口
- `HistoryScreen.swift`
  - 周计划标题与摘要改为统一 helper 输出
- `HistoryCompletedTrainingSection.swift`
  - 新完成记录组件中的标题、副标题、badge、metric、source label、未记录重量等文案全部切到本地化 key
- `HistoryPlanDaySection.swift`
  - `Today` 标签改为本地化输出

### 3. 今日页收口
- `TodayWorkoutScreen.swift`
  - 顶部标题
  - 摘要卡
  - 跑步摘要
  - section 标题与副标题
  - 手动添加跑步 sheet
  - AI overlay 状态标题/副标题
  - overlay 周计划卡与今日变化卡
  - RPE 菜单文案
  - 全部切到 key 或 helper

### 4. 聊天气泡计划卡收口
- `MessageBubbleView.swift`
  - 周计划卡 `Week of` 改为 helper
  - 训练日状态由 `capitalized` 改为本地化状态标签

### 5. 顺手补齐的零散兼容项
- `VoiceWaveformView.swift`
  - 语音录制 / 转写可访问性文案本地化
- `PRSummaryCard.swift`
  - `First recorded PR` 本地化
- `TrainingPlanModels.swift`
  - `weighted / unknown` 占位文案改为本地化 key

### 6. 字符串表
- 扩展 `PeakLog/Localizable.xcstrings`
- 新增历史页 / 今日页 / 计划卡相关语义 key
- 为之前只有 source text、没有中英文翻译的部分旧 key 补了 `en` / `zh-Hans`

## 验证
- `swiftc -parse-as-library PeakLog/Support/LocalizedPlanText.swift tests/localized_plan_text_test.swift -o /tmp/localized_plan_text_test && /tmp/localized_plan_text_test`
- `swiftc -parse-as-library PeakLog/Models/WorkoutModels.swift PeakLog/Models/HistoryCompletedModels.swift PeakLog/Support/WorkoutDateFormatter.swift tests/history_completed_training_aggregation_test.swift -o /tmp/history_completed_training_aggregation_test && /tmp/history_completed_training_aggregation_test`
- `xcodebuild -scheme PeakLog -destination 'platform=iOS Simulator,id=8AB8FBD4-8664-4A06-B763-DDB33DBC0DB9' -derivedDataPath /tmp/PeakLogDerived build`

## 结果
- 上述测试与构建均通过
- 本次需求仅修改 iOS App，不需要推送 Supabase

## 剩余说明
- 本轮按你的要求重点清理了历史页、今日页、聊天计划卡，以及与之直接相关的可访问性 / PR 文案
- 项目其他页面仍可能存在零散旧写法，但这三个最影响观感的区域已统一到同一套本地化路径
