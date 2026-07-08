# Calendar 今日计划误完成修复方案

- 根因口径：计划字段和训练记录是双写完成态，但历史页只应相信训练记录。
- 数据层加入完成态清洗：`linkedExerciseSetId` 必须能在 `strengthSessions` 中找到。
- `completedAt` 单独存在不再构成有效完成。
- `replaceAll`、`mergeFromCloud` 后立即清洗，阻断云端脏状态进入 UI。
- `activePlan()`、`todayPlan()` 读取时兜底清洗，覆盖旧本地缓存。
- 保留 `completePlannedSet` 的正常路径：完成时创建训练记录 set，再写回计划链接。
- 保留删除记录后的回退逻辑：删除 set 后清空计划链接。
- 回归测试覆盖无训练记录的完成标记被清除。
- 回归测试覆盖有真实训练 set 的完成标记被保留。
- 用 XcodeBuildMCP 跑测试和模拟器构建启动验收。
