import Foundation

public enum TrafficControlKind: String, Codable, Sendable {
    case signal
    case stop
    case giveWay
    case crossing
    case roundabout
}

/// How often each kind of thing on the road actually halts the car.
///
/// One copy, because two copies is how the route preview starts quietly
/// disagreeing with the drive it is previewing. `SpeedProfileBuilder` rolls
/// against these to decide whether a stop happens, and the route ribbon reads
/// the same numbers to decide whether to draw that stop as certain or as a
/// maybe. A signal is the exception: how often a driver catches a red is a
/// property of the driver, so it comes off the persona.
public enum StopOdds {
    /// A stop sign is a stop sign. You stop.
    public static let stopSign: Double = 1
    /// Most give ways have nothing coming.
    public static let giveWay: Double = 0.35
    /// A crossing with its own lights, holding traffic now and then.
    public static let signalledCrossing: Double = 0.15
    /// A plain zebra with nobody on it. Stopping at these at random was one of
    /// the things that looked wrong.
    public static let plainCrossing: Double = 0.03
    /// On foot there is no phase to wait for, only a gap in the traffic.
    public static let crossingOnFoot: Double = 0.2

    /// The chance this control stops the car, given who is driving and whether
    /// they are in it.
    public static func chance(
        of control: TrafficControl,
        persona: DriverPersona,
        onFoot: Bool
    ) -> Double {
        guard !onFoot else { return control.kind == .crossing ? crossingOnFoot : 0 }
        switch control.kind {
        case .signal: return persona.redLightProbability
        case .stop: return stopSign
        case .giveWay: return giveWay
        case .crossing: return control.isSignalled ? signalledCrossing : plainCrossing
        // A roundabout is a ceiling on the speed, not a halt.
        case .roundabout: return 0
        }
    }
}

public struct TrafficControl: Hashable, Codable, Sendable {
    public var kind: TrafficControlKind
    public var coordinate: Coordinate
    public var alongTrack: Double
    /// OSM says this sign faces the minor road (`stop=minor`) or one approach
    /// only (`direction=...`). The car on the through road does not stop for
    /// it, which was the "stops in weird places" complaint.
    public var appliesToMinorRoadOnly: Bool
    /// A pedestrian crossing with its own lights. A plain zebra crossing
    /// almost never stops a car; a signalled one does, sometimes.
    public var isSignalled: Bool

    /// A stable name for this control, for remembering that somebody crossed
    /// it off.
    ///
    /// Keyed on the coordinate, deliberately, not on `alongTrack`. The preview
    /// densifies the line at 5 m and the run densifies it at 4 m, so the same
    /// traffic light carries two different distances in the two places. The
    /// coordinate comes straight out of the road data and does not move.
    public var suppressionKey: String {
        kind.rawValue + "@" + String(format: "%.6f,%.6f", coordinate.latitude, coordinate.longitude)
    }

    public init(
        kind: TrafficControlKind,
        coordinate: Coordinate,
        alongTrack: Double,
        appliesToMinorRoadOnly: Bool = false,
        isSignalled: Bool = false
    ) {
        self.kind = kind
        self.coordinate = coordinate
        self.alongTrack = alongTrack
        self.appliesToMinorRoadOnly = appliesToMinorRoadOnly
        self.isSignalled = isSignalled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(TrafficControlKind.self, forKey: .kind)
        coordinate = try c.decode(Coordinate.self, forKey: .coordinate)
        alongTrack = try c.decode(Double.self, forKey: .alongTrack)
        appliesToMinorRoadOnly = try c.decodeIfPresent(Bool.self, forKey: .appliesToMinorRoadOnly) ?? false
        isSignalled = try c.decodeIfPresent(Bool.self, forKey: .isSignalled) ?? false
    }
}

public struct StopEvent: Hashable, Sendable {
    public var alongTrack: Double
    public var dwell: TimeInterval
    public var kind: TrafficControlKind

    public init(alongTrack: Double, dwell: TimeInterval, kind: TrafficControlKind) {
        self.alongTrack = alongTrack
        self.dwell = dwell
        self.kind = kind
    }
}
