import Foundation
import Combine

// Issue #134 回归测试：账号直接切换（`.signedIn(A) → .signedIn(B)`，中间没有
// `.signedOut`）时的会话代际边界。
//
// 这个测试驱动的是**真正的 `CloudSyncController`**，不是抄一份实现：编译时把
// `PeakLog/Services/Cloud/CloudSyncController.swift` 整份喂给 swiftc，只去掉
// `import Supabase` 那一行（SwiftPM 依赖，裸 swiftc 拿不到），它引用的那几个
// 类型由本文件用同名替身补齐。所以下面所有断言检验的都是生产源码里的生命周期
// 逻辑；把 controller 改回修复前的写法，1/2/3/5/6 会直接变红。
//
// 编译并运行（在仓库根目录）：
//
//   grep -v '^import Supabase$' PeakLog/Services/Cloud/CloudSyncController.swift \
//     > /tmp/peaklog_cloud_sync_controller.swift && \
//   swiftc -parse-as-library -default-isolation MainActor \
//     /tmp/peaklog_cloud_sync_controller.swift \
//     tests/cloud_session_handoff_test.swift -o /tmp/csh && /tmp/csh
//
// `-default-isolation MainActor` 对应工程里的 `SWIFT_DEFAULT_ACTOR_ISOLATION =
// MainActor`（见 PeakLog.xcodeproj）；不带这个标志编译出来的隔离语义和 App 里
// 跑的不是同一套，断言就失去意义。
//
// 替身的两点刻意偏差，都不影响被测逻辑：
//   * 真实的 `LocalAppDatabase` / `CloudSyncCoordinator` 是 `actor`，这里是
//     `@MainActor` 类 + `async` 方法。挂起点仍然真实存在（每个方法里都有显式
//     `Task.yield()`），但所有续体都排在 MainActor 队列上，测试因此可以靠
//     `Task.yield()` 把它们确定性地抽干；跨 actor 的话就只能靠 sleep 撞运气。
//     被测的串行/代际逻辑本身住在 `@MainActor` 的 controller 里，不受影响。
//   * `CloudSyncStatus` 没有用户字段，所以状态回调用 `.pendingRetry(String)`
//     的载荷把发出者的 user id 带出来，好断言「A 迟到的状态回调被丢弃」。
//
// 覆盖：
//   1. A→B 直切：B 的 prepare/arm 必须排在 A 的 stop/disarm 之后；A 迟到的
//      pull / 时区回填 / settle / 状态回调全部被丢弃；且 B 不必等 A 的在途
//      pull 自己超时（换代时的取消会把它放行）。
//   2. A→signedOut→B。
//   3. 快速 A→B→A：中间那代 B 一步都不落地。
//   4. start 失败时仍然放行登录 splash。
//   5. onForeground 的时区回填 / pull 不会落到新用户的会话上。
//   6. replan 往返期间换账号：结果丢弃，且不得用旧 coordinator 去 pull。
//   7. `bind(to:)` 的同步性：sink 返回时 `isPreparingSession` 已经翻转 ——
//      这是「登录后第一个 mutation 不会绕过尚未装好的 push hook」的前提。

// MARK: - 替身：Supabase / Auth 边界

/// 对应 `PeakLog/Services/SupabaseClientFactory.swift`。controller 只把它当句柄
/// 转手给 `SupabaseDataClient` / `PlanReplanService`，没有行为需要复刻。
nonisolated struct SupabaseAPIClient: Sendable {}

/// 对应 `PeakLog/Services/Auth/AuthProviding.swift`。
protocol TokenProviding: Sendable {
    func validToken() async throws -> String
}

nonisolated struct StubTokenProvider: TokenProviding {
    let userId: String
    func validToken() async throws -> String { "token-\(userId)" }
}

