# 动作库与动作选择器 — 技术方案（方案 A 持久化 + 方案 3 Picker 先行流程）

需求文档：`docs/requirements/2026-07-06-exercise-library-picker.md`

## 改动总览

| 文件 | 改动 |
|---|---|
| `PeakLog/Models/ExerciseLibraryModels.swift` | **新增**：`ExerciseDefinition` / `MuscleGroup` / `Equipment`，搜索归一化工具 |
| `PeakLog/Resources/exercise_library.json` | **新增**：种子库（~150 动作，双语 + aliases + popularity），bundle 资源 |
| `PeakLog/Services/ExerciseLibraryService.swift` | **新增**：加载种子库、合并自定义、搜索/筛选/最近使用推导 |
| `PeakLog/Services/LocalAppDatabase.swift` | `LocalAppState` 增加 `customExercises`（decode 容错默认 `[]`）；`addCustomExercise` |
| `PeakLog/Models/TrainingPlanModels.swift` | `TrainingPlanExercise` 增加可选 `exerciseId` |
| `PeakLog/Models/WorkoutModels.swift` | `Exercise` 增加可选 `exerciseId` |
| `PeakLog/Models/PlanExerciseFormModel.swift` | `PlanExerciseDraft` 增加 `exerciseId`；`DailyRecordExerciseInput` 携带来源动作 |
| `PeakLog/Views/Today/ExercisePickerScreen.swift` | **新增**：Picker 全部 UI（搜索/chips/分区列表/底部 CTA/自定义创建小 sheet） |
| `PeakLog/Views/Today/AddPlanExerciseSheet.swift` | 重构：NavigationStack root = Picker，push 表单页；表单「添加动作」pop 回追加 |
| `PeakLog/Views/Today/DailyRecordSheet.swift` | 同构接入 Picker 先行流程 |
| `PeakLog/Views/Today/ExerciseFormComponents.swift` | header 动作名从 TextField 改为只读文本（名称来自库/自定义） |
| `PeakLog/Localizable.xcstrings` | 新增 `exercise_picker.*`、肌群/器械枚举文案（en / zh-Hans） |
| `tests/exercise_library_search_test.swift` | **新增**：搜索归一化 / 别名命中 / 双语命中 / 筛选 |
| `tests/exercise_picker_recent_test.swift` | **新增**：最近使用推导（最近度+频次排序、只取实际历史） |
| `tests/local_state_decode_compat_test.swift` | **新增**：旧 JSON（无新字段）decode 兼容 |

## 数据模型

```swift
enum MuscleGroup: String, Codable, CaseIterable { case chest, back, legs, shoulders, arms, core, fullBody }
enum Equipment: String, Codable, CaseIterable { case barbell, dumbbell, machine, cable, bodyweight, kettlebell, other }

struct ExerciseDefinition: Identifiable, Codable, Equatable {
    let id: String            // 稳定 slug："barbell-bench-press" / 自定义 "custom-<uuid>"
    var nameEN: String
    var nameZH: String
    var aliases: [String]     // 小写归一化匹配
    var muscleGroup: MuscleGroup
    var equipment: Equipment
    var loadType: ExerciseLoadType   // 复用现有枚举
    var popularity: Int       // 组内排序权重，自定义固定 0（置顶于"我的动作"）
    var isCustom: Bool
}
```

- 种子 JSON 顶层 `{ "version": 1, "exercises": [...] }`；`ExerciseLibraryService` 启动加载一次并缓存。
- 展示名按 `LocalizationManager` 当前语言取 `nameZH`/`nameEN`；搜索无视界面语言同时匹配两者 + aliases（全部 lowercase + 去空白归一化）。
- 兼容性关键点：`LocalAppState` 新字段用 `decodeIfPresent` 默认 `[]`（自定义 `init(from:)` 或属性默认值 + 手写 CodingKeys），保证旧本地文件可加载；`exerciseId` 全链路可选，旧数据不迁移。
- 最近使用：从 `strengthSessions` 推导——按动作归一化名（优先 exerciseId）聚合，排序键 =（最近训练日期 desc，出现次数 desc），取前 10。不落库。

## 种子库内容策略
- 覆盖：胸/背/腿/肩/臂/核心/全身 × 杠铃/哑铃/器械/绳索/自重/壶铃，约 150 条，健身房高频动作优先（卧推系、深蹲系、硬拉系、划船系、推举系、下拉系、弯举/臂屈伸、腿举/腿屈伸、核心、壶铃摆动等）。
- 每条含中英名 + 常见别名（如 bench/bp/平板卧推）；popularity 按常用度 0–100 人工分档。
- 生成后单独给用户过目清单再定稿。

## Picker UI 规格（无卡片，字体分层）

