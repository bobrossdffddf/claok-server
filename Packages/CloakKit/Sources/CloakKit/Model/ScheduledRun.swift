import Foundation
import SwiftData

/// Something Cloak should start on its own at a given time.
///
/// A schedule is deliberately not a promise. iOS will not wake a sideloaded
/// app out of nowhere, so a schedule fires reliably while Cloak is running —
/// which, with background location on, is most of the time — and otherwise
/// sends a notification so the run is one tap away.
@Model
public final class ScheduledRun {
    public var id: UUID
    public var name: String

    /// What to run: a fixed point, a saved route, or a recorded trip.
    public var kindRaw: String
    /// The saved route or recorded trip this points at.
    public var targetID: UUID?
    public var latitude: Double
    public var longitude: Double

    public var hour: Int
    public var minute: Int

    /// Bit per weekday, Sunday is bit 0. Zero means it runs once, on `onceOn`.
    public var weekdays: Int
    public var onceOn: Date?

    /// Minutes to run for. Zero means until it is stopped by hand.
    public var durationMinutes: Int

    public var isEnabled: Bool
    public var lastFiredAt: Date?
    public var createdAt: Date

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case place
        case route
        case trip

        public var title: String {
            switch self {
            case .place: "Place"
            case .route: "Route"
            case .trip: "Recording"
            }
        }

        public var symbol: String {
            switch self {
            case .place: "mappin"
            case .route: "arrow.triangle.turn.up.right.diamond"
            case .trip: "clock.arrow.circlepath"
            }
        }
    }

    public init(
        id: UUID = UUID(),
        name: String,
        kind: Kind,
        targetID: UUID? = nil,
        coordinate: Coordinate = Coordinate(latitude: 0, longitude: 0),
        hour: Int,
        minute: Int,
        weekdays: Int = 0,
        onceOn: Date? = nil,
        durationMinutes: Int = 0
    ) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.targetID = targetID
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
        self.onceOn = onceOn
        self.durationMinutes = durationMinutes
        self.isEnabled = true
        self.lastFiredAt = nil
        self.createdAt = .now
    }

    public var kind: Kind { Kind(rawValue: kindRaw) ?? .place }

    public var coordinate: Coordinate {
        Coordinate(latitude: latitude, longitude: longitude)
    }

    public var repeats: Bool { weekdays != 0 }

    /// The next moment this should start, or nil if it never will again.
    public func nextFire(after now: Date = .now, calendar: Calendar = .current) -> Date? {
        guard isEnabled else { return nil }

        if !repeats {
            guard let day = onceOn else { return nil }
            var parts = calendar.dateComponents([.year, .month, .day], from: day)
            parts.hour = hour
            parts.minute = minute
            guard let moment = calendar.date(from: parts) else { return nil }
            return moment > now ? moment : nil
        }

        // Walk forward a week; the first matching day that has not already
        // passed today is the answer.
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let weekday = calendar.component(.weekday, from: day) - 1
            guard weekdays & (1 << weekday) != 0 else { continue }

            var parts = calendar.dateComponents([.year, .month, .day], from: day)
            parts.hour = hour
            parts.minute = minute
            guard let moment = calendar.date(from: parts), moment > now else { continue }
            return moment
        }
        return nil
    }

    /// Whether this should be starting right now.
    ///
    /// The window is generous because a phone that was asleep may only get
    /// around to asking a minute or two late, and a schedule that silently
    /// skipped would be worse than one that starts slightly late.
    public func isDue(at now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard isEnabled else { return false }

        let parts = calendar.dateComponents([.hour, .minute], from: now)
        guard let nowHour = parts.hour, let nowMinute = parts.minute else { return false }
        let minutesNow = nowHour * 60 + nowMinute
        let minutesDue = hour * 60 + minute
        let late = minutesNow - minutesDue
        guard (0...3).contains(late) else { return false }

        if repeats {
            let weekday = calendar.component(.weekday, from: now) - 1
            guard weekdays & (1 << weekday) != 0 else { return false }
        } else {
            guard let day = onceOn, calendar.isDate(day, inSameDayAs: now) else { return false }
        }

        if let last = lastFiredAt, now.timeIntervalSince(last) < 600 { return false }
        return true
    }

    public var scheduleText: String {
        let time = String(format: "%d:%02d %@", hour % 12 == 0 ? 12 : hour % 12, minute, hour < 12 ? "AM" : "PM")
        guard repeats else {
            guard let day = onceOn else { return time }
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE d MMM"
            return "\(formatter.string(from: day)) at \(time)"
        }
        if weekdays == 0b1111111 { return "Every day at \(time)" }
        if weekdays == 0b0111110 { return "Weekdays at \(time)" }
        if weekdays == 0b1000001 { return "Weekends at \(time)" }
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let picked = (0..<7).filter { weekdays & (1 << $0) != 0 }.map { names[$0] }
        return "\(picked.joined(separator: ", ")) at \(time)"
    }
}