/// 对应 `PeakLog/Services/Cloud/SupabaseDataClient.swift`。
nonisolated struct SupabaseDataClient: Sendable {
    let tokenProvider: any TokenProviding
    init(client: SupabaseAPIClient, tokenProvider: any TokenProviding) {
        self.tokenProvider = tokenProvider
    }
}

/// 对应 `PeakLog/Services/Cloud/CloudSyncStatus.swift`（形状一致）。
nonisolated enum CloudSyncStatus: Equatable, Sendable {
    case idle
    case syncing
    case pendingRetry(String)
}

/// 对应 `PeakLog/Models/ReplanSignal.swift`。controller 只是原样透传。
nonisolated enum ReplanSignal: String, Sendable {
    case tooHard = "too_hard"
}

nonisolated struct AuthedUser: Equatable, Sendable {
    let id: String
}

/// 对应 `PeakLog/Services/Auth/AuthStateManager.swift` 的 `AuthGateState`。
enum AuthGateState: Equatable {
    case checking
    case signedOut
    case signedIn(AuthedUser)
    case localOnly
}

/// 只保留 controller 用到的两个面：`$state` 发布者（`bind(to:)` 订阅它）和
/// `makeTokenProvider()`。
final class AuthStateManager: ObservableObject {
    @Published private(set) var state: AuthGateState = .checking

    func makeTokenProvider() -> any TokenProviding {
        StubTokenProvider(userId: currentUserId ?? "none")
    }

    /// 模拟 Supabase SDK 推来的认证状态变化。
    func emit(_ next: AuthGateState) {
        state = next
    }

    private var currentUserId: String? {
        if case .signedIn(let user) = state { return user.id }
        return nil
    }
}

// MARK: - 替身：偏好设置

nonisolated struct UserPreferences: Sendable {
    var timezone: String
}

nonisolated struct UserProfile: Sendable {
    var preferences: UserPreferences
}

/// 对应 `UpdatePreferencesRequest` 的记忆化初始化器签名（controller 按位置传参）。
nonisolated struct UpdatePreferencesRequest: Sendable {
    let notificationsEnabled: Bool?
    let weightUnit: String?
    let timezone: String?
    let language: String?
}

// MARK: - 替身：本地缓存

/// 一次落到本地缓存的写入。`writer` 是这次写入归属的用户，`owner` 是写入落地时
/// 缓存本身归属的用户 —— 两者不一致就是 #134 描述的跨用户污染。
nonisolated struct CacheWrite: Equatable, Sendable {
    let kind: String
    let writer: String
    let owner: String?
}

/// 复刻 `LocalAppDatabase` 里与云同步生命周期相关的可观察行为，语义照抄
/// `PeakLog/Services/LocalAppDatabase.swift:192-222`。
final class LocalAppDatabase {
    // 真实实现是 actor，`static let shared` 天然 nonisolated；替身是 @MainActor
    // 类，得显式放行才能出现在 controller 初始化器的默认参数里。
    nonisolated static let shared = LocalAppDatabase()

    /// seed 状态里的时区占位符。真实实现在 `prepareForCloudUser` 里把缓存重置成
    /// `makeSeedState()`，时区回到「客户端从没设过」的状态；这里只要保证它永远
    /// 不等于 `TimeZone.current.identifier`，时区回填就会真的发生一次。
    static let seedTimezone = "__seed__"

    private(set) var log: [String] = []
    private(set) var writes: [CacheWrite] = []
    private(set) var ownerUserId: String?
    private(set) var armedUserId: String?
    private var profileTimezone = LocalAppDatabase.seedTimezone

    // MARK: 生命周期（controller 经 coordinator 间接驱动）

    /// 对应 `prepareForCloudUser`：换 owner 时丢掉旧缓存并摘掉 hook；owner 没变
    /// 就是空操作（真实实现里的 `guard state.ownerUserId != userId`）。
    func prepareForCloudUser(_ userId: String) {
        log.append("prepare(\(userId))")
        guard ownerUserId != userId else { return }
        ownerUserId = userId
        armedUserId = nil
        profileTimezone = Self.seedTimezone
        log.append("reset(\(userId))")
    }

