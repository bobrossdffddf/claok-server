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

    func interpolated(to other: Coordinate, fraction: Double) -> Coordinate {
        let t = min(max(fraction, 0), 1)
        return Coordinate(
            latitude: latitude + (other.latitude - latitude) * t,
            longitude: longitude + (other.longitude - longitude) * t
        )
    }
}
