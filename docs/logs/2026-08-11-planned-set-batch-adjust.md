# 计划组目标批量调节实现记录

需求：截图中的「编辑重量 / 编辑次数」轮盘一次只改一组，一个动作 4 组要点 4 次。
先补**接口**（写路径打通到 ViewModel），再按用户要求接上 **UI 入口**（见文末「UI 入口」一节）。

## 接口形状

```swift
// Models/TrainingPlanModels.swift
struct PlannedSetBatchAdjustment {
    enum WeightChange { case uniform(Double?, unit: WeightUnit), delta(Double) }
    enum RepsChange   { case uniform(Int),                       delta(Int)    }
    var weight: WeightChange?   // nil = 这一维不动
    var reps: RepsChange?       // nil = 这一维不动
    func applied(to set: TrainingPlanSet) -> TrainingPlanSet
}

// TrainingPlanServiceProtocol / LocalAppDatabase
func batchUpdatePlannedSets(planExerciseId:adjustment:) async throws -> TrainingPlanExercise

// TodayWorkoutViewModel.batchUpdatePlannedSets(planExerciseId:adjustment:)
// FutureDayPlanEditorViewModel.batchUpdateSets(planExerciseId:adjustment:)
```

## 设计决策与理由

1. **作用域＝一个计划动作（`planExerciseId`）下的所有未完成组**，对应截图里「本组」这张卡片。已完成组跳过：它们通过 `linkedExerciseSetId` 关联着已落库的训练记录，事后改目标只会让计划与「实际练了什么」对不上；要改仍走单组的 `updatePlannedSet`。
2. **重量与次数各自可选**，直接对上需求里的「重量**或者**数量」——只改一维时另一维一个字节都不碰。
3. **`Double?` 不足以表达「不改」**：`targetWeight` 里的 `nil` 已经表示「自重 / 未设定」，所以重量单独建模成 `WeightChange` 枚举。
4. **同时支持 `uniform` 与 `delta`**：截图里卧推是 45 / 52 / 55 / 55 的递增结构，统一值会把这个结构抹平；`delta` 保留结构（自重组无基数可加减，不受影响）。`delta` 按每组自己的 `targetWeightUnit` 计——同一动作内不会混单位（单位建组时由用户偏好统一写入），这样也不引入换算产生的小数噪声。
5. **一次写盘**：全部组改完才 `persist()`，不存在改到一半的中间态，云端也只收到一次推送；写盘失败时 `persist()` 已有的回滚会把 `state`（含刚追加的编辑事件）整体还原。逐组调 `updatePlannedSet` 拿不到这三条中的任何一条，这也是为什么接口下沉到 `LocalAppDatabase` 而不是在 ViewModel 里循环。
6. **复用 `set_target_updated` 事件**：每个真正变化的组记一条，载荷仍是既有的 before/after 快照，后端与学习回路的消费方不需要认识新事件类型。
7. **no-op 不留痕**：空调节、无未完成组、或调节后值没变（例如把 40kg 又「改成」40kg）时不写盘、不记事件，避免噪声事件污染学习回路读的那条信号。
8. **协议默认实现抛错**（与 `completePlannedCardio` 同一套处理）：既有 8 个 mock / 测试替身不感知这个方法也能满足协议，不必逐个补空实现；默认抛错而非返回编造的动作，调用方能区分「没改成」和「改成了」。
9. **乐观更新与落库共用 `applied(to:)`**：`TodayWorkoutViewModel` 先按同一份规则改本地状态，再以返回的动作为准；界面先显示的值不会和最终落库的值算成两样。失败沿用既有处理：`errorMessage` + `refresh()`。

## UI 入口

沿用用户已经熟悉的那条路径（点 40kg → 轮盘 → 完成），只加一个 opt-in 开关，不新增第二套入口：

- `WheelSheetChrome` 在轮盘与「取消/完成」之间多一行 `Toggle`，文案 `today.plan.batch.apply_to_all`（en `Apply to all unfinished sets` / zh-Hans `应用到所有未完成组`）。整行只在调用方提供批量回调时出现。
- `WeightWheelEditSheet` / `RepsWheelEditSheet` 各加一个可选回调 `onDoneApplyingToAllSets`：勾选后「完成」走它，没勾还是原来的单组 `onDone`。**它必须声明在 `onCancel` 之后**——既有三个调用点用尾随闭包传 `onDone`/`onCancel`，按 SE-0279 的匹配规则，把新参数插到前面会让尾随闭包静默绑错参数（编译得过、行为全错）。记录动作卡与手动记录表单那两个调用点因此一行未改。
- 开关的出现条件收得比"有多组"更紧：本动作**还剩 2 组以上未完成**（只剩一组时批量等于单组），**且当前编辑的这一组自己未完成**（批量写入跳过已完成组，勾了却连当前这组都不变会让人以为没生效）。两个条件都对齐"批量实际会改哪些组"，affordance 不承诺它做不到的事。
- 重量面板提交 `weight: .uniform(...)`、次数面板提交 `reps: .uniform(...)`——只动被编辑的那一维，正好对上需求里的「重量**或者**数量」。
- 面板高度按是否显示开关加 52pt，否则轮盘或按钮会被挤出可见区。
- 两个宿主都接上：今日页 → `TodayWorkoutViewModel.batchUpdatePlannedSets`；未来日 → `FutureDayPlanEditorViewModel.batchUpdateSets`。

