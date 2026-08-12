# 灵动岛信息层级重设计 — 实现计划

需求：`docs/requirements/2026-08-12-live-activity-information-hierarchy.md`

## 改动文件

| 文件 | 改动 |
| --- | --- |
| `PeakLogShared/PlanLiveActivityShortName.swift` | 新增。动作名 → 2–4 字简称的纯函数。 |
| `PeakLogShared/PlanLiveActivityAttributes.swift` | `ContentState` 增三个字段 + 向后兼容解码；`Attributes` 增 `plannedTotalSetsCount`；`contentState(for:)` 抽出共用构造。 |
| `PeakLog/Services/LiveActivityManager.swift` | `trimmedAttributes` 透传裁剪前的总组数。 |
| `PeakLogLiveActivityExtension/PeakLogLiveActivityBundle.swift` | 四态 UI 重写。 |
| `tests/live_activity_short_name_test.swift` | 新增。缩写规则 + 动作库全量扫描。 |
| `tests/live_activity_information_hierarchy_test.swift` | 新增。ActivityKit 门禁内文件的源码契约断言。 |

`PeakLogShared/` 在 Xcode 里是 `fileSystemSynchronizedGroups`（主 App 与扩展两个 target
都引用），新增文件自动进两个 target，不需要改 `project.pbxproj`。

## 数据契约

```swift
struct ContentState {
    let currentExerciseShortName: String     // P3
    let currentExerciseRemainingSets: Int    // P1
    let currentExerciseTotalSets: Int        // 展开态「共 4 组」
    ...
}

struct PlanLiveActivityAttributes {
    let plannedTotalSetsCount: Int?          // 裁剪前总数，进度分母
    var progressTotalSetsCount: Int { max(plannedTotalSetsCount ?? 0, totalSetsCount) }
}
```

剩余组数随 state 下发，**不在 Widget 里从 `attributes.exercises` 反推**：裁剪后当前动作
可能不在 attributes 里，反推会算出 0。两个 Int 的 payload 开销可忽略。

新增字段一律 `decodeIfPresent` + 兜底。App 升级时系统里可能还留着上一版编码的 Activity，
缺 key 直接抛错会让它从 `Activity.activities` 里消失，而 `update`/`end` 都靠遍历那份
注册表找 handle。

## 缩写规则

四步，命中即停：

1. `overrides` —— 规则读不通的 9 个动作，人工指定。
2. 逐层删修饰词：器械 → 体位 → 肢体/握法。信息量最低的先删；**位于词尾的不删**
   （「反向蝴蝶机」的蝴蝶机是动作本身，删了只剩「反向」）。
3. 从词尾匹配 `movementTerms` 里最长的核心动作词。
4. 兜底截取末 4 字（中文动作名修饰在前、动作在后，尾部信息量最大）。

已经 ≤4 字的名字原样保留——保留器械词能把同一天里的两个变式区分开（「杠铃卧推」不会和
「上斜哑铃卧推」撞成同一个「卧推」）。

拉丁文名字走另一条分支：取词尾一个词（`Incline Barbell Bench Press` → `Press`）。

## 测试矩阵

| 层 | 覆盖 |
| --- | --- |
| `tests/live_activity_short_name_test.swift` | 逐条规则断言；动作库 1328 条全量扫描（每条落在 2–4 字、不引入原名没有的字、英文名不产出空串）。 |
| `tests/live_activity_information_hierarchy_test.swift` | 剩余组数随 state 下发、进度分母是裁剪前总数、复合件被紧凑态与最小态共用、新字段 `decodeIfPresent`、进度比例夹在 0…1、无障碍标签。 |
| `tests/live_activity_manager_safety_test.swift` | 既有断言（#11 / #12 / #37）必须继续通过。 |

`PlanLiveActivityShortName` 刻意放在 ActivityKit 门禁**之外**的独立文件里，就是为了能被
主机 swiftc 直接编译执行——紧凑态左槽的可读性完全取决于这条规则，只做文本断言盯不住。

```bash
swiftc -O -o /tmp/short_test tests/live_activity_short_name_test.swift \
  PeakLogShared/PlanLiveActivityShortName.swift && /tmp/short_test
swiftc -O -o /tmp/hier_test tests/live_activity_information_hierarchy_test.swift && /tmp/hier_test
swiftc -O -o /tmp/safety_test tests/live_activity_manager_safety_test.swift && /tmp/safety_test
```

## 模拟器验收步骤

1. 开始一个含多个动作的训练，确认紧凑态左槽是简称、右槽是环 + 剩余组数。
2. 点「完成本组」，确认环内数字递减、环变长。
3. 做完某动作最后一组，确认左槽换名、数字跳成新动作总组数。
4. 全部完成，确认环走满 + `✓`，按钮禁用。
5. 起一个能触发 `trimmedAttributes` 的大计划（动作多到超 3.5 KB），确认进度分母仍是计划
   总组数，不出现超过 100%。
6. 同时开一个别的 Live Activity（如计时器），确认最小态显示环 + 数字。
7. 打开 VoiceOver，确认灵动岛读出完整语义。

## 风险

- **简称撞名**：4 字预算内无法区分所有变式，例如「硬拉」和「罗马尼亚硬拉」都落到「硬拉」。
  全名一次长按可见，可接受；后续若成问题再考虑同 session 内的去重后缀。
- **44 pt 宽度是估值**：紧凑态槽位宽度未在真机上量过，4 字简称配了 `minimumScaleFactor`
  兜底，需要真机确认不被裁切。
- **升级期的在飞 Activity**：`decodeIfPresent` 保证解码不失败，但旧 payload 缺剩余组数，
  会显示 0，直到 App 下一次 `update` 刷新。
