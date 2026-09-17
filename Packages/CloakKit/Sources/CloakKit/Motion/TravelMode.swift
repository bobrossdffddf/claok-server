import Foundation

public enum TravelMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case drive
    case walk
    case run
    case cycle

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .drive: "Drive"
        case .walk: "Walk"
        case .run: "Run"
        case .cycle: "Cycle"
        }
    }

    public var symbolName: String {
        switch self {
        case .drive: "car.fill"
        case .walk: "figure.walk"
        case .run: "figure.run"
        case .cycle: "bicycle"
        }
    }

    /// True when the person is on their own feet.
    public var isOnFoot: Bool { self == .walk || self == .run }

    public var speedBand: ClosedRange<Double> {
        switch self {
        case .drive: Speed.mph(0)...Speed.mph(80)
        // An unhurried person with somewhere to be covers 1.1 to 1.5 m/s.
        // The band used to top out at 4 mph, which is 1.79 m/s: a march, and
        // with the engine's speed noise laid over it the reported figure went
        // past that again. Anything above about 1.5 m/s stops reading as
        // walking, which is exactly the complaint.
        case .walk: Speed.mph(2.5)...Speed.mph(3.3)
        case .run: Speed.mph(5)...Speed.mph(9)
        case .cycle: Speed.mph(8)...Speed.mph(18)
        }
    }

    /// The pace this mode settles at when nothing is holding it back.
    ///
    /// A drive has no single answer, because the posted limit of the road
    /// under the car decides it. Everything else does: a person does not walk
    /// faster because the street is wider.
    public var cruisingSpeed: Double {
        switch self {
        case .drive: speedBand.upperBound
        case .walk: Speed.mph(3.0)
        case .run: Speed.mph(7.0)
        case .cycle: Speed.mph(13.0)
        }
    }

    public var obeysTrafficControl: Bool { self == .drive }

    /// A person turns on the spot. Holding them to a car's cornering limit
    /// slowed a walk to a crawl every time the path bent round a building,
    /// which is not something feet do.
    public var cutsCorners: Bool { isOnFoot }

    /// How long this mode waits when something does stop it. A car at a red
    /// light is there for the whole phase; a person at the same crossing
    /// waits for a gap and goes.
    public var stopDwellRange: ClosedRange<Double> {
        switch self {
        case .drive: 8...42
        case .walk: 3...12
        case .run: 2...8
        case .cycle: 3...14
        }
    }

    public var pauseProbabilityPerMinute: Double {
        switch self {
        case .drive: 0
        case .walk: 0.18
        case .run: 0.06
        case .cycle: 0.08
        }
    }
}
