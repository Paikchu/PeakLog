# 技术方案：修复首页 Today 星期显示偏移

## 根因
首页 `TodayWorkoutViewModel` 在处理 `weeklyPlan` 流式块时，使用了：

- `ISO8601DateFormatter`
- `formatOptions = [.withFullDate]`

这套 formatter 默认按 GMT/UTC 工作，而项目其它训练日期链路主要使用 `WorkoutDateFormatter`，其内部绑定当前时区。两套逻辑混用后，在中国时区零点附近会把“今天”的 `yyyy-MM-dd` 算错，导致首页匹配到错误的 `planDate`，最终显示成错误星期。

## 方案
### 1. 统一首页 today 计划日期来源
- 删除 `TodayWorkoutViewModel` 内部单独的 `ISO8601DateFormatter.planDateFormatter`
- 改为统一使用 `WorkoutDateFormatter().string(from:)`

### 2. 抽取可测试 helper
- 在 `TodayWorkoutViewModel` 中新增 `currentPlanDateString(now:formatter:)`
- 目的：
  - 让日期逻辑可测试
  - 后续若要按自定义时区或 mock 时间验证，不必走 UI 事件链

### 3. 增加回归测试
- 新增 `PeakLogTests/TodayWorkoutViewModelDateTests.swift`
- 构造一个 UTC 时间点，其在上海时区已经进入第二天，验证返回的 `planDate` 必须是本地日历日，而不是 UTC 日期。

## 风险控制
- 风险较低，修改面集中在首页 today 匹配逻辑。
- 统一 formatter 后，首页和聊天/本地数据库的日期口径会更一致，属于收敛而非行为扩散。

