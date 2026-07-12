# Issue #62 修复记录

- 根因：`LocalAppDatabase` 在所有 mutation 中先修改 actor 内 `state`，再调用 `persist()`；`writeStateToDisk()` 抛错时没有恢复内存状态，导致失败写入仍污染 snapshot，且后续操作可能继续使用脏状态。
- 修复：增加 `lastPersistedState` 事务基线。`persist()` 写盘失败恢复基线并重新抛错，成功写盘后更新基线，再触发 `onChange`；`replaceAll`、`mergeFromCloud` 和账号切换路径同步维护基线。
- 回归测试：新增 update、delete、batch mutation 的写盘失败场景；将 state 文件替换为目录模拟原子写入失败，断言 snapshot 字节级一致，失败路径不触发 change hook。
- RED：原始实现下 update 测试稳定失败，证实写盘失败后内存状态未回滚。
- GREEN：修复后测试源已编译；完整 XCTest 运行受并行 worktree 占用导致 iPhone 17 Pro Max Simulator 进入 Invalid device state，需在其他测试进程退出后重跑。
- 未涉及：#63 UI 保存流、Supabase schema/RLS、Edge Function、线上数据。
