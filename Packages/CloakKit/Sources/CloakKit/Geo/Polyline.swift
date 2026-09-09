import Foundation

public struct Polyline: Sendable {
    public private(set) var points: [Coordinate]
    public private(set) var cumulative: [Double]

    public init(points: [Coordinate]) {
        self.points = points
        var running: [Double] = []
        running.reserveCapacity(points.count)
        var total: Double = 0
        for index in points.indices {
            if index > 0 { total += points[index - 1].distance(to: points[index]) }
            running.append(total)
        }
        self.cumulative = running
    }

    public var length: Double { cumulative.last ?? 0 }
    public var isEmpty: Bool { points.count < 2 }

    public func coordinate(at distance: Double) -> Coordinate {
        guard let first = points.first else { return Coordinate(latitude: 0, longitude: 0) }
        guard points.count > 1 else { return first }
        if distance <= 0 { return first }
        if distance >= length { return points[points.count - 1] }
        var low = 0
        var high = cumulative.count - 1
        while low + 1 < high {
            let mid = (low + high) / 2
            if cumulative[mid] <= distance { low = mid } else { high = mid }
        }
        let span = cumulative[high] - cumulative[low]
        let fraction = span > 0 ? (distance - cumulative[low]) / span : 0
        return points[low].interpolated(to: points[high], fraction: fraction)
    }

    public func bearing(at distance: Double) -> Double {
        guard points.count > 1 else { return 0 }
        let ahead = coordinate(at: min(distance + 5, length))
        let behind = coordinate(at: max(distance - 5, 0))
        return behind.bearing(to: ahead)
    }

    public func densified(spacing: Double) -> Polyline {
        guard points.count > 1, spacing > 0 else { return self }
        var output: [Coordinate] = []
        var travelled: Double = 0
        while travelled < length {
            output.append(coordinate(at: travelled))
            travelled += spacing
        }
        output.append(points[points.count - 1])
        return Polyline(points: output)
    }

    public func nearestDistance(to target: Coordinate) -> (alongTrack: Double, offset: Double) {
        guard !points.isEmpty else { return (0, .greatestFiniteMagnitude) }
        var bestAlong: Double = 0
        var bestOffset = Double.greatestFiniteMagnitude
        for index in points.indices {
            let candidate = points[index].distance(to: target)
            if candidate < bestOffset {
                bestOffset = candidate
                bestAlong = cumulative[index]
            }
        }
        return (bestAlong, bestOffset)
    }

    public func boundingBox() -> BoundingBox {
        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        for point in points {
            minLat = min(minLat, point.latitude)
            maxLat = max(maxLat, point.latitude)
            minLon = min(minLon, point.longitude)
            maxLon = max(maxLon, point.longitude)
        }
        return BoundingBox(minLatitude: minLat, minLongitude: minLon, maxLatitude: maxLat, maxLongitude: maxLon)
    }
}

public struct BoundingBox: Hashable, Codable, Sendable {
    public var minLatitude: Double
    public var minLongitude: Double
    public var maxLatitude: Double
    public var maxLongitude: Double

    public init(minLatitude: Double, minLongitude: Double, maxLatitude: Double, maxLongitude: Double) {
        self.minLatitude = minLatitude
        self.minLongitude = minLongitude
        self.maxLatitude = maxLatitude
        self.maxLongitude = maxLongitude
    }

    public func padded(byMeters meters: Double) -> BoundingBox {
        let dLat = meters / Coordinate.earthRadius * 180 / .pi
        let midLat = (minLatitude + maxLatitude) / 2
        let dLon = meters / (Coordinate.earthRadius * cos(midLat * .pi / 180)) * 180 / .pi
        return BoundingBox(
            minLatitude: minLatitude - dLat,
            minLongitude: minLongitude - dLon,
            maxLatitude: maxLatitude + dLat,
            maxLongitude: maxLongitude + dLon
        )
    }

    public var overpassClause: String {
        String(format: "%.6f,%.6f,%.6f,%.6f", minLatitude, minLongitude, maxLatitude, maxLongitude)
    }

    public func contains(_ point: Coordinate) -> Bool {
        point.latitude >= minLatitude && point.latitude <= maxLatitude &&
        point.longitude >= minLongitude && point.longitude <= maxLongitude
    }
}
