import Foundation

public enum SimulationMode: Equatable, Sendable, Codable {
    case idle
    case fixed(Coordinate)
    case route(name: String, mode: TravelMode)
    case replay(name: String)
    case joystick

    public var isMoving: Bool {
        switch self {
        case .idle, .fixed: false
        case .route, .replay, .joystick: true
        }
    }

    public var title: String {
        switch self {
        case .idle: "Not simulating"
        case .fixed: "Holding position"
        case .route(let name, let travel): "\(travel.displayName) to \(name)"
        case .replay(let name): "Replaying \(name)"
        case .joystick: "Manual control"
        }
    }
}

public struct SimulationSnapshot: Equatable, Sendable, Codable {
    public var isRunning: Bool
    public var isPaused: Bool
    public var mode: SimulationMode
    public var fix: SimulatedFix?
    public var progress: Double
    public var remainingTime: TimeInterval?
    public var distanceRemaining: Double?
    public var startedAt: Date?
    public var reconnectCount: Int
    public var stopsMade: Int
    public var nextStopDistance: Double?
    public var speedLimit: Double?
    public var linkMessage: String?

    public init(
        isRunning: Bool = false,
        isPaused: Bool = false,
        mode: SimulationMode = .idle,
        fix: SimulatedFix? = nil,
        progress: Double = 0,
        remainingTime: TimeInterval? = nil,
        distanceRemaining: Double? = nil,
        startedAt: Date? = nil,
        reconnectCount: Int = 0,
        stopsMade: Int = 0,
        nextStopDistance: Double? = nil,
        speedLimit: Double? = nil,
        linkMessage: String? = nil
    ) {
        self.isRunning = isRunning
        self.isPaused = isPaused
        self.mode = mode
        self.fix = fix
        self.progress = progress
        self.remainingTime = remainingTime
        self.distanceRemaining = distanceRemaining
        self.startedAt = startedAt
        self.reconnectCount = reconnectCount
        self.stopsMade = stopsMade
        self.nextStopDistance = nextStopDistance
        self.speedLimit = speedLimit
        self.linkMessage = linkMessage
    }

    public static let stopped = SimulationSnapshot()
}
