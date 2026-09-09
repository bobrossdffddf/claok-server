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

    public init(kind: TrafficControlKind, coordinate: Coordinate, alongTrack: Double) {
        self.kind = kind
        self.coordinate = coordinate
        self.alongTrack = alongTrack
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
