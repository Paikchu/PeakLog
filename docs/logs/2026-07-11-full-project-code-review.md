# PeakLog 全项目代码审查记录

## 基线与范围

- 审查日期：2026-07-11。
- Git 基线：`main` / `eece9ed163ab9428902b37233984a49914b2b94d`，与 `origin/main` 一致。
- 范围：iOS 架构、Swift Concurrency、类型与数据安全、本地持久化、Cloud Sync、Auth、UX、Live Activity、Supabase migrations/RLS/RPC/Edge Function、测试与可重放性。
- 本地未提交改动未作为远端 Issue 证据，也未被修改、暂存或还原。
- 先对 GitHub 58 个开放 Issue 去重；2026-07-08 历史报告中的问题未重复创建。

## 验证结果

- Xcode 26.6，iOS 26.5 SDK，iPhone 17 Pro Max Simulator。
- `xcodebuild test -project PeakLog.xcodeproj -scheme PeakLog -destination 'platform=iOS Simulator,id=BF450796-F6EF-49BB-906E-0532203E4CEB'`：`TEST SUCCEEDED`。
- `node --test backend/tests/*.test.mjs`：65 passed，0 failed。
- Hosted Supabase `fqyurmsuvtdafbnynurg` 仅做只读检查；未执行 DDL/DML、迁移或部署。
- `information_schema.routine_privileges` 确认两个高风险 RPC 向 `PUBLIC`、`anon`、`authenticated` 授予 `EXECUTE`。
- Supabase Security Advisor 确认公开 `SECURITY DEFINER` 告警；Performance Advisor 另报告未索引外键与 RLS init-plan 优化项。
- 官方依据：[Supabase Database Functions](https://supabase.com/docs/guides/database/functions)、[Supabase Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security)。

## 新建 Issues

### P0

- [#59 切换账号会将前一账号的训练数据上传到新账号](https://github.com/Paikchu/PeakLog/issues/59)
- [#67 计划组可跨用户关联训练组，Edge Function 会泄露受害者训练数据](https://github.com/Paikchu/PeakLog/issues/67)

### P1

- [#60 首次云拉取失败后仍启用全量推送，可能删除云端新数据](https://github.com/Paikchu/PeakLog/issues/60)
- [#61 本地状态解码失败会覆盖原文件并丢失全部训练数据](https://github.com/Paikchu/PeakLog/issues/61)
- [#68 公开 SECURITY DEFINER RPC 可匿名重建任意用户 PR 与统计](https://github.com/Paikchu/PeakLog/issues/68)
- [#69 Replan revision 冲突后复用旧结果重试，乐观锁仍会丢失更新](https://github.com/Paikchu/PeakLog/issues/69)
- [#70 generate-weekly-plan 使用错误共享模块路径，干净 checkout 无法打包部署](https://github.com/Paikchu/PeakLog/issues/70)

### P2

- [#62 本地写盘失败不回滚内存 mutation，状态会在重启后反转](https://github.com/Paikchu/PeakLog/issues/62)
- [#63 编辑保存失败后 Sheet 仍关闭并丢失用户输入](https://github.com/Paikchu/PeakLog/issues/63)
- [#64 删除已完成计划动作会级联删除训练记录，但没有确认或撤销](https://github.com/Paikchu/PeakLog/issues/64)
- [#65 History 快速切换日期时旧请求会覆盖当前日期内容](https://github.com/Paikchu/PeakLog/issues/65)
- [#71 Replan 每日配额按伪 UTC 午夜计算，非 UTC 用户会误限流或重复执行](https://github.com/Paikchu/PeakLog/issues/71)
- [#72 Supabase 配置启用不存在的 seed.sql，干净环境无法可靠重放数据库](https://github.com/Paikchu/PeakLog/issues/72)

### P3

- [#66 Profile 的 Help 与 Privacy 按钮点击后无任何行为](https://github.com/Paikchu/PeakLog/issues/66)

## 修复顺序

1. 立即处理 #59、#67、#68：账号隔离、租户关系完整性、公开 SECURITY DEFINER 权限。
2. 阻断数据删除与覆盖：#60、#61、#69。
3. 恢复 Edge Function 可部署性：#70，并补 clean-checkout bundle CI。
4. 修复事务/UX 并发路径：#62、#63、#64、#65、#71。
5. 恢复数据库重放与无效入口：#72、#66。

## 排除与未升级项

- `audit_logs_insert_service WITH CHECK (true)` 不属于当前基线问题；后续 migration 已删除 `audit_logs` 整表。
- trigger-only 的无参数 trigger functions 仍被 Advisor 标记为可公开执行；直接 RPC 通常因 trigger return type 无法作为普通函数运行。应在 #68 的权限收敛迁移中一并 revoke，而不拆重复 Issue。
- public avatars bucket listing、RLS init-plan 与未索引外键保留为后端 hardening 清单；当前证据不足以证明产品预期被破坏，未作为 Bug 发布。
- `tests/*.swift` 是源码拼接式轻量脚本，不能逐文件直接执行；正式 Xcode test target 和后端 Node tests 已作为有效验证入口。

## 结论

- 当前版本不适合按生产安全标准发布。
- 两条 P0 均涉及跨账号/跨租户隐私边界；#68 已在 hosted 数据库验证为真实在线权限暴露。
- 测试通过不覆盖账号切换、首次 pull 失败、RLS 关系完整性、Edge bundle、异步乱序与写盘失败路径。
