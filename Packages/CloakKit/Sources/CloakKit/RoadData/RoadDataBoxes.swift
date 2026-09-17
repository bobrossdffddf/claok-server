import Foundation

public extension BoundingBox {
    /// Roughly how much ground this box covers, in square kilometres.
    ///
    /// Overpass is paid for in ground covered, not in route length. A route
    /// that runs diagonally has a box many times the area of the strip it
    /// actually needs, and the box is what the server reads. So area, not
    /// distance, is the number the splitter works in.
    var areaSquareKilometres: Double {
        let height = (maxLatitude - minLatitude) * .pi / 180 * Coordinate.earthRadius
        let middle = (minLatitude + maxLatitude) / 2
        let width = (maxLongitude - minLongitude) * .pi / 180
            * Coordinate.earthRadius * cos(middle * .pi / 180)
        return max(0, height) * max(0, width) / 1_000_000
    }

    /// The smallest box holding both.
    func union(_ other: BoundingBox) -> BoundingBox {
        BoundingBox(
            minLatitude: min(minLatitude, other.minLatitude),
            minLongitude: min(minLongitude, other.minLongitude),
            maxLatitude: max(maxLatitude, other.maxLatitude),
            maxLongitude: max(maxLongitude, other.maxLongitude)
        )
    }

    /// The smallest box holding this one and a point.
    func extended(to point: Coordinate) -> BoundingBox {
        BoundingBox(
            minLatitude: min(minLatitude, point.latitude),
            minLongitude: min(minLongitude, point.longitude),
            maxLatitude: max(maxLatitude, point.latitude),
            maxLongitude: max(maxLongitude, point.longitude)
        )
    }

    /// A box with no size, around one point.
    init(_ point: Coordinate) {
        self.init(
            minLatitude: point.latitude,
            minLongitude: point.longitude,
            maxLatitude: point.latitude,
            maxLongitude: point.longitude
        )
    }
}

/// Which boxes to ask Overpass for, for one route.
///
/// One box around the whole route is the wrong shape for anything but a route
/// that runs due north or due east. A 27 km trip across a city measures 6 km
/// by 27 km as a box: 173 square kilometres, of which the route needs a strip
/// about 7. Overpass answers for the box, so it was asked for, and sent, every
/// road in a quarter of the metro area: measured at 39.9 MB and 15 seconds on
/// the fastest mirror, which no phone request survives.
///
/// Cutting the line into pieces and taking a box around each one is the same
/// coverage for a fraction of the ground, because both sides of the box shrink
/// at once. The same trip in three pieces is 69 square kilometres.
public enum RoadDataBoxes {
    /// How far each box reaches past the line. A limit is looked up within
    /// 40 m of the route and a control within 10 m, so this is generous, and
    /// it is what lets a box answer for a slightly different line through the
    /// same streets.
    public static let padding: Double = 120

    /// The most ground one request should ask for.
    ///
    /// Above this the answer stops being worth waiting for on a phone: the
    /// mirror either spends its own timeout on it and truncates, or sends tens
    /// of megabytes. Below it a request is a couple of seconds and a couple of
    /// megabytes.
    public static let maximumArea: Double = 32

    /// The most requests one route may cost. A route long enough to need more
    /// gets coarser boxes instead of more requests, because Overpass is a free
    /// service and a hundred requests for one trip is not a fair use of it.
    public static let limit: Int = 12

    /// The boxes covering a route, in order along it.
    ///
    /// Consecutive boxes share the point they were cut at, and each is padded,
    /// so the union covers every metre of the line with at least `padding`
    /// either side. Nothing falls down the seam.
    public static func boxes(
        for polyline: Polyline,
        padding: Double = padding,
        maximumArea: Double = maximumArea,
        limit: Int = limit
    ) -> [BoundingBox] {
        let points = sampled(polyline)
        guard let first = points.first else { return [] }
        guard points.count > 1 else { return [BoundingBox(first).padded(byMeters: padding)] }

        var target = max(0.01, maximumArea)
        // A long route is covered by coarser boxes rather than by more
        // requests. The growth is bounded: each pass at least halves the count.
        for _ in 0..<12 {
            let split = cut(points, target: target, padding: padding)
            if split.count <= max(1, limit) { return split }
            target *= 1.7
        }
        return cut(points, target: target, padding: padding)
    }

    /// True when every one of `inner` lies inside one of `outers`.
    ///
    /// The route's data is only what its own boxes covered, so an offered route
    /// can be answered from it only when its boxes are inside them. A box that
    /// merely sits in the outline of the first route's boxes is not covered:
    /// with the line cut into pieces, the outline holds ground nobody fetched.
    public static func covers(_ outers: [BoundingBox], _ inner: [BoundingBox]) -> Bool {
        guard !outers.isEmpty, !inner.isEmpty else { return false }
        return inner.allSatisfy { box in outers.contains { RouteBuilder.covers($0, box) } }
    }

    /// The whole outline of a set of boxes.
    public static func outline(_ boxes: [BoundingBox]) -> BoundingBox? {
        guard let first = boxes.first else { return nil }
        return boxes.dropFirst().reduce(first) { $0.union($1) }
    }

    // MARK: - Working parts

    /// The line at a spacing fine enough to cut at.
    ///
    /// A motorway leg can be two points fifty kilometres apart, and a box can
    /// only be cut where there is a point. Filling the line in first means the
    /// pieces are chosen by area rather than by wherever the road happened to
    /// bend.
    static func sampled(_ polyline: Polyline) -> [Coordinate] {
        guard polyline.points.count > 1 else { return polyline.points }
        let wanted = 96.0
        guard Double(polyline.points.count) < wanted else { return polyline.points }
        let spacing = max(10, polyline.length / wanted)
        return polyline.densified(spacing: spacing).points
    }

    static func cut(_ points: [Coordinate], target: Double, padding: Double) -> [BoundingBox] {
        var boxes: [BoundingBox] = []
        var start = 0
        var current = BoundingBox(points[0])

        var index = 1
        while index < points.count {
            let grown = current.extended(to: points[index])
            // Never cut a piece down to a single point: two points that are
            // already too far apart are one piece, however big it is.
            if index > start + 1, grown.padded(byMeters: padding).areaSquareKilometres > target {
                boxes.append(current.padded(byMeters: padding))
                start = index - 1
                current = BoundingBox(points[start]).extended(to: points[index])
            } else {
                current = grown
            }
            index += 1
        }
        boxes.append(current.padded(byMeters: padding))
        return boxes
    }
}
