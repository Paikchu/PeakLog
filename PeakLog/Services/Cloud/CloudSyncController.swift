import Foundation
import Combine
import Supabase

// 闸门被提到独立类型（而不是散落在 controller 里的几个 `guard`），是为了把
// 「代际校验」收敛成一处原语：调用方不容易在某个 await 之后漏写 guard，而且
// 「串行交接」这条不变量有一个可以单独讲清楚的归属地。
/// 会话代际闸门：把「账号身份变化」变成一条严格串行、带代际标记的交接链。
///
/// 为什么需要它（Issue #134）：从 `.signedIn(A)` 直接变成 `.signedIn(B)` 时，
/// 唯一安全的顺序是「先停掉 A 的 coordinator、等 `disarmCloudSync` 落地，再准备
/// B」，而「等」是异步的；但 `CloudSyncController.handle` 是 `@MainActor` 上的
/// 同步方法（Combine sink 直接调用），不能简单改成 `async` —— 一旦改成 async，
/// `isPreparingSession` 就不再是在 sink 返回前翻转的，登录后的第一个 mutation
/// 可能赶在 push hook 装好之前溜过去（见 `bind(to:)` 的注释）。
///
/// 于是把一次切换拆成两半：同步的一半（翻 `isPreparingSession`、换 coordinator
/// 引用、代际 +1）留在 `handle` 的调用栈里，异步的一半排进这条链。
///
/// 两条不变量：
/// 1. **串行**：后一次交接的 teardown 一定排在前一次交接整体跑完之后。反过来
///    （并行）会出现 B 先 disarm、A 后 arm 的顺序反转，把 A 的 change hook 永久
///    留在 B 的会话上，比「不 stop」更糟。
/// 2. **代际**：任何 `await` 之后再写共享状态之前，都要确认代际没变。旧代际的
///    迟到结果一律丢弃，不得覆盖新会话的 `coordinator` / `activeUserId` /
///    `isPreparingSession` / `syncStatus`，也不得触发时区回填。
@MainActor
final class CloudSyncSessionGate {
    /// 当前会话代际。每次身份变化（登入、登出、直接换账号）都 +1。
    private(set) var generation = 0

    /// 交接链的尾节点。新排入的节点先 `await` 它，从而形成严格串行。
    /// `tailId` 只用来判断「跑完的这一节是不是仍然是链尾」，好在链排空时把尾指针
    /// 放掉，而不是让最后一个已完成的 Task 一直挂在 controller 的生命周期上。
    private var tail: Task<Void, Never>?
    private var tailId: Int?

    /// 尚未跑完的交接节点。换代时逐个取消：取消**不会**跳过 teardown（actor
    /// 方法调用不因取消而中断，`disarm` 一定会发生），但会让旧用户在途的网络
    /// 等待立刻抛错返回，避免新用户的登录 splash 被旧用户一次超时的 pull 拖住
    /// 整个 URLSession 超时窗口。
    private var pendingLinks: [Int: Task<Void, Never>] = [:]
    private var nextLinkId = 0

    /// 开启新一代会话，返回新代际号。必须在 `handle` 的同步段里调用，这样
    /// 「旧代际已失效」这件事在 Combine sink 返回前就已经成立。
    @discardableResult
    func beginTransition() -> Int {
        generation += 1
        for link in pendingLinks.values {
            link.cancel()
        }
        return generation
    }

    /// `generation` 是否仍是当前代际。
    func isCurrent(_ generation: Int) -> Bool {
        self.generation == generation
    }

    /// 仅当代际未变时执行 `body`。把「await 之后再写共享状态」这一步的代际校验
    /// 收敛成一个原语，调用方（例如 coordinator 的状态回调）不容易漏写。
    func runIfCurrent(_ generation: Int, _ body: @MainActor () -> Void) {
        guard isCurrent(generation) else { return }
        body()
    }

