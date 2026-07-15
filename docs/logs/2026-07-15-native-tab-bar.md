# 原生 Tab Bar 交付记录

## 改动

- `ContentView` 改用 `TabView(selection:)` 承载日历、计划、设置三个原生 Tab。
- 三个 Tab 使用已有本地化文字与 SF Symbols，系统负责 iOS 26 Liquid Glass、选中态、点击反馈和 Home Indicator 安全距离。
- 删除自绘 `HomeDockBar`、选中胶囊、固定槽位和旧版材质降级代码。
- `HomeTab` 拆到独立文件，仅保留导航身份、标题和图标映射。
- iOS 26.1+ 的非专注态训练操作层使用动态 `tabViewBottomAccessory`，专注态真正禁用附件；iOS 26.0 使用 Tab 内容安全区 fallback。
- 训练专注态的 Tab Bar 显隐偏好挂在计划 Tab 内容上；进入专注态隐藏，收起训练后恢复。
- “完成当前组 / 完成训练”改用纯色胶囊，移除按钮自身 Liquid Glass 边缘。
- 修复无条件空 `tabViewBottomAccessory` 在专注态残留灰色系统胶囊的问题。

## 验证

- `swift tests/home_dock_navigation_test.swift`：通过。
- `swift tests/home_dock_fixed_rail_test.swift`：通过。
- `swift tests/today_workout_screen_overlay_layout_test.swift`：通过。
- XcodeBuildMCP 在 iPhone 17 Pro Max Simulator 构建、安装和启动成功。
- 运行时确认日历、计划、设置均可切换，系统无障碍树将三项识别为带中文标签的 `tab`。
- 运行时确认“训练进行中”位于 Tab Bar 上方，不覆盖文字。
- 运行时确认恢复专注训练后 Tab Bar 与空附件消失、`TrainingFocusBar` 保留且无灰色底层；收起训练后 Tab Bar 与训练附件恢复。
- 运行时点击“完成第 1 组”成功进入休息倒计时，主操作未被布局层拦截。

## 已知项

- 构建仍输出既有 Swift 并发隔离警告，涉及 `TrainingPlanModels.swift`、`CloudRows.swift`、`CloudSyncController.swift`、`CloudSyncCoordinator.swift`、`LocalAppDatabase.swift` 与 `WorkoutDateFormatter.swift`；本次导航改动未新增警告。
- 未修改 Supabase、训练数据模型或持久化路径。