`delta`（整组一起 +2.5kg）仍然只有接口、没有 UI——轮盘天然表达的是绝对值，相对调节需要另一种控件，留到有明确需求时再加。

## 未做（明确的边界）

- **没有覆盖训练记录（`WorkoutServiceProtocol`）侧的批量改**：截图是计划卡片。记录侧若要同样能力，照本次形状加一份即可。
- 无 Supabase 迁移 / Edge Function 改动：计划组目标随现有全量快照推送，Schema 与 RLS 都不受影响。

## 测试

新增 `PeakLogTests/PlannedSetBatchAdjustmentTests.swift`（XCTest，落在 `ios.yml` 的 CI 门禁内）：

- 纯函数：只改重量 / 只改次数、清成自重、`delta` 保留 45→47.5 / 52→54.5 / 55→57.5 的递增结构、自重组不被 `delta` 影响、重量下界 0 与次数下界 1、空调节恒等。
- 本地库：改写全部未完成组并确实落库、**三组只触发一次 `onChange`**（即一次写盘一次推送，批量存在的理由）、已完成组保持原值、每个变化的组一条 `set_target_updated`（校验 before/after 重量）、空调节与「值没变」两条 no-op 路径都不写盘不记事件、未知 `planExerciseId` 抛 `planExerciseNotFound`。

写盘次数用 `armCloudSync` 的 `onChange` 计数（`mutationSeq` 只在 `ownerUserId != nil` 时推进，测试里没走登录路径，拿它断言会恒真）。

`PeakLogTests` 由 `PBXFileSystemSynchronizedRootGroup` 同步，新文件无需改 `project.pbxproj`。

UI 接线另加 `tests/plan_set_batch_ui_contract_test.swift`（源码契约，仓库既有形式，不在 CI 覆盖内）：锁死「批量回调排在 onCancel 之后」这条尾随闭包陷阱、开关的两个出现条件、两个面板各自只提交一维、两个宿主都接到了 ViewModel、以及 en/zh-Hans 文案齐全。这些断言已用等价的脚本逐条比对过当前源码，全部命中。

**验证状态**：本次在 Linux 容器内完成，没有 Swift 工具链，`xcodebuild` 与 `tests/` 下的 swiftc 脚本都未能本地运行；编译与测试结论以 PR 上的 iOS workflow 为准。

## 与 #168（训练进行中快速修改重量与次数）合并后的补充

本分支开发期间 `main` 合入了 #168，它改变了两条前提，合并时一并跟上：

1. **计划侧的编辑必须打进进行中 session 的快照**。#168 发现 `confirmPlanLiveWorkout` 落库读的是 session 快照，因此把 `updatePlannedSet` 接上了 `applyTargetToLiveSession`，并用 `tests/quick_set_edit_contract_test.swift` 锁死。`batchUpdatePlannedSets` 是同一类入口（训练最小化时用户照样能在普通计划卡上批量改），漏掉这一步等于把 #168 刚修好的 bug 从新口子放回来——因此批量路径逐组调用 `applyTargetToLiveSession`，并把 `batchUpdatePlannedSets(` 加进那份契约测试的入口清单。原先文档里「不改写 activeLiveWorkout，与单组编辑保持一致」的说法随之作废：单组编辑现在改写它了。
2. **取值规则只能有一份实现**。#168 建立了 `QuickSetAdjustment` 作为 ± 步长与钳制的唯一来源，`PlannedSetBatchAdjustment.applied(to:)` 里手写的 `max(0,…)` / `max(1,…)` 因此改为调用 `QuickSetAdjustment.clampedWeight` / `clampedReps`，边界值不再有第二套定义。由此新增的依赖边（`TrainingPlanModels` → `QuickSetAdjustment`）已同步补进 `tests/cloud_mapper_roundtrip_test.swift` 与 `tests/training_reminder_schedule_test.swift` 的 swiftc 文件清单。

`delta` 目前仍不吸附到 `QuickSetAdjustment` 的 0.25 刻度网格（该常量是 private，且 delta 尚无 UI 入口）。真要接 UI 时需要先把网格暴露出来复用，否则可能算出轮盘选不中的值。
