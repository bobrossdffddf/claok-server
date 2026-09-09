import Foundation

public enum AppGroup {
    /// The group named in this build's signature.
    ///
    /// A sideloaded copy does not keep the bundle identifier it was built
    /// with: the installer rewrites it so the app belongs to whichever Apple
    /// ID signed it, and rewrites the app group to match. Reading the group
    /// out of the running signature is the only way to be right in both
    /// cases, so that is what happens here, with the built-in name as the
    /// fallback for the simulator and for previews.
    public static let identifier: String = resolveIdentifier()

    /// Whether this build actually has a shared container.
    ///
    /// Free Apple IDs may not get one. Everything that uses the group still
    /// works when it is missing — it just stops being shared with the
    /// extensions, which is a real but survivable loss.
    public static let isShared: Bool =
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) != nil

    public static var tunnelBundleIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "app.cloak.ios") + ".loopback"
    }

    nonisolated(unsafe) private static let suite = UserDefaults(suiteName: identifier)

    public static var defaults: UserDefaults { suite ?? .standard }

    public static var containerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    private static let fallbackIdentifier = "group.app.cloak"

    private static func resolveIdentifier() -> String {
        if let signed = signedGroups().first(where: { $0.contains("cloak") }) ?? signedGroups().first {
            return signed
        }
        return fallbackIdentifier
    }

    /// The `com.apple.security.application-groups` entitlement this copy was
    /// actually signed with, read out of the embedded provisioning profile.
    ///
    /// The profile is a CMS envelope with a plain XML plist inside it, so the
    /// plist can be lifted out without doing any crypto.
    private static func signedGroups() -> [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let opening = range(of: "<plist", in: data),
              let closing = range(of: "</plist>", in: data, from: opening.lowerBound) else {
            return []
        }

        let xml = data[opening.lowerBound..<closing.upperBound]
        guard let profile = try? PropertyListSerialization.propertyList(
                from: xml, options: [], format: nil) as? [String: Any],
              let entitlements = profile["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else {
            return []
        }
        return groups
    }

    private static func range(of marker: String, in data: Data, from start: Data.Index? = nil) -> Range<Data.Index>? {
        guard let needle = marker.data(using: .utf8) else { return nil }
        let lower = start ?? data.startIndex
        guard lower < data.endIndex else { return nil }
        return data.range(of: needle, in: lower..<data.endIndex)
    }
}

public enum TunnelCommand: Codable, Sendable {
    case start(TunnelStartPayload)
    case stop
    case snapshot
    case setPlaybackRate(Double)
    case panic
    case pause
    case resume
    case steer(bearing: Double, throttle: Double)
    case releaseSteering
    case status
    /// Clear the simulated fix so CoreLocation reports the real one again.
    case peekBegin
    /// Put the simulation back.
    case peekEnd
}

public struct TunnelStartPayload: Codable, Sendable {
    public var points: [Coordinate]
    public var postedLimits: [Double]
    public var controls: [TrafficControl]
    public var personaID: String
    public var mode: TravelMode
    public var playbackRate: Double
    public var loop: Bool
    public var seed: UInt64
    public var label: String
    /// How far a held position is allowed to drift, in metres. A phone left on
    /// a desk moves; one pinned to a single coordinate for hours does not.
    public var dwellRadius: Double

    public init(
        points: [Coordinate],
        postedLimits: [Double],
        controls: [TrafficControl],
        personaID: String,
        mode: TravelMode,
        playbackRate: Double,
        loop: Bool,
        seed: UInt64,
        label: String,
        dwellRadius: Double = 6
    ) {
        self.points = points
        self.postedLimits = postedLimits
        self.controls = controls
        self.personaID = personaID
        self.mode = mode
        self.playbackRate = playbackRate
        self.loop = loop
        self.seed = seed
        self.label = label
        self.dwellRadius = dwellRadius
    }

    public static func fixed(_ coordinate: Coordinate, label: String, dwellRadius: Double = 6) -> TunnelStartPayload {
        TunnelStartPayload(
            points: [coordinate],
            postedLimits: [],
            controls: [],
            personaID: DriverPersona.normal.id,
            mode: .walk,
            playbackRate: 1,
            loop: false,
            seed: UInt64.random(in: 1...UInt64.max),
            label: label,
            dwellRadius: dwellRadius
        )
    }
}

public enum TunnelReply: Codable, Sendable {
    case snapshot(SimulationSnapshot)
    case acknowledged
    case failed(String)
}
