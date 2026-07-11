# Issue #59 账号数据隔离修复记录

- 修复范围：同设备 A → 退出 → B 的本地缓存与云端推送隔离。
- 根因：单一 `peaklog-local-state.json` 没有缓存所属账号；登录拉取会保留 UUID 本地记录；映射层再把记录 `userId` 覆盖成当前账号。
- 本地边界：状态新增持久化 `ownerUserId`；同步启动在拉取前调用 `prepareForCloudUser`。账号不一致或旧缓存没有 owner 时，先重置缓存和待上传事件。
- 合并边界：workout 与 running 只允许当前缓存 owner 的 domain 记录参与云合并。
- 推送边界：`CloudMapper.pushBundle` 改为 throwing API；profile、workout、running、plan edit event 任一归属不一致，整批推送失败，不再静默改写。
- 生命周期：旧账号的异步 stop 只能解除自己的同步 hook，避免账号快速切换时关闭新账号同步。
- RED：新增测试在实现前因缺少 `prepareForCloudUser` 失败；mapper 旧 API 也不能表达拒绝跨账号记录。
- GREEN：iOS 26.5 / iPhone 17 Pro Max 定向账号隔离测试通过；完整 `PeakLog` scheme 测试通过。
- 未覆盖：真实 Supabase RLS 伪造 UUID 验收需要测试账号与线上测试环境，本地单元测试只验证客户端在发出请求前拒绝污染数据。
