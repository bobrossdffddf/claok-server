import Foundation

/// A coarse grid over a set of boxes, so a point can find the few of them near
/// it without being measured against all of them.
///
/// This exists because the road data finally started arriving. A 34 km route
/// comes back with about eight thousand roads and five thousand controls, and
/// both the limit lookup and the control snapping walked the whole list for
/// every point of the route: measured at 8.5 seconds on a Mac for one route,
/// which is worse on a phone than the request it was waiting for.
struct SpatialIndex: Sendable {
    /// About 200 m north to south. Small enough that a cell holds a handful of
    /// roads, large enough that a long way does not fill the table.
    static let cell: Double = 0.002

    private var buckets: [Int64: [Int32]] = [:]
    /// Boxes too large to be worth bucketing, measured against everything.
    private var everywhere: [Int32] = []

    /// - Parameters:
    ///   - boxes: what to index, in the order the caller will look them up by.
    ///   - latitudeSlack: how far past a box a point still counts as near it.
    ///   - longitudeSlack: the same, east to west, which is more degrees for
    ///     the same distance the further from the equator it is.
    init(boxes: [BoundingBox], latitudeSlack: Double, longitudeSlack: Double, cellLimit: Int = 512) {
        buckets.reserveCapacity(boxes.count * 2)
        for (offset, box) in boxes.enumerated() {
            let index = Int32(offset)
            let minLat = Int(floor((box.minLatitude - latitudeSlack) / Self.cell))
            let maxLat = Int(floor((box.maxLatitude + latitudeSlack) / Self.cell))
            let minLon = Int(floor((box.minLongitude - longitudeSlack) / Self.cell))
            let maxLon = Int(floor((box.maxLongitude + longitudeSlack) / Self.cell))
            guard minLat <= maxLat, minLon <= maxLon else { everywhere.append(index); continue }
            let cells = (maxLat - minLat + 1) * (maxLon - minLon + 1)
            guard cells <= cellLimit else { everywhere.append(index); continue }
            for latitude in minLat...maxLat {
                for longitude in minLon...maxLon {
                    buckets[Self.key(latitude, longitude), default: []].append(index)
                }
            }
        }
    }

    /// The boxes that might be near this point, as indices into what was
    /// indexed. Never misses one: a box is in every cell its slackened outline
    /// touches, so a point close enough to matter is in one of them.
    func candidates(near point: Coordinate) -> [Int32] {
        let latitude = Int(floor(point.latitude / Self.cell))
        let longitude = Int(floor(point.longitude / Self.cell))
        guard let found = buckets[Self.key(latitude, longitude)] else { return everywhere }
        guard !everywhere.isEmpty else { return found }
        return found + everywhere
    }

    static func key(_ latitude: Int, _ longitude: Int) -> Int64 {
        Int64(latitude) &* 4_000_037 &+ Int64(longitude)
    }

    /// Degrees of longitude that cover the same ground as `degrees` of
    /// latitude, at this latitude.
    static func longitudeSlack(_ degrees: Double, atLatitude latitude: Double) -> Double {
        degrees / max(0.15, cos(latitude * .pi / 180))
    }
}