    /// 排入一次完整的会话交接。
    ///
    /// - Parameters:
    ///   - generation: `beginTransition()` 返回的代际号。
    ///   - teardown: 拆卸上一代会话（`coordinator.stop()` → `disarmCloudSync`）。
    ///     **无条件执行**，即使这次交接已被更新的代际取代 —— 旧 coordinator 必须
    ///     被摘掉，这正是 #134 的核心；跳过它等于回到「A 的 change hook 挂在 B 的
    ///     会话上」。
    ///   - prepare: 装配新会话（`coordinator.start()`），返回是否成功。只有代际
    ///     仍然是自己时才执行 —— 否则就会出现「已经切到 C 了还去 arm B」。
    ///   - reconcile: `prepare` 成功后的异步收尾（时区回填），此时 push hook 已
    ///     装好，这次写入才会被推送出去。
    ///   - settle: 最后一次写共享状态（`isPreparingSession = false`），参数是
    ///     `prepare` 的结果。
    func enqueueHandoff(
        generation: Int,
        teardown: @escaping @MainActor () async -> Void,
        prepare: @escaping @MainActor () async -> Bool,
        reconcile: @escaping @MainActor () async -> Void,
        settle: @escaping @MainActor (Bool) -> Void
    ) {
        enqueue { [weak self] in
            await teardown()
            guard let self, self.isCurrent(generation) else { return }
            let prepared = await prepare()
            guard self.isCurrent(generation) else { return }
            guard prepared else {
                settle(false)
                return
            }
            await reconcile()
            guard self.isCurrent(generation) else { return }
            settle(true)
        }
    }

    /// 排入一段必须串行、且必须跑完的交接工作（登出只有 teardown 一段）。
    func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = tail
        nextLinkId += 1
        let id = nextLinkId
        let link = Task { [weak self] in
            // 串行的落点：等上一节点整体结束，绝不能并行 —— 见不变量 1。
            // `Task<Void, Never>.value` 不会因为本节点被取消而提前返回，
            // 所以取消也不会破坏顺序。
            await previous?.value
            await work()
            guard let self else { return }
            self.pendingLinks[id] = nil
            if self.tailId == id {
                self.tail = nil
                self.tailId = nil
            }
        }
        pendingLinks[id] = link
        tail = link
        tailId = id
    }
}

/// Bridges the `@MainActor` app/auth world to the background `CloudSyncCoordinator`.
/// Starts a coordinator when a user signs in, tears it down on sign-out or
/// DEBUG local mode, and forwards foreground ticks. Idempotent per user id so
/// repeated auth-state emissions don't restart an active sync.
@MainActor
final class CloudSyncController: ObservableObject {
    /// True from sign-in until the first pull finishes. The gate holds on a
    /// splash while this is set, so the main UI's first read sees cloud truth
    /// rather than the stale seed/local cache it would otherwise render.
    @Published private(set) var isPreparingSession = false

    /// User-visible sync state (see `CloudSyncStatus`). `.idle` while signed out
    /// or in DEBUG local mode — there is nothing to report.
    @Published private(set) var syncStatus: CloudSyncStatus = .idle

    private let database: LocalAppDatabase
    private let apiClient: SupabaseAPIClient?
    private var coordinator: CloudSyncCoordinator?
    private var activeUserId: String?
    private var activeTokenProvider: TokenProviding?
    private var stateSubscription: AnyCancellable?

    /// 身份代际闸门。所有跨 `await` 的会话状态写入都要过它 —— 见类型注释。
    private let sessionGate = CloudSyncSessionGate()

    /// True while a one-tap replan request is in flight — the Today UI disables
    /// the adjust menu so a double-tap can't fire two requests.
    @Published private(set) var isRequestingReplan = false

    init(
        database: LocalAppDatabase = .shared,
        apiClient: SupabaseAPIClient? = nil
    ) {
        self.database = database
        self.apiClient = apiClient
    }

