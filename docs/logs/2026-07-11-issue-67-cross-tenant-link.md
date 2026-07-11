# Issue #67 跨租户计划关联修复

- 为计划、训练日、计划动作、计划组建立包含 `user_id` 的复合外键，数据库拒绝跨租户父子关联。
- 为 `training_plan_sets.linked_exercise_set_id` 与 `exercise_sets` 建立租户一致的复合外键。
- 迁移会删除层级归属不一致的历史子记录，并将跨租户实际训练组链接置空，避免约束上线失败或旧数据继续泄露。
- `generate-weekly-plan` 的用户上下文、嵌套计划、重规划、行为推断读取均显式按 `user_id` 过滤。
- 实际训练组读取额外过滤返回行的 `user_id`，即使底层查询异常混入其他租户数据，也不会进入 LLM context。
- 修正 `generate-weekly-plan` 的共享模块相对路径；远端首次部署复现 #70 的 module-not-found，修正后需重新部署验证。
- 新增查询行为、恶意历史关联、迁移完整性及 service-role 查询范围回归测试。
- 静态回归测试锁定新增共享模块从函数入口使用 `../_shared/` 相对路径。

## 验证

- RED：查询模块和迁移不存在，2 个测试失败；恶意混入返回行测试显示 `victim-set` 进入结果；行为推断测试显示三个计划层级查询缺少 `user_id`。
- GREEN：`node --test backend/tests/*.test.mjs` 通过。
- `git diff --check` 通过。
- Supabase CLI 2.75.0 可用；本机 Docker daemon 未运行，无法执行 `supabase db reset`。

## 远端 Supabase 验收

- `cross_tenant_plan_integrity` 已应用到项目 `fqyurmsuvtdafbnynurg`；六个复合外键均为 `convalidated = true`。
- 清理后 `training_plan_sets` 与 `exercise_sets` 的跨租户关联计数为 0。
- 首次 Edge Function 部署复现 #70：旧 `./_shared` import 无法打包；修正并补 RED/GREEN 测试后部署成功。
- `generate-weekly-plan` 以 `--no-verify-jwt` 部署，由函数内部校验 generation secret 或用户 JWT，兼容现有 cron 请求。
- 无鉴权 POST 命中函数并返回 HTTP 401 `{"error":"unauthorized"}`；远端函数为 ACTIVE。
- 远端仅有 1 个真实账号，无法使用生产账号执行 A/B 双用户攻击请求；数据库约束、历史数据扫描及 service-role 查询测试共同覆盖该风险。
