import Foundation

public struct IdleJitter: Sendable {
    public var anchor: Coordinate
    public var radius: Double
    private var offsetNorth: Double = 0
    private var offsetEast: Double = 0
    private var generator: SeededGenerator

    public init(anchor: Coordinate, radius: Double = 6, seed: UInt64 = 0xC10A4) {
        self.anchor = anchor
        self.radius = radius
        self.generator = SeededGenerator(seed: seed)
    }

    public mutating func next(now: Date = .now) -> SimulatedFix {
        offsetNorth += generator.gaussian(mean: 0, deviation: 0.35)
        offsetEast += generator.gaussian(mean: 0, deviation: 0.35)
        let magnitude = sqrt(offsetNorth * offsetNorth + offsetEast * offsetEast)
        if magnitude > radius {
            let scale = radius / magnitude
            offsetNorth *= scale
            offsetEast *= scale
        }
        let coordinate = anchor.offset(metersNorth: offsetNorth, metersEast: offsetEast)
        let accuracy = 5 + generator.double(in: 0...7)
        return SimulatedFix(
            coordinate: coordinate,
            speed: 0,
            course: -1,
            altitude: 0,
            horizontalAccuracy: accuracy,
            timestamp: now
        )
    }
}