    func armCloudSync(userId: String) {
        armedUserId = userId
        log.append("arm(\(userId))")
    }

    /// 对应 `disarmCloudSync`：只有当前挂着 hook 的那个用户能摘掉它
    /// （真实实现里的 `guard armedUserId == userId`）。
    func disarmCloudSync(userId: String) {
        guard armedUserId == userId else {
            log.append("disarm-noop(\(userId))")
            return
        }
        armedUserId = nil
        log.append("disarm(\(userId))")
    }

    func mergeFromCloud(writer: String) {
        writes.append(CacheWrite(kind: "merge", writer: writer, owner: ownerUserId))
        log.append("merge(\(writer)->\(ownerUserId ?? "nil"))")
    }

    /// 一次本地 mutation 触发 change hook：只有仍然挂着 hook 的用户会被推送。
    func fireChangeHook() {
        guard let armedUserId else {
            log.append("hook-dropped")
            return
        }
        writes.append(CacheWrite(kind: "push", writer: armedUserId, owner: ownerUserId))
        log.append("push(\(armedUserId)->\(ownerUserId ?? "nil"))")
    }

    // MARK: controller 直接调用的两个方法

    func fetchProfile() async -> UserProfile {
        // 真实实现是 actor 方法，调用点是一个真正的挂起点 —— 账号正是可能在这里
        // 换人的，`reconcileDeviceTimezone` 的代际校验就是为它准备的。
        await Task.yield()
        return UserProfile(preferences: UserPreferences(timezone: profileTimezone))
    }

    @discardableResult
    func updatePreferences(_ request: UpdatePreferencesRequest) async throws -> UserPreferences {
        await Task.yield()
        if let timezone = request.timezone {
            profileTimezone = timezone
            // 时区回填就是一次普通的本地 mutation，它的归属是此刻挂着 change hook
            // 的那个用户 —— 真实实现里正是这个 hook 把它推到云端。所以「A 的时区
            // 回填落到 B 的会话」在这里表现为一条 writer≠owner 的记录。
            writes.append(
                CacheWrite(kind: "timezone", writer: armedUserId ?? "unarmed", owner: ownerUserId)
            )
            log.append("timezone(\(armedUserId ?? "unarmed")->\(ownerUserId ?? "nil"))")
        }
        return UserPreferences(timezone: profileTimezone)
    }

    // MARK: 断言辅助

    /// 跨用户写入 —— 任何一条都是 #134 的复现。
    var crossUserWrites: [CacheWrite] {
        writes.filter { $0.writer != $0.owner }
    }

    var timezoneWriters: [String] {
        writes.filter { $0.kind == "timezone" }.map(\.writer)
    }

    /// 用于稳定性判定：日志不再增长就认为交接链已经跑完。
    var signature: String { log.joined(separator: "|") }
}

// MARK: - 替身：可控挂起点

/// 手动放行的挂起点，用来把「A 的 pull 还在途中」变成确定性时序。
///
/// 支持取消：任务被取消时立刻放行，模拟 URLSession 在 Task 取消时抛错返回 ——
/// 生产闸门在换代时取消旧链节，靠的就是这一点让新用户的登录 splash 不必干等
/// 旧用户一整个超时窗口。
final class Latch {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for continuation in pending {
            continuation.resume()
        }
    }

    func wait() async {
        if isOpen || Task.isCancelled { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if isOpen || Task.isCancelled {
                    continuation.resume()
                    return
                }
                waiters.append(continuation)
            }
        } onCancel: {
            Task { @MainActor in self.open() }
        }
    }
}

/// 测试对替身 coordinator / replan service 的遥控器。它们由 controller 内部
/// `new` 出来，没法从外面注入，所以配置走这个进程级单例。
final class SyncControl {
    static let shared = SyncControl()

