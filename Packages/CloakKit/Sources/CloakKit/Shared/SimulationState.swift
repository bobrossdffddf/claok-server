import Foundation

public enum SimulationMode: Equatable, Sendable, Codable {
    case idle
    case fixed(Coordinate)
    case route(name: String, mode: TravelMode)
    case replay(name: String)
    case joystick
    /// A real drive, reported no faster than the limit allows.
    case shield(ShieldSettings.Mode)

    /// SHIELD needs the real drive fed to it; nothing else does.
    public var isShield: Bool {
        if case .shield = self { return true }
        return false
    }

    public var isMoving: Bool {
        switch self {
        case .idle, .fixed: false
        case .route, .replay, .joystick, .shield: true
        }
    }

    public var title: String {
        switch self {
        case .idle: "Not simulating"
        case .fixed: "Holding position"
        case .route(let name, let travel): "\(travel.displayName) to \(name)"
        case .replay(let name): "Replaying \(name)"
        case .joystick: "Manual control"
        case .shield(let mode): "SHIELD, \(mode.name.lowercased())"
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
    /// The posted limit where the simulation is right now, when there is one.
    ///
    /// Only ever set while driving. A walking stretch has a pace, not a limit,
    /// and reporting the pace here would have every display in the app draw a
    /// 3 mph speed limit sign for the walk to the terminal door.
    public var speedLimit: Double?
    /// What the simulation is doing at this moment, which on a route with
    /// walking legs is not the same as the mode the whole route was asked for.
    public var travelMode: TravelMode?
    public var linkMessage: String?
    /// SHIELD only: how far the real phone is ahead of what is reported.
    public var shieldHoldingBack: Double?
    /// SHIELD only: the phone's real speed right now.
    public var shieldRealSpeed: Double?
    /// How steadily fixes have been going out over the last minute. One a
    /// second is the target; a long gap means iOS paused the app.
    public var fixesLastMinute: Int?
    public var longestGapLastMinute: Double?
    public var slowestPushLastMinute: Double?

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
        travelMode: TravelMode? = nil,
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
        self.travelMode = travelMode
        self.linkMessage = linkMessage
    }

    public static let stopped = SimulationSnapshot()
}
