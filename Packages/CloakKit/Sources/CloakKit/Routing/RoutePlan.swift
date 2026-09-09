import Foundation

public struct RouteWaypoint: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var coordinate: Coordinate
    public var title: String

    public init(id: UUID = UUID(), coordinate: Coordinate, title: String) {
        self.id = id
        self.coordinate = coordinate
        self.title = title
    }
}

public struct RoutePlan: Sendable {
    public var waypoints: [RouteWaypoint]
    public var polyline: Polyline
    public var metadata: RoadMetadata
    public var mode: TravelMode
    public var expectedTravelTime: TimeInterval

    public init(
        waypoints: [RouteWaypoint],
        polyline: Polyline,
        metadata: RoadMetadata,
        mode: TravelMode,
        expectedTravelTime: TimeInterval
    ) {
        self.waypoints = waypoints
        self.polyline = polyline
        self.metadata = metadata
        self.mode = mode
        self.expectedTravelTime = expectedTravelTime
    }

    public func speedProfile(persona: DriverPersona, seed: UInt64) -> SpeedProfile {
        let densified = polyline.densified(spacing: 5)
        let limits = metadata.limits(along: densified, fallback: mode == .drive ? .residential : .footway)
        let controls = metadata.snappedControls(to: densified)
        return SpeedProfileBuilder.build(
            polyline: densified,
            postedLimits: limits,
            controls: controls,
            persona: persona,
            mode: mode,
            seed: seed
        )
    }
}