    /// 让某个用户的初始 pull 停在半路。
    var pullLatches: [String: Latch] = [:]
    /// 让某个用户的 `start()` 返回 false（例如本地数据需要恢复）。
    var startFailures: Set<String> = []
    /// 让 Edge Function 往返停在半路。
    var replanLatch: Latch?

    func reset() {
        pullLatches = [:]
        startFailures = []
        replanLatch = nil
    }
}

// MARK: - 替身：coordinator

/// 复刻 `CloudSyncCoordinator` 的生命周期外形（`PeakLog/Services/Cloud/
/// CloudSyncCoordinator.swift:64-101`）：
/// `start()` = prepareForCloudUser → pull（可挂起）→ arm hook；`stop()` = disarm。
final class CloudSyncCoordinator {
    private let database: LocalAppDatabase
    private let userId: String
    private let onStatusChange: (@Sendable (CloudSyncStatus) -> Void)?

    init(
        client: SupabaseDataClient,
        database: LocalAppDatabase,
        userId: String,
        onStatusChange: (@Sendable (CloudSyncStatus) -> Void)? = nil
    ) {
        self.database = database
        self.userId = userId
        self.onStatusChange = onStatusChange
    }

    @discardableResult
    func start() async -> Bool {
        database.prepareForCloudUser(userId)
        if let latch = SyncControl.shared.pullLatches[userId] {
            await latch.wait()
        }
        guard !SyncControl.shared.startFailures.contains(userId) else {
            onStatusChange?(.pendingRetry("start-failed:\(userId)"))
            return false
        }
        database.mergeFromCloud(writer: userId)
        database.armCloudSync(userId: userId)
        onStatusChange?(.pendingRetry("started:\(userId)"))
        return true
    }

    func stop() async {
        await Task.yield()
        database.disarmCloudSync(userId: userId)
    }

    func onForeground() async {
        await Task.yield()
        database.mergeFromCloud(writer: userId)
    }

    @discardableResult
    func pull() async -> Bool {
        await Task.yield()
        database.mergeFromCloud(writer: userId)
        return true
    }
}

// MARK: - 替身：replan service

/// 对应 `PeakLog/Services/Cloud/PlanReplanService.swift`。
nonisolated struct PlanReplanService: Sendable {
    enum Outcome: Sendable, Equatable {
        case replanned([String])
        case noChange(reason: String)
        case failed(reason: String)
    }

    init(client: SupabaseAPIClient, tokenProvider: any TokenProviding) {}

    func requestReplan(userId: String, signal: ReplanSignal) async throws -> Outcome {
        let latch = await MainActor.run { SyncControl.shared.replanLatch }
        await latch?.wait()
        return .replanned(["\(userId)-day-1"])
    }
}

// MARK: - 测试脚手架

@MainActor
func pump(_ times: Int = 8) async {
    for _ in 0..<times {
        await Task.yield()
    }
}

/// 一直 yield 到本地缓存日志不再增长为止 —— 交接链、迟到回调都排在 MainActor
/// 队列上，所以「连续 N 轮没有新事件」等价于「已经尘埃落定」。挂在未放行 latch
/// 上的链节自然也会稳定下来，这正是测试要观察的中间态。
@MainActor
func quiesce(_ database: LocalAppDatabase, rounds: Int = 600, stableRounds: Int = 40) async {
    var lastSignature = database.signature
    var stable = 0
    for _ in 0..<rounds {
        await Task.yield()
        let signature = database.signature
        if signature == lastSignature {
            stable += 1
            if stable >= stableRounds { return }
        } else {
            lastSignature = signature
            stable = 0
        }
    }
}

@MainActor
func requireOrdered(_ log: [String], _ expected: [String], _ context: String) {
    var searchFrom = 0
    for entry in expected {
        guard let index = log[searchFrom...].firstIndex(of: entry) else {
            preconditionFailure("\(context): 期望日志里按序出现 \(expected)，实际是 \(log)")
        }
        searchFrom = index + 1
    }
}

