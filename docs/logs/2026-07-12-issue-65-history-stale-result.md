# Issue #65 验证记录

- RED：未加 generation 防护时，`HistoryStaleResultTests.testStaleDateResultCannotOverwriteNewerSelection` 失败，旧日期结果覆盖新日期。
- GREEN：加入 generation 与日期校验后，定向 XCTest 通过。
- 覆盖：旧请求延迟、新日期请求先完成；断言 selected date 与 sessions 均来自新日期。
- 未覆盖：完整 XCTest 套件与真实网络延迟环境。
