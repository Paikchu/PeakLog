# Issue #67 跨租户计划关联修复方案

## 根因

- 计划层级表重复保存 `user_id`，但外键只引用父记录 `id`；RLS 只能确认写入行声称属于当前用户，无法确认父记录也属于当前用户。
- `training_plan_sets.linked_exercise_set_id` 只引用 `exercise_sets.id`，允许攻击者把自己的计划组关联至其他用户的实际训练组。
- `generate-weekly-plan` 使用 service role，按关联 ID 批量读取 `exercise_sets` 时没有 `user_id` 条件，RLS 被绕过，受害者训练数据进入生成上下文。

## 修改

- 新增迁移，先清理不一致的历史层级数据并将跨租户 `linked_exercise_set_id` 置空，再建立包含 `user_id` 的复合唯一键与复合外键。
- 所有按用户组装上下文、读取嵌套计划的 service-role 查询显式增加 `user_id = currentUserId`。
- 抽取实际训练组读取函数，用 Node 测试验证查询链包含租户过滤；迁移契约测试验证四类关系均受约束。

## 验收

- RED：新查询测试因模块不存在失败；迁移测试因迁移不存在失败。
- GREEN：`node --test backend/tests/*.test.mjs` 全部通过。
- 静态检查确认 per-user service-role 查询没有只按计划 ID 或关联 ID 读取。
- 若本机 Supabase 可用，执行数据库重建验证迁移可应用；不可用时记录环境限制。