/// 建一套全新的被测环境。
@MainActor
func makeSubject() -> (CloudSyncController, LocalAppDatabase, AuthStateManager) {
    SyncControl.shared.reset()
    let database = LocalAppDatabase()
    let controller = CloudSyncController(database: database, apiClient: SupabaseAPIClient())
    return (controller, database, AuthStateManager())
}

@MainActor
func signIn(_ controller: CloudSyncController, _ auth: AuthStateManager, _ userId: String) {
    auth.emit(.signedIn(AuthedUser(id: userId)))
    controller.handle(state: auth.state, auth: auth)
}

@MainActor
func signOut(_ controller: CloudSyncController, _ auth: AuthStateManager) {
    auth.emit(.signedOut)
    controller.handle(state: auth.state, auth: auth)
}

/// 状态回调里被接受的用户标签（替身把 user id 塞进了 `.pendingRetry` 的载荷）。
@MainActor
func acceptedStatusTag(_ controller: CloudSyncController) -> String? {
    if case .pendingRetry(let tag) = controller.syncStatus { return tag }
    return nil
}

// MARK: - 测试

@main
struct CloudSessionHandoffTest {
    static func main() async {
        await directSwitchAwaitsPreviousStop()
        await signOutBetweenAccountsStillSerializes()
        await rapidSwitchBackDiscardsMiddleGeneration()
        await failedStartStillSettlesPreparingFlag()
        await foregroundTickCannotLandOnNextUser()
        await replanOutcomeDiscardedAfterAccountSwitch()
        await bindDeliversSignInSynchronously()
        print("cloud_session_handoff_test passed")
    }

    // 1. `.signedIn(A) → .signedIn(B)`，中间没有 `.signedOut`。
    @MainActor
    static func directSwitchAwaitsPreviousStop() async {
        let (controller, database, auth) = makeSubject()
        let latchA = Latch()
        SyncControl.shared.pullLatches["A"] = latchA

        signIn(controller, auth, "A")
        await quiesce(database)
        precondition(
            database.log == ["prepare(A)", "reset(A)"],
            "期望 A 的 start 停在在途 pull 上，实际日志：\(database.log)"
        )

        signIn(controller, auth, "B")

        // 同步段必须已经生效：Combine sink 返回时 isPreparingSession 已经是 true，
        // 登录后的第一个 mutation 才会被 splash 挡住。
        precondition(controller.isPreparingSession, "切换那一刻 isPreparingSession 必须已经翻转")

        // 刻意不手动 open latchA：换代时对旧链节的取消必须把 A 的在途 pull 放行，
        // 否则 B 的登录要干等 A 一整个网络超时窗口。
        await quiesce(database)

        // 核心顺序：A 先跑完自己的 arm，再被 disarm，然后才轮到 B 去 prepare。
        // 修复前 B 的 prepare 和 A 的 arm 会交错，A 的 hook 就留在了 B 的缓存上。
        requireOrdered(database.log, ["arm(A)", "disarm(A)", "prepare(B)", "arm(B)"], "A→B 直切")
        precondition(
            database.crossUserWrites.isEmpty,
            "不允许跨用户写入，实际：\(database.crossUserWrites)，日志：\(database.log)"
        )
        precondition(database.armedUserId == "B", "最终只能是 B 挂着 change hook：\(database.log)")
        precondition(database.ownerUserId == "B", "最终缓存归属必须是 B")
        precondition(
            database.timezoneWriters == ["B"],
            "A 的时区回填必须被丢弃，实际：\(database.timezoneWriters)"
        )
        precondition(
            acceptedStatusTag(controller) == "started:B",
            "A 迟到的状态回调必须被丢弃，实际：\(String(describing: controller.syncStatus))"
        )
        precondition(
            controller.isPreparingSession == false,
            "B 准备完毕后应放行 splash（A 的旧 Task 也不得抢先放行）"
        )

        // 切换之后的本地 mutation 只能归属 B。
        database.fireChangeHook()
        precondition(database.log.last == "push(B->B)", "切换后的 push 必须归属 B：\(database.log)")
    }

