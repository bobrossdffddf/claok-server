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

    /// How long the drive takes at the chosen profile.
    ///
    /// The routing service's own estimate assumes its own speeds, so with a
    /// profile applied it describes a different drive from the one being
    /// simulated. Scaling it by the ratio of the targets keeps the arrival time
    /// on screen honest about what is actually going to happen.
    public func expectedTravelTime(with speedHelp: SpeedHelp) -> TimeInterval {
        guard speedHelp.isEnabled, mode == .drive else { return expectedTravelTime }

        let densified = polyline.densified(spacing: 5)
        let limits = metadata.limits(along: densified, fallback: .residential)
        guard !limits.isEmpty else { return expectedTravelTime }

        var baseline = 0.0
        var adjusted = 0.0
        for posted in limits {
            let target = speedHelp.target(postedLimit: posted, fallback: posted)
            baseline += posted
            adjusted += max(target, Speed.mph(3))
        }
        guard adjusted > 0, baseline > 0 else { return expectedTravelTime }

        return expectedTravelTime * (baseline / adjusted)
    }

    public func speedProfile(
        persona: DriverPersona,
        speedHelp: SpeedHelp = SpeedHelp(),
        seed: UInt64
    ) -> SpeedProfile {
        let densified = polyline.densified(spacing: 5)
        let limits = metadata.limits(along: densified, fallback: mode == .drive ? .residential : .footway)
        let controls = metadata.snappedControls(to: densified)
        return SpeedProfileBuilder.build(
            polyline: densified,
            postedLimits: limits,
            controls: controls,
            persona: persona,
            mode: mode,
            speedHelp: speedHelp,
            seed: seed
        )
    }
}
