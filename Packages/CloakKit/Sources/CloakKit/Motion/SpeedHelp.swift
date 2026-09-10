import Foundation

/// How fast a simulated drive goes, relative to the posted limit.
///
/// A route already carries the speed limit of every road along it, and the
/// engine already drives to a target derived from that. This is the knob on the
/// front of it: pick how a simulated drive should sit against the limits, and
/// every stretch of the route follows, adjusting as the limits change.
///
/// It shapes the drive Cloak simulates. It has no view of how the phone is
/// really moving and does not react to it.
public struct SpeedHelp: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        /// Sit against the posted limit, wherever the route goes.
        case auto
        /// Never exceed one number, whatever the limit says.
        case manual
    }

    public enum Profile: String, Codable, Sendable, CaseIterable, Identifiable {
        case slow
        case limit
        case aggressive

        public var id: String { rawValue }

        public var name: String {
            switch self {
            case .slow: "Slow"
            case .limit: "Speed limit"
            case .aggressive: "Aggressive"
            }
        }

        public var detail: String {
            switch self {
            case .slow: "About 3 to 5 mph under the limit"
            case .limit: "Within about 3 mph of the limit"
            case .aggressive: "About 5 to 8 mph over the limit"
            }
        }

        /// Middle of the band, in mph. The engine's own noise spreads the
        /// actual speed either side of it, which is what puts the drive inside
        /// the band rather than pinned to one value.
        public var offsetMph: Double {
            switch self {
            case .slow: -4
            case .limit: 0
            case .aggressive: 6.5
            }
        }
    }

    public var isEnabled: Bool
    public var mode: Mode
    public var profile: Profile
    /// Manual mode's ceiling, in mph.
    public var manualMaxMph: Double

    public init(
        isEnabled: Bool = false,
        mode: Mode = .auto,
        profile: Profile = .limit,
        manualMaxMph: Double = 60
    ) {
        self.isEnabled = isEnabled
        self.mode = mode
        self.profile = profile
        self.manualMaxMph = manualMaxMph
    }

    /// The target for a stretch of road with this posted limit, in metres per
    /// second. `fallback` is what the driver persona would have done.
    public func target(postedLimit: Double, fallback: Double) -> Double {
        guard isEnabled else { return fallback }

        switch mode {
        case .auto:
            return max(Speed.mph(5), postedLimit + Speed.mph(profile.offsetMph))
        case .manual:
            // Still bounded by the road: a 30 limit does not become 60 because
            // the ceiling was set there.
            return min(fallback, Speed.mph(manualMaxMph))
        }
    }

    /// What to show on screen for a stretch of road, in mph.
    public func targetMph(postedLimitMph: Double) -> Double {
        guard isEnabled else { return postedLimitMph }
        switch mode {
        case .auto: return max(5, postedLimitMph + profile.offsetMph)
        case .manual: return min(postedLimitMph, manualMaxMph)
        }
    }

    public var summary: String {
        guard isEnabled else { return "Off" }
        switch mode {
        case .auto: return profile.name
        case .manual: return "Never above \(Int(manualMaxMph.rounded())) mph"
        }
    }

    // MARK: - Changing one thing

    public func with(isEnabled: Bool) -> SpeedHelp {
        var copy = self
        copy.isEnabled = isEnabled
        return copy
    }

    public func with(mode: Mode) -> SpeedHelp {
        var copy = self
        copy.mode = mode
        return copy
    }

    public func with(profile: Profile) -> SpeedHelp {
        var copy = self
        copy.profile = profile
        return copy
    }

    public func with(manualMaxMph: Double) -> SpeedHelp {
        var copy = self
        copy.manualMaxMph = manualMaxMph
        return copy
    }

    // MARK: - Storage

    private static let key = "speedHelp"

    public static func load() -> SpeedHelp {
        guard let data = AppGroup.defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(SpeedHelp.self, from: data) else {
            return SpeedHelp()
        }
        return decoded
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        AppGroup.defaults.set(data, forKey: Self.key)
    }
}