    // 2. `.signedIn(A) → .signedOut → .signedIn(B)`：登出的 disarm 也在同一条链上，
    //    所以 B 依然排在它之后。
    @MainActor
    static func signOutBetweenAccountsStillSerializes() async {
        let (controller, database, auth) = makeSubject()
        SyncControl.shared.pullLatches["A"] = Latch()

        signIn(controller, auth, "A")
        await quiesce(database)

        signOut(controller, auth)
        precondition(controller.isPreparingSession == false, "登出后不应继续挂在 splash 上")
        precondition(controller.isReplanAvailable == false, "登出后不应还认为有云端会话")

        signIn(controller, auth, "B")
        await quiesce(database)

        requireOrdered(database.log, ["disarm(A)", "prepare(B)", "arm(B)"], "A→signedOut→B")
        precondition(database.crossUserWrites.isEmpty, "不允许跨用户写入：\(database.log)")
        precondition(database.armedUserId == "B", "最终只能是 B 挂着 change hook")
        precondition(
            database.timezoneWriters == ["B"],
            "A 的时区回填必须被丢弃，实际：\(database.timezoneWriters)"
        )
        precondition(controller.isPreparingSession == false, "B 准备完毕后应放行 splash")
    }

    // 3. 快速 A→B→A：中间那代 B 一步都不能落地。
    @MainActor
    static func rapidSwitchBackDiscardsMiddleGeneration() async {
        let (controller, database, auth) = makeSubject()
        SyncControl.shared.pullLatches["A"] = Latch()
        SyncControl.shared.pullLatches["B"] = Latch()

        signIn(controller, auth, "A")
        await quiesce(database)

        signIn(controller, auth, "B")
        signIn(controller, auth, "A")
        await quiesce(database)

        precondition(
            database.log == [
                "prepare(A)", "reset(A)", "merge(A->A)", "arm(A)",   // 第 1 代跑完，但结果被丢弃
                "disarm(A)",                                          // 第 2 代只做了 teardown
                "disarm-noop(B)",                                     // 第 3 代 teardown：B 从没 arm 过
                "prepare(A)", "merge(A->A)", "arm(A)", "timezone(A->A)"
            ],
            "A→B→A 的交接顺序不符合预期，实际：\(database.log)"
        )
        precondition(!database.log.contains("arm(B)"), "被跳过的一代 B 不允许 arm hook")
        precondition(!database.log.contains("reset(B)"), "被跳过的一代 B 不允许改写缓存归属")
        precondition(database.crossUserWrites.isEmpty, "不允许跨用户写入：\(database.log)")
        precondition(
            database.armedUserId == "A" && database.ownerUserId == "A",
            "最终会话必须是 A"
        )
        precondition(
            acceptedStatusTag(controller) == "started:A",
            "只有最后一代的状态回调能生效，实际：\(String(describing: controller.syncStatus))"
        )
        precondition(controller.isPreparingSession == false, "最后一代准备完毕后应放行 splash")
    }

    // 4. start 失败（例如本地数据需要恢复）时仍然要放行 splash，
    //    否则登录后会永远停在加载页。
    @MainActor
    static func failedStartStillSettlesPreparingFlag() async {
        let (controller, database, auth) = makeSubject()
        SyncControl.shared.startFailures = ["A"]

        signIn(controller, auth, "A")
        await quiesce(database)

        precondition(controller.isPreparingSession == false, "start 失败也必须放行 splash")
        precondition(
            acceptedStatusTag(controller) == "start-failed:A",
            "start 失败的状态应该到达 UI，实际：\(String(describing: controller.syncStatus))"
        )
        precondition(database.timezoneWriters.isEmpty, "start 失败时不应回填时区（hook 还没装）")
        precondition(database.armedUserId == nil, "start 失败时不应挂 hook")
    }

