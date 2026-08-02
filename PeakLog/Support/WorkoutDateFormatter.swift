import Foundation

/// Formats/parses the app's "yyyy-MM-dd" day-key strings.
///
/// A `final class`, not a `struct`: `DateFormatter` construction is the
/// expensive part (locale/timezone/calendar setup), and it needs to be
/// built once per instance and reused across `string(from:)`/`date(from:)`
/// calls. A struct wrapper around a "build a fresh DateFormatter every
/// call" method doesn't help — callers that cache the *wrapper* still pay
/// for a new `DateFormatter` on every single formatting call, which is what
/// made caching a `WorkoutDateFormatter` instance not actually fix the
/// perf issue in `HistoryViewModel.calendarDays()` (issue #55). Here the
/// `DateFormatter` itself is what's cached, lazily, on first use.
///
/// `@unchecked Sendable`: the only mutable state is the lazily built
/// `DateFormatter` cache, and it is guarded by `formatterLock` (see below), so
/// the claim is backed by a lock rather than by an assumption about how call
/// sites happen to use the type today.
/// Deliberately not a `static`/global singleton: issue #29 (open) means
/// this will need to start honoring the user's timezone preference instead
/// of always `TimeZone.current`; a per-instance cache stays trivial to
/// invalidate (just create a new instance) when that lands, whereas a
/// shared singleton would need its own invalidation mechanism bolted on.
nonisolated final class WorkoutDateFormatter: @unchecked Sendable {
    /// Counts how many times the underlying `DateFormatter` is actually
    /// constructed (across all instances), so tests can assert the lazy
    /// cache is doing its job instead of just checking output correctness
    /// (issue #55). `WorkoutDateFormatter.swift` lives in the app target,
    /// which never gets the `TESTING` compilation flag PeakLogTests uses
    /// (that flag is only set for the test target's own compilation), so
    /// this can't be gated behind `#if TESTING` — it's always compiled in.
    /// The increment is a single `Int` add on a cache-miss path that fires
    /// once per instance, so the always-on cost is negligible.
    ///
    /// Held in a lock-owning box rather than a `nonisolated(unsafe) static var`:
    /// a shared mutable static reachable from any thread is exactly the case
    /// `nonisolated(unsafe)` would only be silencing (issue #137). The box is a
    /// `let` of a genuinely `Sendable` type, so nothing here needs an isolation
    /// exemption at all — the mutable state lives behind the box's lock.
    private static let constructionCounter = ConstructionCounter()

    static var formatterConstructionCount: Int { constructionCounter.value }

    /// Lock-guarded `Int`. `@unchecked Sendable` is confined to this box, whose
    /// entire surface is the two synchronized accessors below.
    private final class ConstructionCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int { lock.withLock { count } }

        func increment() { lock.withLock { count += 1 } }
    }

    let calendar: Calendar

    private let timeZone: TimeZone

    // The cache the whole type exists for. `lazy var` would be the obvious
    // spelling, but it is unsynchronized: two threads formatting through the
    // same instance would race on the initialization. `@unchecked Sendable`
    // silences the compiler about that, it does not make it true — so the
    // cache is an explicit lock-guarded optional instead. The lock is only
    // held while reading/publishing the reference; `DateFormatter` itself is
    // documented as safe to use concurrently once fully configured, so the
    // actual formatting happens outside the critical section.
    private let formatterLock = NSLock()
    private var cachedFormatter: DateFormatter?

    init(timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        self.timeZone = timeZone
    }

    private var formatter: DateFormatter {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        if let cachedFormatter { return cachedFormatter }

        Self.constructionCounter.increment()
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        cachedFormatter = formatter
        return formatter
    }

    func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    func date(from string: String) -> Date? {
        formatter.date(from: string)
    }

    func startOfDay(for date: Date) -> Date {
        calendar.startOfDay(for: date)
    }
}
