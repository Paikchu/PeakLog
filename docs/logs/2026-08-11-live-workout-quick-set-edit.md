# 交付记录：训练进行中快速修改重量与次数

**日期**：2026-08-11
**关联**：无需求文档（单点交互补齐，范围一次说清）；改动集中在专注模式（`#164` 引入的训练进行中体验）

## 背景

专注模式此前只能勾选组，组的目标值是只读的。而 `confirmPlanLiveWorkout` 落库时读的正是
**session 快照**里的 `targetWeight` / `targetReps`——也就是说，实际做了 65kg × 5 却按计划写着
60kg × 6 时，训练记录只能记成计划值。想改就得退出专注模式、回到浏览模式的卡片上点轮盘，
再回来继续练。

计划是开练前的估计，实际做的才是要落库的那份。这次把「改」这个动作放回训练现场。

## 实现改动

### 新增

- `PeakLog/Models/QuickSetAdjustment.swift`：`±` 的取值规则（`nonisolated` 纯值计算）。负重步长
  kg 2.5 / lbs 5；次数步长 1、下限 1；自重动作 `nil ⇄ 已加负重` 可互相到达，非自重动作钳在 0；
  每次调整吸附回负重轮的 0.25 刻度，避免连点后浮点漂移。UI 算下一档和 view model 落库前钳制
  共用这一份，两边不会分叉。
- `PeakLogTests/QuickSetAdjustmentTests.swift`：取值规则的独立断言（步长、自重边界、0 下限、
  连点 8 上 8 下精确回到起点、刻度吸附、钳制）。
- `tests/quick_set_edit_contract_test.swift`：结构契约（可变字段、共用取值规则、view model 接口、
  去抖与三处 flush、UI 接线、四个无障碍 key 的 en/zh-Hans 翻译存在且确有使用）。

### 修改

- `PeakLog/Models/PlanLiveWorkoutModels.swift`：`PlanLiveWorkoutSet` 的 `targetWeight` / `targetReps`
  由 `let` 改 `var`。这两个字段就是 confirm 时落库的值，不可变等于训练中改什么都到不了记录里。
- `PeakLog/ViewModels/TodayWorkoutViewModel.swift`：
  - 新增 `updateLiveWorkoutSet(setId:targetWeight:targetReps:)`。同时写 session（决定落库值）与
    `todayPlan`（决定退出专注模式后看到的值）；已在开练前落库的组（`isAlreadyCompleted`）拒绝修改，
    与「已落库的组不允许在 session 内撤销」同一条边界；顺带 `liveActivityManager.update`，
    灵动岛跟着变。
  - **顺带修掉的既有缺陷**：训练最小化时用户看到的是普通计划卡、走的是 `updatePlannedSet`，
    而那条路径此前完全不碰 session 快照——于是那次编辑会在结束训练时被静默丢掉，记进训练
    记录的还是旧数字。两个入口现在共用 `applyTargetToLiveSession(...)`。若不一并修，本次改动
    反而会让两条编辑路径的行为不对称，更难解释。
  - 计划侧写库去抖 600ms（`flushPendingPlanSetTargets()` / `writePendingPlanSetTargets()`）。
    连点 `+` 只写最后一档，并消除多个并发写请求完成顺序不定导致「落库的是中间那一档」。
    `confirmPlanLiveWorkout` / `cancelPlanLiveWorkout` / `flushPendingLiveWorkoutPersistence`
    三处强制 flush。写库回声若发现该组已有更新的待写值则跳过，不把本地盖回旧值。
- `PeakLog/Views/Today/TrainingFocusComponents.swift`：
  - 当前组下方出现快速档：`[− 2.5 kg +]` `[− 1 次 +]`，步长直接写在按钮之间，按下去之前就知道
    这一下加多少。
  - 任意未落库的组，点数值进精确档——复用既有的 `WeightWheelEditSheet` / `RepsWheelEditSheet`，
    没有引入第二套编辑器。`lastTime` 传 nil：上次成绩已在卡片顶部的上下文块里。
  - 已落库的组数值不可点（渲染成纯文本），不做「按下去没反应的按钮」。
- `PeakLog/Views/Today/TodayWorkoutScreen.swift`：`onUpdateLiveSet` 接线。
- `PeakLog/Localizable.xcstrings`：新增 4 个无障碍标签 key（en / zh-Hans）。

## 几个取舍

1. **`±` 只给当前组，精确档给所有未落库的组**。训练时真正要改的永远是手上这一组；其余行保持
   紧凑，否则四组动作卡会被八个按钮撑开。要修早先某一组（刚勾掉的第 2 组其实少做了一次），
   点数字进轮盘同样能改，且改完仍会落库到那一组。
2. **改一组就只改这一组，不向后传播**。4 组同重量时把第 2 组改成 65 会让人想「后面几组是不是
   也该跟着变」，但计划里存在 ramp-up（60/70/80/80）这类非均匀编排，自动传播会把它抹平。
   显式、可预期优先。
3. **快速档放在数值行下方而不是左右两侧**。内联进同一行在 iPhone SE 宽度（可用 ~315pt）下会
   溢出，三位数负重更甚；专注模式竖向空间本就富余。
4. **写库失败不 `refresh()`**。计划的其他写路径失败会整份拉回，但训练进行中拉回会用服务端的
   旧目标值盖掉用户刚改的数。session 快照不受这次失败影响，只报错。

## 验证结果

| 项 | 结果 |
| --- | --- |
| `tests/quick_set_edit_contract_test.swift` 的断言 | **未执行**（本环境无 Swift 工具链）；逐条用等价脚本比对源码，全部匹配 |
| `PeakLogTests/*`（新增 8 + 6 条用例） | **未执行**——需要 macOS + `xcodebuild test` |
| `xcodebuild build` | **未执行**——同上 |
| 模拟器手测 | **未执行** |

**本次交付未经编译与运行验证**：改动在无 Swift 工具链的 Linux 容器内完成，只做了逐行人工走查
与源码级契约比对。合并前需要在 macOS 上补齐：

1. `xcodebuild build`（确认 `PeakLog*/` 下 0 warning，CI 会因任何 warning 判失败）
2. `xcodebuild test`（新增用例见上表）
3. `swift tests/quick_set_edit_contract_test.swift`
4. iPhone 17 Pro Max / iOS 26.5 模拟器走一遍：`±` 改值 → 底部 CTA 与灵动岛同步 → 勾选完成 →
   结束训练 → 训练记录里是改后的值；以及**窄机型**（iPhone SE）下快速档不溢出

## 未覆盖 / 残余风险

- **窄屏布局未实测**。快速档已改为独立一行以规避内联溢出，但 SE 宽度下两个 group 加起来
  ~250pt 的估算未在真机/模拟器上量过。
- **`flushPendingLiveWorkoutPersistence()` 里的计划写库是 `Task{}`，退到后台时不保证跑完**。
  session 快照是同步落盘的，训练数据不会丢；最坏情况是计划侧的目标值晚一次同步。
- **本次没有给浏览模式的计划卡加 `±`**。那里已有点数值进轮盘的路径，且不在「训练现场快速改」
  这个问题范围内。
