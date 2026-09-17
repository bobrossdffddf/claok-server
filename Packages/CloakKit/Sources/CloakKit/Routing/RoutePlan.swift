import Foundation

/// How a trip is meant to finish at a waypoint.
public enum ArrivalStyle: Hashable, Codable, Sendable {
    /// Let the builder decide. It walks the last stretch when the car cannot
    /// get to the point, and drives up to the door when it can.
    case automatic
    /// Drive right up to the point whatever the map says. For a place that is
    /// genuinely a driveway.
    case driveAll
    /// Park this far out and walk the rest in, whatever the map says. For a
    /// terminal, a campus or anywhere the door is not on a road.
    case onFoot(metres: Double)
}

public struct RouteWaypoint: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var coordinate: Coordinate
    public var title: String
    /// How the trip should end here. Waypoints saved before this existed
    /// decode as `.automatic`.
    public var arrival: ArrivalStyle

    public init(id: UUID = UUID(), coordinate: Coordinate, title: String, arrival: ArrivalStyle = .automatic) {
        self.id = id
        self.coordinate = coordinate
        self.title = title
        self.arrival = arrival
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        coordinate = try container.decode(Coordinate.self, forKey: .coordinate)
        title = try container.decode(String.self, forKey: .title)
        arrival = try container.decodeIfPresent(ArrivalStyle.self, forKey: .arrival) ?? .automatic
    }
}

/// One stretch of a built route, and why it is the mode it is.
public struct RouteLeg: Hashable, Sendable {
    public enum Reason: String, Hashable, Codable, Sendable {
        /// The mode the whole trip was asked for.
        case requested
        /// Short enough that nobody would take the car.
        case shortHop
        /// The car route stops short of the point, so the rest is walked.
        case noRoadToTheDoor
        /// The waypoint asked to be arrived at on foot.
        case askedFor
    }

    public var mode: TravelMode
    /// Metres along the whole route.
    public var start: Double
    public var end: Double
    public var reason: Reason

    public init(mode: TravelMode, start: Double, end: Double, reason: Reason) {
        self.mode = mode
        self.start = start
        self.end = end
        self.reason = reason
    }

    public var length: Double { max(0, end - start) }

    /// A plain line for the route card.
    public var note: String {
        switch reason {
        case .requested: "\(mode.displayName) \(Self.readable(length))"
        case .shortHop: "Walk \(Self.readable(length)), too short to drive"
        case .noRoadToTheDoor: "Walk \(Self.readable(length)), no road to the door"
        case .askedFor: "Walk \(Self.readable(length)) at the end"
        }
    }

    static func readable(_ metres: Double) -> String {
        metres < 1000 ? "\(Int(metres.rounded()))m" : String(format: "%.1f km", metres / 1000)
    }
}

public struct RoutePlan: Sendable, Identifiable {
    /// One built route. A copy keeps it, so the same route relabelled once
    /// the others offered alongside it are finished is still recognisably the
    /// route already on screen.
    public var id: UUID
    public var waypoints: [RouteWaypoint]
    public var polyline: Polyline
    public var metadata: RoadMetadata
    public var mode: TravelMode
    public var expectedTravelTime: TimeInterval
    /// What the builder decided about each stretch. Empty when the whole route
    /// is one mode.
    public var legs: [RouteLeg]
    /// A short line that tells this route apart from the others offered for
    /// the same stops, such as "Fastest" or "2 min longer, via US-183 N".
    /// Built only from what Apple Maps said about each route.
    public var label: String
    /// Apple Maps' own name for the route, usually its main road, or empty
    /// when it gave none. On a trip with several stops, the name of the leg
    /// the offered routes differ on.
    public var routeName: String
    /// Apple Maps' notices about the route, such as tolls, word for word.
    public var advisories: [String]

    /// The label of a route that was not offered alongside any other.
    public static let defaultLabel = "Suggested route"

    public init(
        waypoints: [RouteWaypoint],
        polyline: Polyline,
        metadata: RoadMetadata,
        mode: TravelMode,
        expectedTravelTime: TimeInterval,
        legs: [RouteLeg] = [],
        label: String = RoutePlan.defaultLabel,
        routeName: String = "",
        advisories: [String] = [],
        id: UUID = UUID()
    ) {
        self.id = id
        self.waypoints = waypoints
        self.polyline = polyline
        self.metadata = metadata
        self.mode = mode
        self.expectedTravelTime = expectedTravelTime
        self.legs = legs
        self.label = label
        self.routeName = routeName
        self.advisories = advisories
    }

