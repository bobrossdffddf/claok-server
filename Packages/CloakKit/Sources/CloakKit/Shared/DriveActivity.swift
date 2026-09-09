import Foundation
import ActivityKit

/// What the Live Activity shows while a simulation is running.
///
/// It has a second job beyond being useful: a running Live Activity is a
/// standing reminder that the phone is reporting a location that is not the
/// real one, and it carries a stop button that works from the lock screen.
public struct DriveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Where the phone says it is, in words. A place name if there is one.
        public var label: String
        /// What Cloak is doing: driving, walking, holding still.
        public var activity: String
        /// The SF Symbol for that activity.
        public var symbol: String
        public var latitude: Double
        public var longitude: Double
        public var speedMph: Double
        public var speedLimitMph: Double?
        public var progress: Double
        public var distanceRemaining: Double?
        public var isPaused: Bool
        /// When this run started, so the widget can run its own clock without
        /// Cloak having to push an update every second.
        public var startedAt: Date
        /// Zero means the run has no end time of its own.
        public var endsAt: Date?

        public init(
            label: String,
            activity: String,
            symbol: String,
            latitude: Double,
            longitude: Double,
            speedMph: Double,
            speedLimitMph: Double? = nil,
            progress: Double,
            distanceRemaining: Double? = nil,
            isPaused: Bool,
            startedAt: Date,
            endsAt: Date? = nil
        ) {
            self.label = label
            self.activity = activity
            self.symbol = symbol
            self.latitude = latitude
            self.longitude = longitude
            self.speedMph = speedMph
            self.speedLimitMph = speedLimitMph
            self.progress = progress
            self.distanceRemaining = distanceRemaining
            self.isPaused = isPaused
            self.startedAt = startedAt
            self.endsAt = endsAt
        }

        public var coordinateText: String {
            String(format: "%.4f, %.4f", latitude, longitude)
        }

        public var isMoving: Bool { speedMph >= 0.5 }

        public var speedValue: String {
            isMoving ? String(format: "%.0f", speedMph) : "0"
        }

        public var speedText: String {
            isMoving ? String(format: "%.0f mph", speedMph) : "Stopped"
        }

        public var distanceText: String? {
            guard let meters = distanceRemaining, meters > 0 else { return nil }
            if meters < 950 { return "\(Int(meters.rounded())) m left" }
            return String(format: "%.1f km left", meters / 1000)
        }

        public var isOverLimit: Bool {
            guard let limit = speedLimitMph, limit > 0 else { return false }
            return speedMph > limit + 3
        }
    }

    public var startedAt: Date

    public init(startedAt: Date = .now) {
        self.startedAt = startedAt
    }
}

public extension SimulationMode {
    /// A short word for what is happening, for small spaces.
    var activityWord: String {
        switch self {
        case .idle: "Idle"
        case .fixed: "Holding"
        case .route(_, let travel): travel.displayName
        case .replay: "Replaying"
        case .joystick: "Manual"
        }
    }

    /// The place or route this run is about, without the verb.
    var subject: String {
        switch self {
        case .idle: "Nothing"
        case .fixed: "This spot"
        case .route(let name, _): name
        case .replay(let name): name
        case .joystick: "Wherever you steer"
        }
    }

    var symbol: String {
        switch self {
        case .idle: "location.slash"
        case .fixed: "mappin.circle.fill"
        case .route(_, let travel): travel == .drive ? "car.fill" : "figure.walk"
        case .replay: "arrow.clockwise.circle.fill"
        case .joystick: "gamecontroller.fill"
        }
    }
}