    /// Subscribe to auth-state changes. Combine delivers synchronously with the
    /// `@Published` mutation (unlike SwiftUI `.onChange`, which is deferred to
    /// the next view update) — so `isPreparingSession` flips and the coordinator
    /// starts *before* any post-sign-in mutation can slip past an uninstalled
    /// push hook. Call once at app launch.
    func bind(to auth: AuthStateManager) {
        guard stateSubscription == nil else { return }
        stateSubscription = auth.$state.sink { [weak self, weak auth] state in
            guard let self, let auth else { return }
            self.handle(state: state, auth: auth)
        }
    }

    /// React to an auth-gate transition. Only `.signedIn` runs the cloud sync;
    /// `.localOnly` (DEBUG) and `.signedOut` keep the app fully offline.
    ///
    /// 保持同步方法：`bind(to:)` 靠 sink 的同步投递让 `isPreparingSession` 在任何
    /// post-sign-in mutation 之前翻转，改成 `async` 会把这个性质丢掉。真正需要
    /// `await` 的「停旧 → 再起新」被拆进 `sessionGate` 的串行交接链（#134）。
    func handle(state: AuthGateState, auth: AuthStateManager) {
        switch state {
        case .signedIn(let user):
            guard activeUserId != user.id else { return }
            start(userId: user.id, tokenProvider: auth.makeTokenProvider())
        case .signedOut, .localOnly, .checking:
            stop()
        }
    }

    func onForeground() {
        guard let coordinator else { return }
        let generation = sessionGate.generation
        Task { [weak self] in
            guard let self else { return }
            // Reconcile first: if the device's timezone changed (e.g. travel),
            // this mutation must land before onForeground() decides whether
            // there's anything pending to push, or it waits for next time.
            await self.reconcileDeviceTimezone(generation: generation)
            // 前台 tick 期间可能已经换了账号；旧会话的 pull/push 不能再跑，
            // 否则 A 的同步结果会落进 B 已经准备好的本地缓存。
            guard self.sessionGate.isCurrent(generation) else { return }
            await coordinator.onForeground()
        }
    }

    /// Writes the device's real IANA timezone to preferences if it differs
    /// from what's on record. `profiles.timezone` defaults to `'UTC'`
    /// server-side and the client has otherwise never set it — left alone,
    /// server-side timezone-sensitive logic (e.g. Phase 2's Sunday-evening
    /// weekly plan generation) would silently run against the wrong clock
    /// for every user. No UI: this is a background reconciliation, same as
    /// the sync itself.
    ///
    /// `generation` 是发起这次回填时的会话代际：`fetchProfile()` 是一个挂起点，
    /// 期间账号可能已经换人，此时这次写入属于旧代际，必须丢弃而不是写进新用户
    /// 的偏好设置里。
    private func reconcileDeviceTimezone(generation: Int) async {
        let deviceTimezone = TimeZone.current.identifier
        let profile = await database.fetchProfile()
        guard sessionGate.isCurrent(generation) else { return }
        guard profile.preferences.timezone != deviceTimezone else { return }
        _ = try? await database.updatePreferences(UpdatePreferencesRequest(
            notificationsEnabled: nil,
            weightUnit: nil,
            timezone: deviceTimezone,
            language: nil
        ))
    }

    #if DEBUG
    /// Latest sync error / pending flag, for the in-process E2E check.
    func diagnostics() async -> (error: String?, pending: Bool)? {
        await coordinator?.diagnostics()
    }

    func makeE2EDataClient(tokenProvider: TokenProviding) -> SupabaseDataClient? {
        guard let apiClient else { return nil }
        return SupabaseDataClient(client: apiClient, tokenProvider: tokenProvider)
    }
    #endif

