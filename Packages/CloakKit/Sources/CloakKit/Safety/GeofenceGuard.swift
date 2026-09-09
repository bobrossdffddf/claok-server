import Foundation

public struct GeofenceGuard: Hashable, Codable, Sendable {
    public var center: Coordinate
    public var radius: Double
    public var isEnabled: Bool

    public init(center: Coordinate, radius: Double = 25_000, isEnabled: Bool = false) {
        self.center = center
        self.radius = radius
        self.isEnabled = isEnabled
    }

    public func shouldStop(realPosition: Coordinate) -> Bool {
        guard isEnabled else { return false }
        return center.distance(to: realPosition) > radius
    }
}

public enum SafetyEvent: Equatable, Sendable {
    case panicRestore
    case geofenceBreach(distance: Double)
    case tunnelLost
    case routeFinished
}
