# Plan Live Workout

- Plan 页右下角加号是一个菜单：「添加训练计划」（手动新增今日计划动作）和「手动记录」（原 `DailyRecordSheet`，力量/自重/有氧）。
- 「添加训练计划」不做任何自动生成，只接受手动输入：动作名称、负重类型（负重/自重）、目标重量、目标次数、组数；今日为 Rest 时会新建/转化为今日计划。
- 有今日计划且组数 > 0 时显示「开始训练」；Rest（0 组）不展示该按钮。
- 点击「开始训练」进入独立的全屏训练执行页 `TrainingSessionScreen`，展示今日计划的**全部动作和全部组**（不再只显示当前一组）。
- 训练执行页每一组行右侧有一个对勾，可随时点击完成/取消完成该组（不要求按顺序），并实时更新总进度。
- 训练执行页底部提供「结束并保存」（写入已完成的组）和「取消本次训练」（放弃本次会话，不落库）。
- 系统 Live Activity 展示当前（下一个未完成）动作，并提供「完成动作」按钮；App 内对勾与 Live Activity 按钮共用同一个完成组集合。
- Live Activity 按钮完成的组回到 App 后合并到同一个计划完成集合。
- Confirm 只写入尚未落库的完成组，避免重复提交。
- Liquid Glass 只用于可交互按钮、执行卡片、底部 dock 和关键面板；低版本使用 material fallback。
- 验收：源码验收、Live Session 单测、PeakLogTests 全量通过、iOS 26.4 iPhone 17 Pro Max build/install/launch 通过。
