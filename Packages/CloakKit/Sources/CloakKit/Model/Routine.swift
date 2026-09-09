import Foundation
import SwiftData

/// A life, rather than a trip.
///
/// Everything else in this category is session shaped: open the app, run one
/// route, stop, snap back. That is fine against somebody glancing at a map
/// once and hopeless against anyone who looks at a fortnight of history, where
/// the tell is not any single journey but the absence of all the others.
///
/// A routine is the other thing. It holds the places a phone actually lives
/// between, and it runs itself all day: asleep at home, out at the usual time
/// give or take a few minutes, parked at work with the phone drifting a few
/// metres the way a real one does on a desk, home again in the evening. No two
/// days come out the same, because the departure times and the pace are drawn
/// from a seed that includes the date.
@Model
public final class Routine {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool

    public var homeName: String
    public var homeLatitude: Double
    public var homeLongitude: Double

    public var workName: String
    public var workLatitude: Double
    public var workLongitude: Double

    /// When the phone usually leaves home, and when it leaves work.
    public var leaveHour: Int
    public var leaveMinute: Int
    public var returnHour: Int
    public var returnMinute: Int

    /// How far either time may slide on any given day.
    public var jitterMinutes: Int

    /// Which days this happens on. Bit per weekday, Sunday is bit zero.
    public var weekdays: Int

    public var modeRaw: String

    /// How far the phone wanders while it is sitting somewhere. A phone on a
    /// desk is not motionless; it is the same spot plus a few metres of GPS
    /// drift, and pinning it to one exact coordinate for eight hours is its
    /// own kind of tell.
    public var dwellDrift: Double

    public var seed: UInt64
    public var createdAt: Date
    public var lastRunDay: Date?

    public init(
        id: UUID = UUID(),
        name: String = "Weekday",
        home: Coordinate,
        homeName: String = "Home",
        work: Coordinate,
        workName: String = "Work",
        leaveHour: Int = 8,
        leaveMinute: Int = 15,
        returnHour: Int = 17,
        returnMinute: Int = 30,
        jitterMinutes: Int = 8,
        weekdays: Int = 0b0111110,
        mode: TravelMode = .drive,
        dwellDrift: Double = 9
    ) {
        self.id = id
        self.name = name
        self.isEnabled = true
        self.homeName = homeName
        self.homeLatitude = home.latitude
        self.homeLongitude = home.longitude
        self.workName = workName
        self.workLatitude = work.latitude
        self.workLongitude = work.longitude
        self.leaveHour = leaveHour
        self.leaveMinute = leaveMinute
        self.returnHour = returnHour
        self.returnMinute = returnMinute
        self.jitterMinutes = jitterMinutes
        self.weekdays = weekdays
        self.modeRaw = mode.rawValue
        self.dwellDrift = dwellDrift
        self.seed = UInt64.random(in: 1...UInt64.max)
        self.createdAt = .now
        self.lastRunDay = nil
    }

    public var home: Coordinate {
        Coordinate(latitude: homeLatitude, longitude: homeLongitude)
    }

    public var work: Coordinate {
        Coordinate(latitude: workLatitude, longitude: workLongitude)
    }

    public var mode: TravelMode { TravelMode(rawValue: modeRaw) ?? .drive }

    public var runsToday: Bool { runs(on: .now) }

    public func runs(on day: Date, calendar: Calendar = .current) -> Bool {
        guard isEnabled else { return false }
        let weekday = calendar.component(.weekday, from: day) - 1
        return weekdays & (1 << weekday) != 0
    }

    public var summary: String {
        let leave = Self.clock(leaveHour, leaveMinute)
        let back = Self.clock(returnHour, returnMinute)
        return "Out around \(leave), back around \(back), give or take \(jitterMinutes) min"
    }

    static func clock(_ hour: Int, _ minute: Int) -> String {
        String(format: "%d:%02d %@", hour % 12 == 0 ? 12 : hour % 12, minute, hour < 12 ? "AM" : "PM")
    }
}

// MARK: - A day of it

