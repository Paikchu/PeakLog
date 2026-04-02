# 2026-04-02 首页今日计划问题修复日志

## 本次完成内容

### 1. 修复重量编辑无法顺利完成的问题

- 为共享的 `ValueEditSheet` 增加了数字键盘工具栏完成按钮
- 让用户在 `decimalPad` / `numberPad` 场景下也能明确收起键盘
- 将首页今日计划中重量/次数编辑弹层高度从 `220` 提高到 `280`

### 2. 修复计划动作被错误显示为“自重”的问题

- 为训练计划动作新增显式字段 `exerciseLoadType`
- iOS 渲染不再用“`targetWeight == nil` 就是自重”这个错误语义
- 展示规则更新为：
  - `bodyweight` -> 显示“自重”
  - `weighted` 且无重量 -> 显示“待设置重量”
  - `unknown` 且无重量 -> 显示“未设置”

### 3. backend 计划生成链路同步升级

- 为计划 schema 增加 `exerciseLoadType`
- 为 `chat-send-message` 和 `ai-workout-action` 的计划写库/读库链路补齐 `exercise_load_type`
- 新增 Supabase migration，给 `training_plan_exercises` 表增加 `exercise_load_type`
- 更新 agent prompt，明确禁止“缺失目标重量时默认当成自重”

## 影响范围

- `PeakLog` iOS app
- `backend` Supabase Edge Functions
- `backend` Supabase migration

## 风险与后续事项

- backend 变更需要执行 Supabase migration 后才会完整生效
- 历史旧消息中的计划 block 没有新字段，iOS 已做兼容解码，缺失时回退为 `unknown`
