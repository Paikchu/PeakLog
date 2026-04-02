# 2026-04-02 历史页已完成训练展示改造

## 背景
- 训练历史页当天内容原本使用松散的列表式展示。
- 力量训练和跑步记录视觉上割裂，且不符合首页卡片组件语言。
- 目标是保留在训练历史页内，只展示当天已完成并已保存的训练记录，不展示未完成计划动作。

## 本次实现
- 新增历史页只读聚合模型：
  - `CompletedDaySummary`
  - `CompletedStrengthExerciseViewData`
  - `CompletedStrengthSetViewData`
  - `CompletedCardioRecordViewData`
- 新增历史页只读展示组件：
  - `HistoryCompletedTrainingSection`
  - `HistoryCompletedDaySummaryCard`
  - `HistoryCompletedStrengthExerciseCard`
  - `HistoryCompletedCardioRecordCard`
- 历史页 `sessionList` 区域改为：
  - 顶部摘要卡
  - 力量训练 section
  - 跑步与有氧 section
- 力量训练卡使用与今日计划一致的卡片语言，但改为完全只读：
  - 保留动作头部、组级明细
  - 去掉编辑、勾选、增减组等交互
- 跑步记录改为与力量卡统一视觉语言的只读记录卡：
  - 展示里程、时长、配速
  - 保留来源和记录时间

## 展示语义
- 历史页当天只显示已完成并已保存的训练。
- 不再把未完成计划动作混入“当天完成训练”展示区域。
- 力量训练中：
  - 有明确重量时显示重量
  - 整个动作都没有重量时显示“自重”
  - 同一动作存在已记录重量，但某一组缺少重量时显示“未记录重量”

## 验证
- `xcodebuild -scheme PeakLog -destination 'platform=iOS Simulator,id=8AB8FBD4-8664-4A06-B763-DDB33DBC0DB9' -derivedDataPath /tmp/PeakLogDerived build`
- `swiftc -parse-as-library PeakLog/Models/WorkoutModels.swift PeakLog/Models/HistoryCompletedModels.swift PeakLog/Support/WorkoutDateFormatter.swift tests/history_completed_training_aggregation_test.swift -o /tmp/history_completed_training_aggregation_test && /tmp/history_completed_training_aggregation_test`

## 备注
- 本次改造只影响训练历史页，不改首页。
- backend schema 未改动，展示语义优先在 iOS 聚合层完成。
