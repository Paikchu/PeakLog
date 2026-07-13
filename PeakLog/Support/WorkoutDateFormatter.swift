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
/// `@unchecked Sendable`: the cached formatter is built once and never
/// mutated afterward, so it's safe under the existing usage pattern — every
/// call site constructs its own local instance (`WorkoutDateFormatter()` /
/// `WorkoutDateFormatter(timeZone:)`) rather than sharing one globally.
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
    nonisolated(unsafe) static var formatterConstructionCount = 0

    let calendar: Calendar

    private let timeZone: TimeZone
    // `nonisolated(unsafe)`: plain `nonisolated` (implicit or explicit) on a
    // mutable stored property is flagged as an error under the Swift 6
    // language mode; `nonisolated(unsafe)` is the supported way to opt a
    // specific mutable property out of isolation checking. Safe here for
    // the same reason the type is `@unchecked Sendable` overall — built
    // once, lazily, on first use, and never mutated afterward.
    nonisolated(unsafe) private lazy var formatter: DateFormatter = {
        Self.formatterConstructionCount += 1
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init(timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        self.timeZone = timeZone
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
