import Foundation

public struct RoadSegment: Hashable, Codable, Sendable {
    public var roadClass: RoadClass
    public var limit: Double?
    public var nodes: [Coordinate]

    public init(roadClass: RoadClass, limit: Double?, nodes: [Coordinate]) {
        self.roadClass = roadClass
        self.limit = limit
        self.nodes = nodes
    }

    public var effectiveLimit: Double { limit ?? roadClass.defaultLimit }
}

public struct RoadMetadata: Hashable, Codable, Sendable {
    public var segments: [RoadSegment]
    public var controls: [TrafficControl]
    public var fetchedAt: Date
    public var wasFallback: Bool

    public init(segments: [RoadSegment] = [], controls: [TrafficControl] = [], fetchedAt: Date = .now, wasFallback: Bool = false) {
        self.segments = segments
        self.controls = controls
        self.fetchedAt = fetchedAt
        self.wasFallback = wasFallback
    }

    public static let empty = RoadMetadata(wasFallback: true)

    /// The posted limit at every point of the route.
    ///
    /// Picks the road whose line runs nearest the point and in the same
    /// direction as the route there. The old version took the limit of the
    /// nearest road vertex, and long straight roads have few vertices, so a
    /// point mid block was often nearer to a side street's vertex than to any
    /// vertex of the road it was on, and inherited the side street's limit.
    public func limits(along polyline: Polyline, fallback: RoadClass = .residential) -> [Double] {
        guard !segments.isEmpty else {
            return Array(repeating: fallback.defaultLimit, count: polyline.points.count)
        }
        let points = polyline.points
        let cumulative = polyline.cumulative
        var output: [Double] = []
        output.reserveCapacity(points.count)

        // Cheap coarse filter: a road whose box is further than this from the
        // point cannot be the road under it. Roughly 150 m in degrees.
        let boxSlack = 0.0015
        let boxes: [BoundingBox] = segments.map { Polyline(points: $0.nodes).boundingBox() }

        for index in points.indices {
            let point = points[index]
            let routeBearing = polyline.bearing(at: cumulative[index])
            var bestScore = Double.greatestFiniteMagnitude
            var bestDistance = Double.greatestFiniteMagnitude
            var bestLimit = fallback.defaultLimit

            for (segmentIndex, segment) in segments.enumerated() {
                let box = boxes[segmentIndex]
                if point.latitude < box.minLatitude - boxSlack || point.latitude > box.maxLatitude + boxSlack
                    || point.longitude < box.minLongitude - boxSlack || point.longitude > box.maxLongitude + boxSlack {
                    continue
                }
                let nodes = segment.nodes
                guard nodes.count > 1 else { continue }
                for n in 0..<(nodes.count - 1) {
                    let (metres, _) = point.distance(toSegmentFrom: nodes[n], to: nodes[n + 1])
                    if metres > 40 { continue }
                    // Roads crossing ours at an intersection are just as near
                    // as ours; direction is what tells them apart.
                    let roadBearing = nodes[n].bearing(to: nodes[n + 1])
                    var delta = abs(roadBearing - routeBearing).truncatingRemainder(dividingBy: 360)
                    if delta > 180 { delta = 360 - delta }
                    if delta > 90 { delta = 180 - delta }
                    let penalty = delta > 35 ? 30.0 : 0.0
                    let score = metres + penalty
                    if score < bestScore {
                        bestScore = score
                        bestDistance = metres
                        bestLimit = segment.effectiveLimit
                    }
                }
            }
            output.append(bestDistance <= 40 ? bestLimit : fallback.defaultLimit)
        }
        return output
    }

    /// The posted limit on the road under one point, given the direction of
    /// travel there, or nil when no road is near. Same choice as
    /// `limits(along:)`, for one point at a time.
    public func limit(at point: Coordinate, heading: Double) -> Double? {
        guard !segments.isEmpty else { return nil }
        var bestScore = Double.greatestFiniteMagnitude
        var bestDistance = Double.greatestFiniteMagnitude
        var bestLimit: Double?
        for segment in segments {
            let nodes = segment.nodes
            guard nodes.count > 1 else { continue }
            for n in 0..<(nodes.count - 1) {
                let (metres, _) = point.distance(toSegmentFrom: nodes[n], to: nodes[n + 1])
                if metres > 40 { continue }
                let roadBearing = nodes[n].bearing(to: nodes[n + 1])
                var delta = abs(roadBearing - heading).truncatingRemainder(dividingBy: 360)
                if delta > 180 { delta = 360 - delta }
                if delta > 90 { delta = 180 - delta }
                let score = metres + (delta > 35 ? 30.0 : 0.0)
                if score < bestScore {
                    bestScore = score
                    bestDistance = metres
                    bestLimit = segment.effectiveLimit
                }
            }
        }
        return bestDistance <= 40 ? bestLimit : nil
    }

    /// Controls that sit on the road the route follows.
    ///
    /// The tolerance used to be 15 m, which is wide enough to catch the stop
    /// sign on the side street and halt the car mid block on the main road. A
    /// node on the road being driven lies within a few metres of the route
    /// line; anything further off belongs to another road.
    public func snappedControls(to polyline: Polyline, tolerance: Double = 10) -> [TrafficControl] {
        var output: [TrafficControl] = []
        for control in controls {
            let match = polyline.nearestDistance(to: control.coordinate)
            guard match.offset <= tolerance else { continue }
            if control.appliesToMinorRoadOnly, control.kind == .stop || control.kind == .giveWay { continue }
            var snapped = control
            snapped.alongTrack = match.alongTrack
            output.append(snapped)
        }
        output.sort { $0.alongTrack < $1.alongTrack }
        var deduped: [TrafficControl] = []
        for control in output {
            if let last = deduped.last, abs(last.alongTrack - control.alongTrack) < 12 { continue }
            deduped.append(control)
        }
        return deduped
    }
}
