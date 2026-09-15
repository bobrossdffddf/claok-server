import Foundation

/// SHIELD: Speed Helping Emulator Is Low Detection.
///
/// A real drive, reported at or near the speed limit. The phone keeps moving
/// as it really does; what other apps see is a shadow of that drive which
/// never exceeds the posted limit plus the chosen allowance. When the car goes
/// faster than that, the shadow falls behind and catches up when the car slows
/// or stops, so the arrival is a little later but every reported speed is one
/// the road allows.
public struct ShieldSettings: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Never above the limit.
        case slow
        /// Up to 5 mph over.
        case fast
        /// Up to 10 mph over.
        case `super`

        public var id: String { rawValue }

        public var name: String {
            switch self {
            case .slow: "Slow"
            case .fast: "Fast"
            case .super: "Super"
            }
        }

        public var detail: String {
            switch self {
            case .slow: "Exactly the speed limit"
            case .fast: "Up to 5 mph over the limit"
            case .super: "Up to 10 mph over the limit"
            }
        }

        public var allowanceMph: Double {
            switch self {
            case .slow: 0
            case .fast: 5
            case .super: 10
            }
        }
    }

    public var isEnabled: Bool
    public var mode: Mode

    public init(isEnabled: Bool = false, mode: Mode = .slow) {
        self.isEnabled = isEnabled
        self.mode = mode
    }

    public func with(isEnabled: Bool) -> ShieldSettings { var c = self; c.isEnabled = isEnabled; return c }
    public func with(mode: Mode) -> ShieldSettings { var c = self; c.mode = mode; return c }

    private static let key = "shield"

    public static func load() -> ShieldSettings {
        guard let data = AppGroup.defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(ShieldSettings.self, from: data) else {
            return ShieldSettings()
        }
        return decoded
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        AppGroup.defaults.set(data, forKey: Self.key)
    }
}

/// One real fix, as CoreLocation delivered it.
public struct RealFix: Sendable, Equatable {
    public var coordinate: Coordinate
    public var speed: Double
    public var timestamp: Date

    public init(coordinate: Coordinate, speed: Double, timestamp: Date) {
        self.coordinate = coordinate
        self.speed = speed
        self.timestamp = timestamp
    }
}

/// The shadow drive.
///
/// Keeps a breadcrumb trail of where the phone really went and moves a
/// reported position along that trail no faster than the cap. Fallback limit
/// applies where the road is unknown. Deterministic and pure so it can be
/// tested on a computer.
public struct ShieldEngine: Sendable {
    public private(set) var trail: [Coordinate] = []
    private var cumulative: [Double] = [0]
    /// How far along the trail the phone really is (its end).
    public var realDistance: Double { cumulative.last ?? 0 }
    /// How far along the trail the reported position is.
    public private(set) var shownDistance: Double = 0
    public private(set) var shownSpeed: Double = 0
    public private(set) var lastRealSpeed: Double = 0
    private var lastCourse: Double = 0
    public let settings: ShieldSettings
    public let fallbackLimit: Double

    /// Real fixes closer than this to the last one are jitter, not travel.
    private static let minimumStep: Double = 2

    public init(settings: ShieldSettings, fallbackLimit: Double = Speed.mph(30)) {
        self.settings = settings
        self.fallbackLimit = fallbackLimit
    }

    /// Feed a real fix. The trail only grows; a fix that jumps backwards
    /// (GPS noise while stopped) is ignored.
    public mutating func observe(_ fix: RealFix) {
        lastRealSpeed = max(0, fix.speed)
        guard let last = trail.last else {
            trail = [fix.coordinate]
            cumulative = [0]
            return
        }
        let step = last.distance(to: fix.coordinate)
        guard step >= Self.minimumStep else { return }
        // A single impossible jump (tunnel, bad fix) is still followed: the
        // shadow will drive it at the cap, which is the honest outcome.
        trail.append(fix.coordinate)
        cumulative.append(realDistance + step)
    }

    /// How far the real phone is ahead of what is being reported, in metres.
    public var holdingBack: Double { max(0, realDistance - shownDistance) }

    /// Advance the reported position by `dt` seconds. `limitAt` gives the
    /// posted limit at a coordinate, or nil where the road is unknown.
    public mutating func step(deltaTime dt: Double, limitAt: (Coordinate) -> Double?) -> SimulatedFix? {
        guard trail.count >= 1 else { return nil }
        let here = coordinate(at: shownDistance)
        let limit = limitAt(here) ?? fallbackLimit
        let cap = limit + Speed.mph(settings.mode.allowanceMph)

        let gap = realDistance - shownDistance
        var advance: Double
        if gap <= 0 {
            advance = 0
        } else {
            // Caught up: follow at the real pace. Behind: close the gap at the
            // cap, which is the fastest the shadow is ever allowed to go.
            let realPace = min(lastRealSpeed, cap)
            let closing = gap > Self.minimumStep * 2 ? cap : realPace
            advance = min(gap, closing * dt)
        }
        shownDistance += advance
        shownSpeed = dt > 0 ? advance / dt : 0

        let position = coordinate(at: shownDistance)
        if advance > 0.3 {
            lastCourse = bearing(at: shownDistance)
        }
        return SimulatedFix(
            coordinate: position,
            speed: shownSpeed,
            course: shownSpeed > 0.3 ? lastCourse : -1,
            horizontalAccuracy: 5
        )
    }

    private func coordinate(at distance: Double) -> Coordinate {
        guard trail.count > 1 else { return trail[0] }
        let d = min(max(distance, 0), realDistance)
        var index = 0
        while index < cumulative.count - 2 && cumulative[index + 1] < d { index += 1 }
        let span = cumulative[index + 1] - cumulative[index]
        let fraction = span > 0 ? (d - cumulative[index]) / span : 0
        return trail[index].interpolated(to: trail[index + 1], fraction: fraction)
    }

    private func bearing(at distance: Double) -> Double {
        guard trail.count > 1 else { return 0 }
        let d = min(max(distance, 0), realDistance)
        var index = 0
        while index < cumulative.count - 2 && cumulative[index + 1] < d { index += 1 }
        return trail[index].bearing(to: trail[index + 1])
    }
}
