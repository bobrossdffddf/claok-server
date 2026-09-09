import Foundation

public struct SimulatedFix: Hashable, Codable, Sendable {
    public var coordinate: Coordinate
    public var speed: Double
    public var course: Double
    public var altitude: Double
    public var horizontalAccuracy: Double
    public var timestamp: Date

    public init(
        coordinate: Coordinate,
        speed: Double = 0,
        course: Double = 0,
        altitude: Double = 0,
        horizontalAccuracy: Double = 5,
        timestamp: Date = .now
    ) {
        self.coordinate = coordinate
        self.speed = speed
        self.course = course
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
    }
}