    // 5. 前台 tick 期间换账号：A 的时区回填和 pull 都不能落到 B 上。
    @MainActor
    static func foregroundTickCannotLandOnNextUser() async {
        let (controller, database, auth) = makeSubject()

        signIn(controller, auth, "A")
        await quiesce(database)
        precondition(database.timezoneWriters == ["A"], "A 自己的时区回填应该正常发生")

        controller.onForeground()
        signIn(controller, auth, "B")   // tick 还在途中就换了账号
        await quiesce(database)

        precondition(database.crossUserWrites.isEmpty, "不允许跨用户写入：\(database.log)")
        precondition(
            database.timezoneWriters == ["A", "B"],
            "A 的前台时区回填必须被丢弃，实际：\(database.timezoneWriters)"
        )
        let leakedAfterSwitch = database.log
            .drop { $0 != "prepare(B)" }
            .filter { $0.hasPrefix("merge(A") || $0.hasPrefix("timezone(A") || $0.hasPrefix("push(A") }
        precondition(
            leakedAfterSwitch.isEmpty,
            "切到 B 之后不允许出现 A 的写入，实际：\(leakedAfterSwitch)，日志：\(database.log)"
        )
    }

    // 6. replan 往返期间换账号：结果丢弃，且不得用旧 coordinator 去 pull。
    @MainActor
    static func replanOutcomeDiscardedAfterAccountSwitch() async {
        let (controller, database, auth) = makeSubject()
        let replanLatch = Latch()
        SyncControl.shared.replanLatch = replanLatch

        signIn(controller, auth, "A")
        await quiesce(database)
        let mergesByABefore = database.writes.filter { $0.kind == "merge" && $0.writer == "A" }.count

        async let outcome = controller.requestReplan(signal: .tooHard)
        await pump()
        precondition(controller.isRequestingReplan, "replan 应处于在途状态")

        signIn(controller, auth, "B")
        replanLatch.open()
        await quiesce(database)
        let result = await outcome

        precondition(
            result == nil,
            "换账号后旧会话的 replan 结果必须丢弃，实际：\(String(describing: result))"
        )
        precondition(database.crossUserWrites.isEmpty, "不允许跨用户写入：\(database.log)")
        let mergesByAAfter = database.writes.filter { $0.kind == "merge" && $0.writer == "A" }.count
        precondition(
            mergesByAAfter == mergesByABefore,
            "replan 的 pull 不得在换账号后再写一次 A 的数据："
                + "切换前 \(mergesByABefore) 次，切换后 \(mergesByAAfter) 次，日志：\(database.log)"
        )
    }

    // 7. `bind(to:)` 必须让 `isPreparingSession` 在 sink 返回前就翻转。
    //    这是 #134 修复的硬约束：交接的异步化不能把这个性质丢掉，否则登录后的
    //    第一个 mutation 会赶在 push hook 装好之前溜过去。
    @MainActor
    static func bindDeliversSignInSynchronously() async {
        let (controller, database, auth) = makeSubject()

        controller.bind(to: auth)
        precondition(controller.isPreparingSession == false, "绑定时还没有人登录")

        auth.emit(.signedIn(AuthedUser(id: "A")))
        // 没有任何 await：`@Published` 的 sink 是同步投递的，所以这一行执行时
        // 交接的同步段必须已经跑完。
        precondition(
            controller.isPreparingSession,
            "sink 返回时 isPreparingSession 必须已经是 true（handle 不能变成 async）"
        )

        await quiesce(database)
        precondition(database.armedUserId == "A", "A 的 hook 应该装好了：\(database.log)")
        precondition(controller.isPreparingSession == false, "A 准备完毕后应放行 splash")

        auth.emit(.signedOut)
        precondition(controller.isPreparingSession == false, "登出后不应挂在 splash 上")
        await quiesce(database)
        precondition(database.armedUserId == nil, "登出后 hook 必须摘掉：\(database.log)")
    }
}
