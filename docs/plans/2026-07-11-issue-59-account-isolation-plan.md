# Issue #59 账号数据隔离修复方案

- 根因：`LocalAppDatabase` 复用单一持久化状态，登录新账号前没有切换或清空账号上下文。
- 放大器：`mergeFromCloud` 保留所有 UUID 本地记录；`CloudMapper` 再用当前登录账号覆盖记录原有 `userId`。
- 登录边界：同步启动时先让数据库进入目标账号上下文，再执行拉取；账号变化时清除前一账号的训练、跑步、自定义动作及待上传事件。
- 同账号恢复：持久化当前缓存所属账号；同账号重启保留离线数据，不重复清空。
- 推送边界：`CloudMapper` 在生成任何行前验证 profile、训练、跑步、编辑事件归属；不一致直接抛错，中止整批推送。
- 回归覆盖：A → 退出 → B 后 workout、running、custom exercise 不可见；B → A 可由 A 云端快照恢复；mapper 不允许将 A 的 domain 数据映射成 B。
- 验收：先运行新增测试得到预期 RED，再做最小实现并得到 GREEN；最后在 iOS 26.5 / iPhone 17 Pro Max 执行完整测试。