    private func start(userId: String, tokenProvider: TokenProviding) {
        guard let apiClient else { return }

        // 同步段：先让新代际生效（旧代际的在途任务就此失效），再把旧 coordinator
        // 摘下来交给交接链。这一段不能有 await —— `isPreparingSession` 必须在
        // Combine sink 返回前就是 true。
        let generation = sessionGate.beginTransition()
        let previousCoordinator = self.coordinator

        let client = SupabaseDataClient(client: apiClient, tokenProvider: tokenProvider)
        let newCoordinator = CloudSyncCoordinator(
            client: client,
            database: database,
            userId: userId,
            onStatusChange: { [weak self] status in
                // Hop back to the main actor; the coordinator itself is background.
                // 旧用户 coordinator 的迟到状态回调不得覆盖新会话的 syncStatus。
                Task { @MainActor in
                    guard let self else { return }
                    self.sessionGate.runIfCurrent(generation) { self.syncStatus = status }
                }
            }
        )
        self.coordinator = newCoordinator
        self.activeUserId = userId
        self.activeTokenProvider = tokenProvider
        isPreparingSession = true
        syncStatus = .idle

        // 异步段：先 await 旧 coordinator 的 stop/disarm 真正落地，再准备新用户。
        // 不能 fire-and-forget —— 否则 A 的 change hook 可能在 B 已经
        // `prepareForCloudUser(B)` 之后才被摘掉，A 的在途 push 会写进 B 的缓存。
        sessionGate.enqueueHandoff(
            generation: generation,
            teardown: { await previousCoordinator?.stop() },
            prepare: { await newCoordinator.start() },
            reconcile: { [weak self] in
                // hook is armed by now, so this pushes
                await self?.reconcileDeviceTimezone(generation: generation)
            },
            settle: { [weak self] _ in self?.isPreparingSession = false }
        )
    }

    private func stop() {
        // 与 start 同构：代际先失效，引用同步清空，真正的 stop/disarm 排进同一
        // 条链 —— 这样紧随其后的 `.signedIn(B)` 一定排在这次 disarm 之后。
        sessionGate.beginTransition()
        let previousCoordinator = self.coordinator
        self.coordinator = nil
        self.activeUserId = nil
        self.activeTokenProvider = nil
        isPreparingSession = false
        syncStatus = .idle
        guard let previousCoordinator else { return }
        sessionGate.enqueue { await previousCoordinator.stop() }
    }

    /// Whether one-tap replan is available at all — false in DEBUG local mode
    /// and while signed out (no cloud session), so the UI can hide the control.
    var isReplanAvailable: Bool {
        coordinator != nil && activeUserId != nil && activeTokenProvider != nil
    }

    /// Fires a one-tap replan (Phase 3). Records nothing itself — the caller has
    /// already recorded the local signal event — then calls the Edge Function
    /// and, on a real replan, pulls so the new plan lands in the local cache and
    /// the UI refreshes. Returns nil when there's no active cloud session.
    func requestReplan(signal: ReplanSignal) async -> PlanReplanService.Outcome? {
        guard let coordinator,
              let userId = activeUserId,
              let tokenProvider = activeTokenProvider,
              let apiClient
        else {
            return nil
        }
        guard !isRequestingReplan else { return nil }
        isRequestingReplan = true
        defer { isRequestingReplan = false }

        let generation = sessionGate.generation
        let service = PlanReplanService(client: apiClient, tokenProvider: tokenProvider)
        do {
            let outcome = try await service.requestReplan(userId: userId, signal: signal)
            // Edge Function 往返期间账号可能已经换人：这个结果属于旧会话，既不能
            // 用旧 coordinator 去 pull（会把 A 的云端数据合进 B 的本地缓存），也
            // 不该把 outcome 交给已经属于 B 的 UI。
            guard sessionGate.isCurrent(generation) else { return nil }
            if case .replanned = outcome {
                // Pull the server-applied replan into the local cache. Because
                // this immediately follows a successful call, the revision guard
                // on the next push is naturally satisfied.
                await coordinator.pull()
            }
            return outcome
        } catch {
            guard sessionGate.isCurrent(generation) else { return nil }
            return .failed(reason: "\(error)")
        }
    }
}
