import Foundation

public struct DriverPersona: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var speedOffset: Double
    public var acceleration: Double
    public var braking: Double
    public var jerkLimit: Double
    public var lateralAcceleration: Double
    public var redLightProbability: Double
    public var signalDwellRange: ClosedRange<Double>
    public var stopSignDwellRange: ClosedRange<Double>
    public var speedNoise: Double

    public init(
        id: String,
        name: String,
        speedOffset: Double,
        acceleration: Double,
        braking: Double,
        jerkLimit: Double,
        lateralAcceleration: Double,
        redLightProbability: Double,
        signalDwellRange: ClosedRange<Double>,
        stopSignDwellRange: ClosedRange<Double>,
        speedNoise: Double
    ) {
        self.id = id
        self.name = name
        self.speedOffset = speedOffset
        self.acceleration = acceleration
        self.braking = braking
        self.jerkLimit = jerkLimit
        self.lateralAcceleration = lateralAcceleration
        self.redLightProbability = redLightProbability
        self.signalDwellRange = signalDwellRange
        self.stopSignDwellRange = stopSignDwellRange
        self.speedNoise = speedNoise
    }
}

public extension DriverPersona {
    static let cautious = DriverPersona(
        id: "cautious",
        name: "Cautious",
        speedOffset: Speed.mph(-2),
        acceleration: 1.5,
        braking: 2.5,
        jerkLimit: 1.2,
        lateralAcceleration: 2.4,
        redLightProbability: 0.55,
        signalDwellRange: 10...45,
        stopSignDwellRange: 2.2...3.5,
        speedNoise: 0.25
    )

    static let normal = DriverPersona(
        id: "normal",
        name: "Normal",
        speedOffset: Speed.mph(3),
        acceleration: 2.0,
        braking: 3.0,
        jerkLimit: 1.8,
        lateralAcceleration: 3.0,
        redLightProbability: 0.55,
        signalDwellRange: 8...42,
        stopSignDwellRange: 1.8...3.0,
        speedNoise: 0.35
    )

    static let assertive = DriverPersona(
        id: "assertive",
        name: "Assertive",
        speedOffset: Speed.mph(8),
        acceleration: 2.5,
        braking: 3.5,
        jerkLimit: 2.6,
        lateralAcceleration: 3.6,
        redLightProbability: 0.55,
        signalDwellRange: 8...38,
        stopSignDwellRange: 1.5...2.4,
        speedNoise: 0.45
    )

    static let all: [DriverPersona] = [.cautious, .normal, .assertive]

    /// SHIELD: a driver who sits at the posted limit plus a fixed allowance
    /// and never wanders above it. The noise is kept low so the reported
    /// speed does not poke over the cap.
    static func shield(allowanceMph: Double) -> DriverPersona {
        DriverPersona(
            id: "shield-\(Int(allowanceMph))",
            name: "SHIELD",
            speedOffset: Speed.mph(allowanceMph) - Speed.mph(0.5),
            acceleration: 2.0,
            braking: 3.0,
            jerkLimit: 1.8,
            lateralAcceleration: 3.0,
            redLightProbability: 0.55,
            signalDwellRange: 8...42,
            stopSignDwellRange: 1.8...3.0,
            speedNoise: 0.12
        )
    }

    static func named(_ id: String) -> DriverPersona {
        if let known = all.first(where: { $0.id == id }) { return known }
        if id.hasPrefix("shield-"), let allowance = Double(id.dropFirst(7)) {
            return shield(allowanceMph: allowance)
        }
        return .normal
    }
}

public enum Speed {
    public static func mph(_ value: Double) -> Double { value * 0.44704 }
    public static func kph(_ value: Double) -> Double { value / 3.6 }
    public static func toMph(_ metersPerSecond: Double) -> Double { metersPerSecond / 0.44704 }
    public static func toKph(_ metersPerSecond: Double) -> Double { metersPerSecond * 3.6 }
}
