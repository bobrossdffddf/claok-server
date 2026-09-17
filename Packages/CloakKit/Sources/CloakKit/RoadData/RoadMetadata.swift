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

    /// One route's road data, from the boxes it was fetched in.
    ///
    /// Boxes overlap at the seams on purpose, so the same road comes back in
    /// two of them. Duplicates are dropped: every extra copy is another line
    /// for every point of the route to be measured against, and the limit
    /// lookup is the slowest thing in the build.
    ///
    /// A part that could not be fetched makes the whole thing a fallback. The
    /// route really is missing road data somewhere along it, and saying so is
    /// what gets it fetched again rather than quietly driven on defaults.
    public static func merged(_ parts: [RoadMetadata]) -> RoadMetadata {
        guard !parts.isEmpty else { return .empty }
        guard parts.count > 1 else { return parts[0] }

        var segments: [RoadSegment] = []
        var seenSegments: Set<RoadSegment> = []
        var controls: [TrafficControl] = []
        var seenControls: Set<TrafficControl> = []
        var fallback = false
        var fetchedAt = Date.distantFuture

        for part in parts {
            fallback = fallback || part.wasFallback
            fetchedAt = min(fetchedAt, part.fetchedAt)
            for segment in part.segments where seenSegments.insert(segment).inserted {
                segments.append(segment)
            }
            for control in part.controls where seenControls.insert(control).inserted {
                controls.append(control)
            }
        }
        return RoadMetadata(
            segments: segments,
            controls: controls,
            fetchedAt: fetchedAt == .distantFuture ? .now : fetchedAt,
            wasFallback: fallback
        )
    }

    /// True when there is nothing here to read a limit or a stop off.
    public var isEmpty: Bool { segments.isEmpty && controls.isEmpty }

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

        // A road whose box is further than this from the point cannot be the
        // road under it. Roughly 150 m in degrees.
        let boxSlack = 0.0015
        let middle = points.isEmpty ? 0 : points[points.count / 2].latitude
        let boxes: [BoundingBox] = segments.map { Polyline(points: $0.nodes).boundingBox() }
        // Which of those boxes are near a point is a lookup rather than a scan.
        // Walking eight thousand roads for each of seven thousand points is
        // fifty seven million comparisons, and it showed.
        let index = SpatialIndex(
            boxes: boxes,
            latitudeSlack: boxSlack,
            longitudeSlack: SpatialIndex.longitudeSlack(boxSlack, atLatitude: middle)
        )

        for position in points.indices {
            let point = points[position]
            let routeBearing = polyline.bearing(at: cumulative[position])
            var bestScore = Double.greatestFiniteMagnitude
            var bestDistance = Double.greatestFiniteMagnitude
            var bestLimit = fallback.defaultLimit

            for candidate in index.candidates(near: point) {
                let segmentIndex = Int(candidate)
                let box = boxes[segmentIndex]
                if point.latitude < box.minLatitude - boxSlack || point.latitude > box.maxLatitude + boxSlack
                    || point.longitude < box.minLongitude - boxSlack || point.longitude > box.maxLongitude + boxSlack {
                    continue
                }
                let nodes = segments[segmentIndex].nodes
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
                        bestLimit = segments[segmentIndex].effectiveLimit
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

    /// How far short of a control node a waiting car actually sits.
    ///
    /// OSM puts the signal or sign on the junction node, and the nearest point
    /// on the route to that node is the junction itself. A car does not wait
    /// in the junction: it waits at the stop line, a few metres short of the
    /// crossing road, and the phone is another car length back from that.
    /// Stopping on the node put the car past the light instead of at it, which
    /// is what the "stops on the wrong side" report describes.
    public static let stopLineSetback: Double = 8

    /// Controls that sit on the road the route follows, placed at the point on
    /// the approach where a car would actually come to rest.
    ///
    /// The tolerance used to be 15 m, which is wide enough to catch the stop
    /// sign on the side street and halt the car mid block on the main road. A
    /// node on the road being driven lies within a few metres of the route
    /// line; anything further off belongs to another road.
    public func snappedControls(to polyline: Polyline, tolerance: Double = 10) -> [TrafficControl] {
        guard !controls.isEmpty else { return [] }
        let points = polyline.points
        guard points.count > 1 else { return [] }
        let cumulative = polyline.cumulative

        // The route line, one straight piece at a time, in a grid. A route
        // box holds thousands of controls and a route holds thousands of
        // points; measuring every pair was tens of millions of comparisons for
        // the forty controls that actually sit on the road being driven.
        var pieces: [BoundingBox] = []
        pieces.reserveCapacity(points.count - 1)
        for index in 0..<(points.count - 1) {
            pieces.append(BoundingBox(points[index]).extended(to: points[index + 1]))
        }
        let latitudeSlack = tolerance / 111_320 * 1.5
        let index = SpatialIndex(
            boxes: pieces,
            latitudeSlack: latitudeSlack,
            longitudeSlack: SpatialIndex.longitudeSlack(latitudeSlack, atLatitude: points[points.count / 2].latitude)
        )

        var output: [TrafficControl] = []
        for control in controls {
            var bestOffset = Double.greatestFiniteMagnitude
            var bestAlong: Double = 0
            for candidate in index.candidates(near: control.coordinate) {
                let piece = Int(candidate)
                let (metres, fraction) = control.coordinate
                    .distance(toSegmentFrom: points[piece], to: points[piece + 1])
                if metres < bestOffset {
                    bestOffset = metres
                    bestAlong = cumulative[piece] + fraction * (cumulative[piece + 1] - cumulative[piece])
                }
            }
            guard bestOffset <= tolerance else { continue }
            if control.appliesToMinorRoadOnly, control.kind == .stop || control.kind == .giveWay { continue }
            var snapped = control
            // A roundabout is a stretch of slow road rather than a line to
            // halt at, so it keeps the node's own position and only the
            // things a car stops for move back to the approach.
            let setback = control.kind == .roundabout ? 0 : Self.stopLineSetback
            snapped.alongTrack = max(0, bestAlong - setback)
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
