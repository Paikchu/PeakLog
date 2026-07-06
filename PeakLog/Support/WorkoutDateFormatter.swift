import Foundation

nonisolated struct WorkoutDateFormatter: Sendable {
    let calendar: Calendar

    private let timeZone: TimeZone

    init(timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        self.timeZone = timeZone
    }

    func string(from date: Date) -> String {
        makeFormatter().string(from: date)
    }

    func date(from string: String) -> Date? {
        makeFormatter().date(from: string)
    }

    func startOfDay(for date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    private func makeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
