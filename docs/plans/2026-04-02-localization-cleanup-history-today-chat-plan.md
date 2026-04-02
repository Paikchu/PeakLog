# 历史页 / 今日页 / 聊天气泡计划卡 本地化系统清理技术方案

## 目标
在不改 backend 的前提下，统一历史页、今日页、聊天计划卡的本地化写法，消除英文硬编码、中文硬编码和直接插值带来的语言兼容问题。

## 改动范围评估
- `backend/`：不需要修改
- `PeakLog/`：需要修改
- 重点文件：
  - `PeakLog/Views/History/HistoryScreen.swift`
  - `PeakLog/Views/History/CalendarGridView.swift`
  - `PeakLog/Views/History/HistoryPlanDaySection.swift`
  - `PeakLog/Views/History/HistoryCompletedTrainingSection.swift`
  - `PeakLog/Views/Today/TodayWorkoutScreen.swift`
  - `PeakLog/Views/Chat/MessageBubbleView.swift`
  - `PeakLog/Views/Chat/VoiceWaveformView.swift`
  - `PeakLog/Views/Chat/PRSummaryCard.swift`
  - `PeakLog/Models/TrainingPlanModels.swift`
  - `PeakLog/Localizable.xcstrings`

## 设计原则
### 1. 统一文本来源
- 固定标题、按钮、空态、辅助说明一律使用本地化 key
- 参数化文案一律通过格式化 key 输出
- 避免在 SwiftUI View 中直接拼接用户可见字符串

### 2. 引入可测试的本地化辅助层
- 新增纯 Foundation 的本地化格式化辅助文件，承接：
  - `Week of %@`
  - `%lld / %lld sets completed`
  - 跑步摘要
  - 历史页已完成训练摘要
  - 计划状态文案
  - 周几标签
- 这样可以先写测试再接 UI，避免只靠手工扫代码

### 3. 历史页新组件整体纳入本地化
- 之前新增的 `HistoryCompletedTrainingSection` 已经解决了结构问题，但里面仍有大量中文硬编码
- 这次把标题、badge、summary chip、metric chip、source label 等全部纳入字符串表

### 4. 今日页与聊天计划卡对齐
- 今日页摘要卡、overlay 卡、聊天计划卡使用同一套：
  - `Week of %@`
  - `Today`
  - 计划状态标签
  - 跑步记录摘要

## 实施步骤
### Step 1. 先写测试
- 新增本地化辅助测试文件，覆盖：
  - `Week of` 格式化
  - `sets completed` 格式化
  - 跑步摘要格式化
  - 历史页力量/有氧摘要格式化
  - 计划状态本地化标签

### Step 2. 实现本地化辅助层
- 新增 `PeakLog/Support/LocalizedPlanText.swift`
- 提供静态格式化函数，避免页面各自拼接字符串

### Step 3. 替换页面文案
- 历史页：
  - `HistoryScreen`
  - `CalendarGridView`
  - `HistoryPlanDaySection`
  - `HistoryCompletedTrainingSection`
- 今日页：
  - `TodayWorkoutScreen`
  - 包括手动录入 sheet 和 AI overlay
- 聊天气泡：
  - `MessageBubbleView`
  - 同时清理顺手发现的 `VoiceWaveformView` / `PRSummaryCard`

### Step 4. 补齐字符串表
- 在 `Localizable.xcstrings` 中补充本轮新增 key 的 `en` / `zh-Hans`
- 保持已有 key 不回退

### Step 5. 验证
- 运行本地化辅助测试
- 运行 iOS 构建
- 静态复查目标文件，确认关键硬编码已被清理

## 风险与处理
- 风险：继续在 View 内零散拼接字符串，后续容易回退
- 处理：把易复用的标题和摘要收口到辅助层

- 风险：历史页已完成训练组件目前是未提交的新文件，修改时容易和已有改动混在一起
- 处理：不回退现有未提交功能，只在其基础上做本地化收口

## 验证方案
- `swiftc` 编译并运行本地化辅助测试
- `xcodebuild -scheme PeakLog -destination 'platform=iOS Simulator,id=8AB8FBD4-8664-4A06-B763-DDB33DBC0DB9' -derivedDataPath /tmp/PeakLogDerived build`
- `rg` 复查目标文件中是否仍残留关键英文/中文硬编码
