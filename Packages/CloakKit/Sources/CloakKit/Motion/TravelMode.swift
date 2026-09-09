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

    public var speedBand: ClosedRange<Double> {
        switch self {
        case .drive: Speed.mph(0)...Speed.mph(80)
        case .walk: Speed.mph(2)...Speed.mph(4)
        case .run: Speed.mph(5)...Speed.mph(9)
        case .cycle: Speed.mph(8)...Speed.mph(18)
        }
    }

    public var obeysTrafficControl: Bool { self == .drive }

    public var pauseProbabilityPerMinute: Double {
        switch self {
        case .drive: 0
        case .walk: 0.18
        case .run: 0.06
        case .cycle: 0.08
        }
    }
}
