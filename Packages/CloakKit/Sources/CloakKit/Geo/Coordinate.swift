import Foundation
import CoreLocation

public struct Coordinate: Hashable, Codable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public init(_ value: CLLocationCoordinate2D) {
        self.latitude = value.latitude
        self.longitude = value.longitude
    }

    public var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    public var isValid: Bool {
        latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180
    }
}

public extension Coordinate {
    static let earthRadius: Double = 6_371_008.8

    func distance(to other: Coordinate) -> Double {
        let phi1 = latitude * .pi / 180
        let phi2 = other.latitude * .pi / 180
        let dPhi = (other.latitude - latitude) * .pi / 180
        let dLambda = (other.longitude - longitude) * .pi / 180
        let a = sin(dPhi / 2) * sin(dPhi / 2) + cos(phi1) * cos(phi2) * sin(dLambda / 2) * sin(dLambda / 2)
        return 2 * Coordinate.earthRadius * atan2(sqrt(a), sqrt(1 - a))
    }

    func bearing(to other: Coordinate) -> Double {
        let phi1 = latitude * .pi / 180
        let phi2 = other.latitude * .pi / 180
        let dLambda = (other.longitude - longitude) * .pi / 180
        let y = sin(dLambda) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLambda)
        let theta = atan2(y, x) * 180 / .pi
        return theta < 0 ? theta + 360 : theta
    }

    func offset(metersNorth north: Double, metersEast east: Double) -> Coordinate {
        let dLat = north / Coordinate.earthRadius * 180 / .pi
        let dLon = east / (Coordinate.earthRadius * cos(latitude * .pi / 180)) * 180 / .pi
        return Coordinate(latitude: latitude + dLat, longitude: longitude + dLon)
    }

    func moved(bearing: Double, distance: Double) -> Coordinate {
        let theta = bearing * .pi / 180
        return offset(metersNorth: cos(theta) * distance, metersEast: sin(theta) * distance)
    }

    /// Distance from this point to the straight segment a–b, in metres, and
    /// how far along the segment (0...1) the nearest point lies. A local flat
    /// projection around this point is accurate to well under a metre at the
    /// distances involved (roads and routes, not continents).
    func distance(toSegmentFrom a: Coordinate, to b: Coordinate) -> (metres: Double, fraction: Double) {
        let kLat = Coordinate.earthRadius * .pi / 180
        let kLon = kLat * cos(latitude * .pi / 180)
        let ax = (a.longitude - longitude) * kLon, ay = (a.latitude - latitude) * kLat
        let bx = (b.longitude - longitude) * kLon, by = (b.latitude - latitude) * kLat
        let dx = bx - ax, dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return (sqrt(ax * ax + ay * ay), 0) }
        var t = -(ax * dx + ay * dy) / lengthSquared
        t = min(max(t, 0), 1)
        let px = ax + t * dx, py = ay + t * dy
        return (sqrt(px * px + py * py), t)
    }

    func interpolated(to other: Coordinate, fraction: Double) -> Coordinate {
        let t = min(max(fraction, 0), 1)
        return Coordinate(
            latitude: latitude + (other.latitude - latitude) * t,
            longitude: longitude + (other.longitude - longitude) * t
        )
    }
}
