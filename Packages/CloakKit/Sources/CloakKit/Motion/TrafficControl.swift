import Foundation

public enum TrafficControlKind: String, Codable, Sendable {
    case signal
    case stop
    case giveWay
    case crossing
    case roundabout
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