    /// True when this route was built for these stops in this mode.
    ///
    /// A stop's title does not count: renaming a stop does not move the line.
    /// Its identity, position and how it is arrived at all do.
    public func matches(waypoints other: [RouteWaypoint], mode otherMode: TravelMode) -> Bool {
        guard mode == otherMode, waypoints.count == other.count else { return false }
        return zip(waypoints, other).allSatisfy { mine, theirs in
            mine.id == theirs.id && mine.coordinate == theirs.coordinate && mine.arrival == theirs.arrival
        }
    }

    /// How much of the route is covered on foot, as the builder laid it out.
    public var walkingDistance: Double {
        legs.filter(\.mode.isOnFoot).reduce(0) { $0 + $1.length }
    }

    public var hasWalkingLeg: Bool { walkingDistance > 0 }

    /// The builder's own decision, in the form the simulation takes.
    ///
    /// `nil` when the builder recorded no legs, which means it never looked,
    /// and the simulation should fall back to working it out from the road
    /// data. An empty array would claim it looked and found nothing.
    public var walkingSpans: [WalkingLegs.Span]? {
        guard !legs.isEmpty else { return nil }
        return legs.map { WalkingLegs.Span(mode: $0.mode, start: $0.start, end: $0.end) }
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

        let modes = modes(of: densified, postedLimits: limits)

        var baseline = 0.0
        var adjusted = 0.0
        for (index, posted) in limits.enumerated() {
            // A walking stretch is not driven at any speed help setting, so
            // scaling it by one would move an arrival time that is not going
            // to move.
            if index < modes.count, modes[index] != .drive {
                baseline += posted
                adjusted += posted
                continue
            }
            let target = speedHelp.target(postedLimit: posted, fallback: posted)
            baseline += posted
            adjusted += max(target, Speed.mph(3))
        }
        guard adjusted > 0, baseline > 0 else { return expectedTravelTime }

        return expectedTravelTime * (baseline / adjusted)
    }

    /// The per point modes the motion engine will derive for this route.
    public func modes(spacing: Double = 5) -> [TravelMode] {
        let densified = polyline.densified(spacing: spacing)
        let limits = metadata.limits(along: densified, fallback: mode == .drive ? .residential : .footway)
        return modes(of: densified, postedLimits: limits)
    }

    /// The builder's legs when it recorded any, and only otherwise a guess
    /// read back out of the posted limits.
    ///
    /// Reading a walk out of speed limits is a last resort, not the design. In
    /// a city that maps its pavements, a footway runs alongside the road for
    /// the whole street, and whichever line measures nearer wins, so an
    /// ordinary drive can be told it is a walk. The builder asked Apple Maps
    /// for the walking route itself and does not have to guess.
    private func modes(of densified: Polyline, postedLimits limits: [Double]) -> [TravelMode] {
        if let walkingSpans {
            return WalkingLegs.modes(polyline: densified, spans: walkingSpans, fallback: mode)
        }
        return WalkingLegs.modes(polyline: densified, postedLimits: limits, requested: mode)
    }

    public func speedProfile(
        persona: DriverPersona,
        speedHelp: SpeedHelp = SpeedHelp(),
        /// Controls the person has crossed off, by `TrafficControl.suppressionKey`.
        ///
        /// This has to be a parameter rather than something applied at the one
        /// call site that starts the drive. The preview ribbon, the
        /// believability grade and the rehearsal all build their own profile,
        /// and if the removal only reached the drive then crossing off a light
        /// would leave two cards on the same screen disagreeing about how many
        /// times the car stops.
        suppressing: Set<String> = [],
        seed: UInt64
    ) -> SpeedProfile {
        let densified = polyline.densified(spacing: 5)
        let limits = metadata.limits(along: densified, fallback: mode == .drive ? .residential : .footway)
        let controls = metadata.snappedControls(to: densified)
            .filter { !suppressing.contains($0.suppressionKey) }
        return SpeedProfileBuilder.build(
            polyline: densified,
            postedLimits: limits,
            controls: controls,
            persona: persona,
            mode: mode,
            speedHelp: speedHelp,
            walkingSpans: walkingSpans,
            seed: seed
        )
    }
}
