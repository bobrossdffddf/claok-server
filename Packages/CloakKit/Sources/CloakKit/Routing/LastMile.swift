import Foundation

/// The part of a trip the car cannot do.
///
/// Apple Maps routes a car to the nearest thing a car can be on, then stops.
/// Ask it to drive to an airport terminal, a pedestrian square, a hospital
/// entrance or a campus building and the line it hands back ends out on the
/// road, sometimes several hundred metres short. Cloak used to take that line
/// as the whole trip and then start the next leg at the point that was asked
/// for, which put a jump in the history exactly where a person would have got
/// out and walked.
///
/// So the gap gets walked. The decisions are kept here, away from MapKit, so
/// they can be tested without a network.
public enum LastMile {
    /// Closer than this and the route simply starts or ends where it does.
    /// Map data snaps an address to the kerb, and a few metres of that is not
    /// a walk, it is rounding.
    public static let drivableGap: Double = 40

    /// Further than this and it is not the walk to the door, it is a second
    /// trip, and walking it would be less believable than not.
    public static let longestWalkIn: Double = 1_200

    /// A trip this short is walked. Nobody starts a car, pulls out and parks
    /// again to cover three hundred metres.
    public static let shortHop: Double = 400

    /// A walking route may wind, but one that is several times the straight
    /// line is going somewhere else. Usually it means the map has no path and
    /// has sent the walk round by the road.
    public static let detourLimit: Double = 3.0

    /// True when the car has stopped far enough short that a person would
    /// walk the rest.
    public static func walksIn(gap: Double) -> Bool {
        gap > drivableGap && gap <= longestWalkIn
    }

    /// True when a walking route for that gap is worth using.
    public static func accepts(walkLength: Double, gap: Double) -> Bool {
        guard walkLength > 0, gap > 0 else { return false }
        guard walkLength <= longestWalkIn * detourLimit else { return false }
        return walkLength <= max(gap * detourLimit, gap + 100)
    }

    /// True when the whole leg is short enough to be walked rather than driven.
    public static func isShortHop(_ distance: Double) -> Bool {
        distance > 0 && distance <= shortHop
    }

    /// How wide a strip either side of the walked line counts as being on it.
    public static let walkCorridor: Double = 10

    /// The road data with the drivable roads taken out of the walked stretches.
    ///
    /// A footway laid on top of a road that runs along the same line does not
    /// win on its own: the limit lookup picks whichever candidate happens to
    /// measure nearest, and two lines on the same ground measure the same to
    /// within floating point. A stretch the car route refused to use is not a
    /// drivable road for the purpose of this trip, so the roads inside it are
    /// removed rather than left to compete. Everything outside the corridor is
    /// untouched, including the far ends of a road that merely passes through.
    public static func clearing(
        _ segments: [RoadSegment],
        along polyline: Polyline,
        spans: [ClosedRange<Double>],
        corridor: Double = walkCorridor
    ) -> [RoadSegment] {
        guard !spans.isEmpty, polyline.points.count > 1 else { return segments }

        let walked: [Polyline] = footways(along: polyline, spans: spans, spacing: 4)
            .map { Polyline(points: $0.nodes) }
            .filter { $0.points.count > 1 }
        guard !walked.isEmpty else { return segments }
        let reach = walked.map { $0.boundingBox().padded(byMeters: corridor + 5) }

        func inside(_ point: Coordinate) -> Bool {
            for (index, line) in walked.enumerated() {
                guard reach[index].contains(point) else { continue }
                if line.nearestDistance(to: point).offset <= corridor { return true }
            }
            return false
        }

        var output: [RoadSegment] = []
        for segment in segments {
            guard segment.nodes.count > 1 else {
                output.append(segment)
                continue
            }
            let line = Polyline(points: segment.nodes)
            let box = line.boundingBox()
            guard reach.contains(where: { overlaps($0, box) }) else {
                output.append(segment)
                continue
            }
            // A way drawn with two nodes a kilometre apart can cross the walk
            // without either node being near it, so the test is made on a line
            // fine enough to catch that.
            var run: [Coordinate] = []
            for node in line.densified(spacing: 5).points {
                if inside(node) {
                    if run.count > 1 {
                        output.append(RoadSegment(roadClass: segment.roadClass, limit: segment.limit, nodes: run))
                    }
                    run = []
                } else {
                    run.append(node)
                }
            }
            if run.count > 1 {
                output.append(RoadSegment(roadClass: segment.roadClass, limit: segment.limit, nodes: run))
            }
        }
        return output
    }

    /// The road data for a route, with the walked stretches described as what
    /// they are. This is the whole of what the builder hands on.
    public static func describing(
        _ metadata: RoadMetadata,
        walked spans: [ClosedRange<Double>],
        along polyline: Polyline
    ) -> RoadMetadata {
        guard !spans.isEmpty else { return metadata }
        var output = metadata
        output.segments = clearing(metadata.segments, along: polyline, spans: spans)
        output.segments.append(contentsOf: footways(along: polyline, spans: spans))
        return output
    }

    static func overlaps(_ a: BoundingBox, _ b: BoundingBox) -> Bool {
        a.minLatitude <= b.maxLatitude && a.maxLatitude >= b.minLatitude
            && a.minLongitude <= b.maxLongitude && a.maxLongitude >= b.minLongitude
    }

    /// Footways laid along the stretches that were walked.
    ///
    /// The route builder knows which parts it walked, but the simulation
    /// rebuilds the speed profile from nothing but the points, the posted
    /// limits and the controls. Writing the walked stretches into the road
    /// data as what they are, ways with a walking limit, carries the decision
    /// across without the payload needing a new field, and it is an honest
    /// description: a stretch Apple Maps would only route on foot is a
    /// footway whether or not Overpass had it.
    public static func footways(
        along polyline: Polyline,
        spans: [ClosedRange<Double>],
        spacing: Double = 8
    ) -> [RoadSegment] {
        guard polyline.points.count > 1, spacing > 0 else { return [] }
        var output: [RoadSegment] = []
        for span in spans {
            let start = max(0, span.lowerBound)
            let end = min(polyline.length, span.upperBound)
            guard end - start > 1 else { continue }
            var nodes: [Coordinate] = []
            var along = start
            while along < end {
                nodes.append(polyline.coordinate(at: along))
                along += spacing
            }
            nodes.append(polyline.coordinate(at: end))
            guard nodes.count > 1 else { continue }
            output.append(RoadSegment(roadClass: .footway, limit: nil, nodes: nodes))
        }
        return output
    }
}