结构（自上而下，通栏平铺，无 glassPanel/圆角容器）：
1. 导航栏：inline 标题「选择动作」，取消按钮 `textSecondary`。
2. 搜索框：唯一的填充控件，`workoutShell` 填充 + `AppRadius.xl`，高 40，不自动聚焦；沿用 `dismissKeyboardOnTap()`。
3. 肌群 chips：水平滚动胶囊，未选中 `Capsule().fill(workoutPanel)` + `textSecondary` 12pt medium；选中文字 `accentValue` + 细琥珀描边（复用 loadTypeToggle 语法）。选中肌群后其下方浮现器械二级 chips（同样式、更小 11pt）。
4. 分区标签：11pt medium `textMuted`、字距加宽，仅文字 + 上方留白 20 / 下方 8，无背景。
5. 动作行（通栏，高 ~56）：
   - 动作名 15pt semibold `textPrimary`；选中时变 `accentValue`。
   - 副信息 11pt rounded `textMuted`："杠铃 · 胸"；最近使用行追加"上次 60 kg × 8"，数字部分 rounded + `accentValue`。
   - 行尾勾选：未选 `circle`（textDarkMuted）/ 选中 `checkmark.circle.fill`（accentPrimary）。
   - 行间用 `appSeparator` 0.5pt 发丝线（左侧对齐文本缩进），无行背景、无圆角。
6. 「创建自定义动作」：列表底部常驻虚线行（复用 `AddExerciseDashedButton` 语法：琥珀 0.4 透明度虚线描边、`accentPrimary` 文字）；搜索无结果时同样式行内嵌搜索词。点击弹 280 高小 sheet（`presentationDetents([.height(280)])`，与 ValueEditSheet 同语法）：名称（预填搜索词）/ 肌群 / 负重方式，确认后入库并自动选中。
7. 底部 CTA：`LinearGradient.accentGradient` 胶囊「添加 N 个动作」，悬浮于安全区上方；选中数为 0 时不显示。

## 流程接线（方案 3）
- `AddPlanExerciseSheet` 重构为：`NavigationStack { ExercisePickerScreen(...) }`，确认后 `navigationDestination` push `ExerciseFormListPage`（即现有卡片编辑流，视觉不动），卡片由所选 `ExerciseDefinition` 预建：名称只读、`isBodyweight = (loadType == .bodyweight)`、默认 3 组。
- 表单页 `AddExerciseDashedButton` → pop 回 Picker（已选状态保留，已进表单的动作在列表中标记为已添加不可重复勾选）。
- 保存路径不变：`PlanExerciseDraftBuilder` → `addPlannedExercises`，draft 新增携带 `exerciseId`。
- `DailyRecordSheet` 以相同结构接入（同一个 `ExercisePickerScreen`，回调不同）。

## 动画规格（全部复用现有曲线，尊重 Reduce Motion）

| 场景 | 动画 |
|---|---|
| chips 筛选 / 搜索词变化 → 列表 diff | `.spring(response: 0.3, dampingFraction: 0.85)`，行 `.transition(.opacity)`（高频操作，刻意不加位移） |
| 器械二级 chips 出现 | 同上 + `.move(edge: .top).combined(with: .opacity)` |
| 勾选/取消勾选 | checkmark `.transition(.scale.combined(with: .opacity))` + `.sensoryFeedback(.selection)` |
| 底部 CTA 出入场 | `.transition(.move(edge: .bottom).combined(with: .opacity))`，dockSpring `.spring(response: 0.35, dampingFraction: 0.82)` |
| CTA 计数变化 | `.contentTransition(.numericText())` |
| Picker → 表单页 | 系统 push；进入后卡片以 0.3/0.85 弹簧按 50ms 错峰插入（不跨页做 matchedGeometryEffect） |
| 搜索无结果 → 虚线创建行 | `.transition(.opacity.combined(with: .scale(scale: 0.95)))` |
| Reduce Motion | 跟随 TodayWorkoutScreen 惯例：降级 `.easeInOut(duration: 0.2)`，scale/move 只保留 opacity |

## 实施顺序
1. 模型 + 种子库 JSON + `ExerciseLibraryService` + `LocalAppDatabase` 扩展（含 decode 兼容），配三个 `tests/` 逻辑测试。
2. `ExercisePickerScreen` UI + 动画。
3. `AddPlanExerciseSheet` / `DailyRecordSheet` 流程重构 + `ExerciseFormCard` header 只读化。
4. 文案本地化、种子库清单给用户过目、模拟器手动验收。

## 验收
- `tests/` 下逻辑测试（swiftc）全部通过；`xcodebuild test`（PeakLogTests）通过。
- 旧 `peaklog-local-state.json`（无新字段）加载不丢数据。
- iOS 26 iPhone 17 Pro Max 模拟器手动验证：零输入命中最近使用、肌群+器械筛选、双语/别名搜索、多选批量添加、自定义创建自动选中、自重动作表单联动、各过渡动画流畅且 Reduce Motion 下不炫技。
