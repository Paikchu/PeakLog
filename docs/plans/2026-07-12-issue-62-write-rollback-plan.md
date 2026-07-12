# Issue #62：本地写盘失败回滚计划

- 根因假设：`LocalAppDatabase` 的 mutation 先直接修改 actor 内存中的 `state`，`persist()` 才写 JSON；写盘失败时只抛错，已修改的内存状态和派生字段仍然可见，且失败路径可能触发后续同步。
- 范围：覆盖所有通过 `persist()` 完成的 update、delete、create、batch 和计划编辑；不修改 #63 的 UI 保存流、不引入数据迁移或 Supabase 变更。
- 修复：为数据库保留最近一次成功持久化的值状态；`persist()` 写盘失败时恢复该状态并重新抛出错误，成功后更新事务基线；`onChange` 仅在写盘成功后触发。
- 验收：模拟有效 state 文件在 mutation 前被替换为目录，验证 update、delete、batch 失败后 snapshot 深度相等、文件内容未被伪造更新、change hook 次数保持不变；成功路径仍持久化并触发一次 hook。
- 验证：新增 XCTest RED/GREEN；运行相关 XCTest、独立 Swift 回归测试和 iOS 26.5 iPhone 17 Pro Max Simulator 全量测试。
- 风险：进程在写盘过程中崩溃仍依赖 `.atomic` 的文件系统语义；本修复只覆盖 actor 内 mutation 的内存一致性，不承诺跨进程锁。
