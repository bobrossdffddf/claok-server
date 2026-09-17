import Foundation
import ActivityKit

// ActivityKit is iOS only. Guarding it lets CloakKit build for macOS, which
// is what makes the tests runnable on a computer with no phone attached.
#if os(iOS)

/// What the Live Activity shows while a simulation is running.
///
/// It has a second job beyond being useful: a running Live Activity is a
/// standing reminder that the phone is reporting a location that is not the
/// real one, and it carries a stop button that works from the lock screen.
///
/// Everything here is deliberately small. ActivityKit caps a content state at
/// four kilobytes and re-encodes it on every push, so the state carries raw
/// numbers and the widget does the wording. Anything the widget can work out
/// for itself is a computed property rather than another field on the wire.
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
        /// When the route is expected to finish. Nil for a run with no end of
        /// its own, such as a fixed hold.
        public var endsAt: Date?
        /// SHIELD only: what the car is really doing and how far behind the
        /// reported position sits.
        public var realSpeedMph: Double?
        public var holdingBackMetres: Double?
        /// When this state was assembled.
        ///
        /// Optional on purpose: an activity that was already on screen when
        /// the app was replaced has an older state in ActivityKit's store, and
        /// a synthesised decoder only tolerates a missing key for an optional.
        /// Everything that reads it goes through `stamp`.
        public var updatedAt: Date?

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
            endsAt: Date? = nil,
            realSpeedMph: Double? = nil,
            holdingBackMetres: Double? = nil,
            updatedAt: Date? = Date.now
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
            self.realSpeedMph = realSpeedMph
            self.holdingBackMetres = holdingBackMetres
            self.updatedAt = updatedAt
        }

        /// Everything the Live Activity needs, taken straight off a snapshot.
        ///
        /// Having one place that does this keeps the app and the widget
        /// honest with each other: the widget's arrival estimate leans on
        /// `endsAt` and on `updatedAt` being the moment the numbers were true,
        /// and both are easy to forget at a hand-written call site.
        public init(snapshot: SimulationSnapshot, now: Date = Date.now) {
            let fix = snapshot.fix
            self.init(
                label: snapshot.mode.subject,
                activity: snapshot.mode.activityWord,
                symbol: snapshot.mode.symbol,
                latitude: fix?.coordinate.latitude ?? 0,
                longitude: fix?.coordinate.longitude ?? 0,
                speedMph: Speed.toMph(fix?.speed ?? 0),
                speedLimitMph: snapshot.speedLimit.map(Speed.toMph),
                progress: snapshot.progress,
                distanceRemaining: snapshot.distanceRemaining,
                isPaused: snapshot.isPaused,
                startedAt: snapshot.startedAt ?? now,
                endsAt: snapshot.remainingTime.flatMap { $0 > 0 ? now.addingTimeInterval($0) : nil },
                realSpeedMph: snapshot.shieldRealSpeed.map(Speed.toMph),
                holdingBackMetres: snapshot.shieldHoldingBack,
                updatedAt: now
            )
        }

        // MARK: Freshness

        /// How long a pushed state stays believable.
        ///
        /// Cloak pushes every couple of seconds while it runs. A minute and a
        /// half of silence means iOS has suspended the app, and the speed and
        /// the distance on screen have quietly become fiction.
        public static let freshFor: TimeInterval = 90

        /// The moment this state was put together. An older encoded state has
        /// no stamp, and falls back to the start of the run, which only makes
        /// every estimate below more cautious.
        public var stamp: Date { updatedAt ?? startedAt }

        /// Hand this to `ActivityContent(state:staleDate:)`. Past it, the
        /// system dims the activity and `context.isStale` turns true, which is
        /// what stops a dead run showing a live-looking speed forever.
        public var staleDate: Date { stamp.addingTimeInterval(Self.freshFor) }

        // MARK: Shape of the run

        /// A run with a finish line. A fixed hold and a SHIELD drive have
        /// none, and every part of the layout that needs one hides itself.
        public var isRoute: Bool { distanceRemaining != nil }

        /// Near enough that a countdown stops meaning anything.
        public var isArriving: Bool {
            guard let left = distanceRemaining else { return false }
            return left < 150
        }

        public var clampedProgress: Double { min(max(progress, 0), 1) }

        public var progressPercent: String {
            "\(Int((clampedProgress * 100).rounded()))%"
        }

        /// How long this route has been under way, frozen while paused.
        public var elapsed: TimeInterval { max(0, stamp.timeIntervalSince(startedAt)) }

        /// The whole route's length, worked back from what is left and how far
        /// along the run is. Nil until progress means something.
        public var routeLength: Double? {
            guard let left = distanceRemaining, clampedProgress > 0.02, clampedProgress < 0.999 else { return nil }
            return left / (1 - clampedProgress)
        }

        // MARK: Arrival

        /// When the route should finish.
        ///
        /// The engine's own figure wins when there is one. Failing that this
        /// averages the pace of the whole run so far, which rides out red
        /// lights instead of promising an arrival next Tuesday every time the
        /// car stops at one. Both are withheld until they would be worth
        /// believing, and a fixed hold never has one at all.
        public var arrivalDate: Date? {
            guard isRoute, !isPaused, !isArriving else { return nil }
            if let endsAt, endsAt > stamp { return endsAt }
            guard let left = distanceRemaining, left > 0, let length = routeLength else { return nil }
            guard elapsed > 25 else { return nil }
            let covered = length - left
            guard covered > 30 else { return nil }
            let pace = covered / elapsed
            guard pace > 0.4 else { return nil }
            return stamp.addingTimeInterval(left / pace)
        }

        /// "4:32 PM", written the way the reader's own clock writes it.
        public var arrivalText: String? {
            guard let arrival = arrivalDate else { return nil }
            return arrival.formatted(date: .omitted, time: .shortened)
        }

        // MARK: Words and numbers

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

        /// "38 mph in a 35", when the road's limit is known and worth saying.
        public var speedAgainstLimitText: String? {
            guard let limit = speedLimitMph, limit > 0, isMoving else { return nil }
            return String(format: "%.0f mph in a %.0f", speedMph, limit)
        }

        public var distanceText: String? {
            guard let meters = distanceRemaining, meters > 0 else { return nil }
            return Units.distance(meters) + " left"
        }

        /// What SHIELD is holding back, in one line, or nil when this is not
        /// a SHIELD run.
        public var shieldText: String? {
            guard let real = realSpeedMph, let back = holdingBackMetres else { return nil }
            return back > 20
                ? String(format: "Really %.0f mph, holding back %@", real, Units.distance(back))
                : String(format: "Really %.0f mph, caught up", real)
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
        case .shield: "SHIELD"
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
        case .shield(let mode): "Your drive, \(mode.detail.lowercased())"
        }
    }

    var symbol: String {
        switch self {
        case .idle: "location.slash"
        case .fixed: "mappin.circle.fill"
        case .route(_, let travel): travel == .drive ? "car.fill" : "figure.walk"
        case .replay: "arrow.clockwise.circle.fill"
        case .joystick: "gamecontroller.fill"
        case .shield: "shield.checkered"
        }
    }
}
#endif
