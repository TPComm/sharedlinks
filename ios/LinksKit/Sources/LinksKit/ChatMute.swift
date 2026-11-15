import Foundation

public enum ChatMuteDuration: CaseIterable, Sendable {
    case hour, tomorrow, indefinite

    public var title: String {
        switch self {
        case .hour: "For 1 Hour"
        case .tomorrow: "Until Tomorrow"
        case .indefinite: "Until I Turn It Back On"
        }
    }

    /// Tomorrow means 9 AM in the person's current calendar and time zone, including across DST.
    public func endDate(from now: Date = .now, calendar: Calendar = .current) -> Date? {
        switch self {
        case .hour: now.addingTimeInterval(3600)
        case .tomorrow:
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
                .flatMap { calendar.date(bySettingHour: 9, minute: 0, second: 0, of: $0) }
        case .indefinite: nil
        }
    }
}
