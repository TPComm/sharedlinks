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

/// Shared by every mute entry point: a later choice must reach the server after the earlier one.
@MainActor
public final class ChatMuteSaveQueue {
    private var pending: [Int: (id: UUID, task: Task<LinkGroup, Error>)] = [:]

    public init() {}

    /// Enqueue synchronously so tap order is established before either caller suspends.
    public func enqueue(_ groupID: Int, save: @escaping @MainActor () async throws -> LinkGroup) -> Task<LinkGroup, Error> {
        let previous = pending[groupID]?.task
        let id = UUID()
        let task = Task { @MainActor in
            defer { if pending[groupID]?.id == id { pending[groupID] = nil } }
            // A failed choice must not prevent the next one from being saved.
            _ = try? await previous?.value
            return try await save()
        }
        pending[groupID] = (id, task)
        return task
    }
}
