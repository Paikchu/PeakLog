# 动作选择器情境推荐 — 技术方案（本地规则打分）

需求文档：`docs/requirements/2026-07-06-exercise-picker-recommendations.md`

## 改动总览

| 文件 | 改动 |
|---|---|
| `PeakLog/Services/ExerciseRecommendationEngine.swift` | **新增**：纯函数推荐引擎（肌群最近训练日、共现计数、打分、硬排除），swiftc 可测 |
| `PeakLog/Services/ExerciseLibraryService.swift` | 协议增加 `fetchTodaysTrainedDefinitions()`（今日计划动作 ∪ 今日已记录动作，解析为库定义） |
| `PeakLog/Views/Today/ExercisePickerScreen.swift` | 「最近使用」区替换为「为你推荐」区；勾选变化实时重排（复用 pickerSpring）；行样式不变，上次摘要沿用 recents 数据装饰 |
| `PeakLog/Localizable.xcstrings` | 新增 `exercise_picker.suggested_section`（en "SUGGESTED" / zh "为你推荐"） |
| `tests/exercise_recommendation_test.swift` | **新增**：恢复规避/顺势推荐/协同递进/今日豁免/冷启动/limit |

## 推荐引擎

```swift
nonisolated struct RecommendationContext {
    let library: [ExerciseDefinition]
    let sessions: [WorkoutSession]              // 全量历史
    let todaysSelections: [ExerciseDefinition]  // picker 勾选 ∪ 已加表单 ∪ 今日计划 ∪ 今日记录
    let today: Date
    let limit: Int                              // 默认 8
}

nonisolated enum ExerciseRecommendationEngine {
    static func recommend(_ context: RecommendationContext) -> [ExerciseDefinition]
}
```

单一入口纯函数——未来接入端上模型时只替换这一个函数的实现，调用方不动。

### 内部信号（全部从 sessions + library 推导，历史动作经 `resolveDefinition` 解析，解析不到的忽略）
- `lastTrainedDayByGroup: [MuscleGroup: Int]`——距该肌群上次训练的自然日数（用 `Calendar.dateComponents(.day)`；今日=0）。
- `coOccurrence: [String: Set<String> 计数]`——同一 session 内两两动作共现次数。
- `personalScore: [String: Double]`——频次 + 近度归一化（沿用 recents 的排序思想）。

### 硬排除
1. `todaysSelections` 中的动作 id。
2. 恢复规避：肌群 `lastTrainedDay ∈ 1...2`（胸/背/腿/肩/臂）或 `== 1`（核心/全身）→ 整组排除。**豁免**：该肌群 ∈ 今日已选肌群（`lastTrainedDay == 0` 或出现在 todaysSelections）→ 不排除（今日方向优先于恢复规避）。

### 打分（排除后取 top limit）
- **已选态**（todaysSelections 非空）：
  `3×共现分 + 2×肌群亲和分 + 1×个人常用分 + 0.5×popularity/100`
  - 共现分：候选与各已选动作的共现次数求和，除以本轮最大值归一。
  - 肌群亲和分：同肌群 1.0；协同肌群 0.6（映射：胸→[肩,臂]，背→[臂]，肩→[臂]，腿→[核心]，全身→[核心]，臂/核心→[]）；其他 0。**递进**：某肌群已选 ≥3 → 该肌群同肌群分降为 0.4，其协同肌群升为 0.8。
- **空态**：
  `2×肌群需求分 + 2×个人常用分 + 1×popularity/100`
  - 肌群需求分：`min(lastTrainedDay, 7)/7`，从未练过 = 1.0。
- 同分并列按 popularity、再按 nameEN 稳定排序（保证可测）。

## UI 接线
- Picker `@State recommendations: [ExerciseDefinition]`；`.task` 初算，`onChange(of: selection)`、confirm 回来后重算，`withAnimation(pickerSpring)` 赋值 → 行以 `.opacity` 过渡重排。
- 推荐区展示条件与原最近使用一致：`query 为空 && 无筛选`。行复用 `pickerRow`，上次摘要从既有 `recents`（`fetchRecentEntries`）按 definition.id 查表装饰，无摘要则只显示 器械·肌群。
- `todaysSelections` 组装：`selection ∪ alreadyAddedIds 解析 ∪ fetchTodaysTrainedDefinitions()`。
- `exercise_picker.recent_section` 键停用删除。

## 测试场景（tests/exercise_recommendation_test.swift）
1. 昨天练腿 → 推荐无腿部动作；3 天前练腿 → 腿部回归且需求分领先。
2. 昨天练核心 → 核心排除；前天练核心 → 不排除。
3. 已选卧推 → 卧推消失；历史常同练动作排最前；胸部动作优于无关肌群。
4. 胸已选 3 个 → 肩/臂动作升至同肌群之前。
5. 今日已记录胸训练 → 胸不被恢复规避排除。
6. 空历史 → popularity 降序；limit 生效。

编译源码清单沿用 `docs/logs/2026-07-06-exercise-library-picker.md` 记录的列表 + 新引擎文件。

## 验收
- 新逻辑测试 + 既有 5 个相关 swiftc 测试通过；`xcodebuild test` 通过。
- 模拟器手动验证：勾选卧推后推荐区实时重排且动画流畅；昨天练过的肌群不出现在推荐区但可通过 chips/搜索找到。