public struct RoutineDay: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case dwell(Coordinate, name: String, drift: Double)
        case travel(from: Coordinate, to: Coordinate, name: String, mode: TravelMode)

        public var name: String {
            switch self {
            case .dwell(_, let name, _): name
            case .travel(_, _, let name, _): name
            }
        }
    }

    public struct Segment: Sendable, Equatable, Identifiable {
        public var id: String { "\(start.timeIntervalSince1970)-\(kind.name)" }
        public var start: Date
        public var end: Date
        public var kind: Kind

        public func contains(_ moment: Date) -> Bool {
            moment >= start && moment < end
        }
    }

    public var segments: [Segment]

    public func segment(at moment: Date) -> Segment? {
        segments.first { $0.contains(moment) }
    }

    public func next(after moment: Date) -> Segment? {
        segments.first { $0.start > moment }
    }
}

public extension Routine {
    /// Lays out one specific day.
    ///
    /// The jitter is drawn from the routine's seed mixed with the date, so the
    /// same day always plans the same way — which matters, because a plan that
    /// changed every time it was consulted would have the phone turning round
    /// halfway to work — while no two days are alike.
    func plan(for day: Date = .now, calendar: Calendar = .current) -> RoutineDay {
        let midnight = calendar.startOfDay(for: day)
        guard runs(on: day, calendar: calendar) else {
            return RoutineDay(segments: [
                RoutineDay.Segment(
                    start: midnight,
                    end: calendar.date(byAdding: .day, value: 1, to: midnight) ?? midnight,
                    kind: .dwell(home, name: homeName, drift: dwellDrift)
                )
            ])
        }

        let dayNumber = UInt64(max(0, calendar.ordinality(of: .day, in: .era, for: day) ?? 0))
        var generator = SeededGenerator(seed: seed &+ dayNumber &* 0x9E37_79B9_7F4A_7C15)

        let slack = Double(max(0, jitterMinutes))
        let leaveShift = generator.gaussian(mean: 0, deviation: slack / 2).clamped(to: -slack...slack)
        let returnShift = generator.gaussian(mean: 0, deviation: slack / 2).clamped(to: -slack...slack)

        let leave = time(midnight, leaveHour, leaveMinute, plusMinutes: leaveShift, calendar: calendar)
        let leaveWork = time(midnight, returnHour, returnMinute, plusMinutes: returnShift, calendar: calendar)

        // A rough travel time, only used to decide when dwelling resumes. The
        // real arrival is whenever the drive actually finishes.
        let metres = home.distance(to: work)
        let pace: Double = mode == .drive ? 13.0 : 1.35
        let commute = max(120, metres / pace * (1.0 + generator.double(in: -0.08...0.18)))

        let arriveWork = leave.addingTimeInterval(commute)
        let arriveHome = leaveWork.addingTimeInterval(commute * (1.0 + generator.double(in: -0.05...0.20)))
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: midnight) ?? midnight

        var segments: [RoutineDay.Segment] = []
        segments.append(.init(start: midnight, end: leave, kind: .dwell(home, name: homeName, drift: dwellDrift)))
        segments.append(.init(start: leave, end: arriveWork, kind: .travel(from: home, to: work, name: "To \(workName)", mode: mode)))
        if arriveWork < leaveWork {
            segments.append(.init(start: arriveWork, end: leaveWork, kind: .dwell(work, name: workName, drift: dwellDrift)))
        }
        segments.append(.init(start: max(leaveWork, arriveWork), end: arriveHome, kind: .travel(from: work, to: home, name: "To \(homeName)", mode: mode)))
        if arriveHome < endOfDay {
            segments.append(.init(start: arriveHome, end: endOfDay, kind: .dwell(home, name: homeName, drift: dwellDrift)))
        }

        return RoutineDay(segments: segments)
    }

    private func time(_ midnight: Date, _ hour: Int, _ minute: Int, plusMinutes: Double, calendar: Calendar) -> Date {
        let base = calendar.date(byAdding: DateComponents(hour: hour, minute: minute), to: midnight) ?? midnight
        return base.addingTimeInterval(plusMinutes * 60)
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
