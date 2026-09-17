import Foundation

/// What a position that is not on a route does: a phone resting somewhere, or
/// a person moving about inside one building.
///
/// Every other spoofer that models a resting position at all does it as a
/// bounded uniform wander, which has the wrong statistics: real GPS error is
/// strongly autocorrelated. It drifts, holds a bias for a minute or so, then
/// reverts, with the occasional larger multipath excursion when a reflection
/// briefly wins. A reviewer looking at a night of "asleep at home" fixes can
/// tell white noise from that.
///
/// So the error is an Ornstein-Uhlenbeck process (mean-reverting Gaussian, the
/// standard model for exactly this) plus rare multipath excursions that arrive
/// and fade over seconds rather than in one step. This is the one part of
/// realism that is genuinely visible to other apps, because unlike speed,
/// course and accuracy — all of which iOS discards for a simulated fix — the
/// sequence of positions is the channel every app actually reads.
///
/// Resting is not the only way to stand still, though. A hold at an airport
/// covers tens of metres of concourse, and no receiver error reaches that far:
/// ground like that is covered on foot. Asking the error model to span it made
/// the phone appear to teleport around the terminal, so a radius that large
/// switches to walking instead — short walks at walking pace, long sits in
/// between — with the receiver's own error laid over the top.
public struct IdleJitter: Sendable {
    public enum Behaviour: String, Sendable, Equatable {
        /// A phone that is not going anywhere. Only the receiver moves it.
        case resting
        /// A person on foot inside the area: the gate, the shops, back again.
        case wandering
    }

    /// Past this, the radius is describing ground rather than error. A resting
    /// consumer receiver does not put its fix fifteen metres out and hold it
    /// there; a person walking to the next gate does.
    public static let walkingBeyond: Double = 15
    /// The error to expect while walking about indoors. Worse than open sky,
    /// and nothing to do with how big the building is.
    public static let receiverSpread: Double = 6
    /// Walking pace in a terminal: unhurried, with a bag, around other people.
    public static let walkingPace: ClosedRange<Double> = 1.1...1.5
    /// How long a person stays put between those walks. Most of a wait is sitting.
    public static let pauseRange: ClosedRange<Double> = 60...420
    /// Nobody walks across the room and calls it a trip.
    public static let shortestLeg: Double = 10
    /// Chance per second of a multipath excursion starting. About one every
    /// three minutes, which is what a receiver in an awkward spot does.
    public static let multipathRate: Double = 0.006

    public var anchor: Coordinate
    public var radius: Double
    public let behaviour: Behaviour

    /// Reversion rate. 1/theta is the time constant, so 0.015 per second is a
    /// bias that lasts a bit over a minute. The slower it reverts the smaller
    /// each second's step is for the same spread, and it is the size of the
    /// step, not the spread, that reads as the position jittering.
    private let theta: Double
    private let sigma: Double
    /// The spread of the receiver error alone. The same as `radius` when
    /// resting; the receiver's own figure when the radius is ground to cover.
    private let errorRadius: Double

    private var north: Double = 0
    private var east: Double = 0
    private var multipathNorth: Double = 0
    private var multipathEast: Double = 0
    private var multipathTargetNorth: Double = 0
    private var multipathTargetEast: Double = 0

    private var walkNorth: Double = 0
    private var walkEast: Double = 0
    private var targetNorth: Double = 0
    private var targetEast: Double = 0
    private var pauseRemaining: TimeInterval = 0
    private var pace: Double = 0

    private var lastTick: Date?
    private var generator: SeededGenerator

    public init(
        anchor: Coordinate,
        radius: Double = 4,
        seed: UInt64 = 0xC10A4,
        behaviour: Behaviour? = nil
    ) {
        self.anchor = anchor
        self.radius = max(1.5, radius)
        self.behaviour = behaviour ?? (self.radius > Self.walkingBeyond ? .wandering : .resting)
        self.errorRadius = self.behaviour == .wandering
            ? min(self.radius, Self.receiverSpread)
            : self.radius
        self.theta = 0.015
        // Stationary standard deviation of an OU process is sigma/sqrt(2 theta).
        // Aim the 1-sigma spread at half the radius so it mostly sits inside it.
        self.sigma = (self.errorRadius / 2) * (2 * theta).squareRoot()
        self.generator = SeededGenerator(seed: seed ^ 0x9E37_79B9_7F4A_7C15)
        // A dwell begins with the person already there and already sitting.
        if self.behaviour == .wandering {
            self.pauseRemaining = self.generator.double(in: Self.pauseRange)
        }
    }

    public mutating func next(now: Date = .now) -> SimulatedFix {
        let dt: Double
        if let lastTick {
            dt = min(5, max(0.2, now.timeIntervalSince(lastTick)))
        } else {
            dt = 1
        }
        lastTick = now

        stepReceiverError(dt)
        let walk = behaviour == .wandering ? stepWalk(dt) : (speed: 0.0, course: -1.0)

        let coordinate = anchor.offset(
            metersNorth: walkNorth + north + multipathNorth,
            metersEast: walkEast + east + multipathEast
        )

        // Reported accuracy tracks the multipath state the way a real receiver
        // widens its estimate when the fix gets noisy. Not seen by other apps
        // on a simulated fix, but honest for Cloak's own display.
        let excursion = (multipathNorth * multipathNorth + multipathEast * multipathEast).squareRoot()
        let accuracy = 4 + excursion * 0.6 + generator.double(in: 0...2)

        return SimulatedFix(
            coordinate: coordinate,
            speed: walk.speed,
            course: walk.course,
            altitude: 0,
            horizontalAccuracy: accuracy,
            timestamp: now
        )
    }

    // MARK: - The receiver

    private mutating func stepReceiverError(_ dt: Double) {
        let sqrtDt = dt.squareRoot()
        north += -theta * north * dt + sigma * sqrtDt * generator.gaussian(mean: 0, deviation: 1)
        east += -theta * east * dt + sigma * sqrtDt * generator.gaussian(mean: 0, deviation: 1)

        // Multipath used to land whole in a single step: up to twice the radius
        // in one tick, which on a map is the position hopping, and is what the
        // "it jibbers when I am standing still" report is about. A receiver
        // walks into a bad fix over a second or two and back out over several,
        // so the excursion is a target the offset moves towards while the
        // target itself fades.
        if generator.double(in: 0...1) < Self.multipathRate * dt {
            let magnitude = errorRadius * generator.double(in: 0.5...1.2)
            let bearing = generator.double(in: 0...(2 * .pi))
            multipathTargetNorth = cos(bearing) * magnitude
            multipathTargetEast = sin(bearing) * magnitude
        }
        let fade = exp(-dt / 6)
        multipathTargetNorth *= fade
        multipathTargetEast *= fade
        let rise = 1 - exp(-dt / 4)
        multipathNorth += (multipathTargetNorth - multipathNorth) * rise
        multipathEast += (multipathTargetEast - multipathEast) * rise

        // A soft cap: real error does breach the nominal radius on multipath,
        // so this only reins in the sustained OU part, not the transient.
        let baseMagnitude = (north * north + east * east).squareRoot()
        if baseMagnitude > errorRadius * 1.4 {
            let scale = (errorRadius * 1.4) / baseMagnitude
            north *= scale
            east *= scale
        }
    }

    // MARK: - The person

    private mutating func stepWalk(_ dt: Double) -> (speed: Double, course: Double) {
        if pauseRemaining > 0 {
            pauseRemaining -= dt
            return (0, -1)
        }
        if pace <= 0 { chooseLeg() }

        let deltaNorth = targetNorth - walkNorth
        let deltaEast = targetEast - walkEast
        let remaining = (deltaNorth * deltaNorth + deltaEast * deltaEast).squareRoot()
        guard remaining > 0.01 else {
            arrive()
            return (0, -1)
        }

        let course = (atan2(deltaEast, deltaNorth) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        let step = min(pace * dt, remaining)
        walkNorth += deltaNorth / remaining * step
        walkEast += deltaEast / remaining * step

        let speed = pace
        if remaining - step <= 0.5 { arrive() }
        return (speed, course)
    }

    private mutating func arrive() {
        pauseRemaining = generator.double(in: Self.pauseRange)
        pace = 0
    }

    /// Somewhere else inside the area, far enough away to be worth the walk.
    private mutating func chooseLeg() {
        pace = generator.double(in: Self.walkingPace)
        for _ in 0..<8 {
            // Uniform over the area rather than over the radius, so the person
            // is not always out at the edge of it.
            let distance = radius * generator.double(in: 0...1).squareRoot()
            let bearing = generator.double(in: 0...(2 * .pi))
            let candidateNorth = cos(bearing) * distance
            let candidateEast = sin(bearing) * distance
            let legNorth = candidateNorth - walkNorth
            let legEast = candidateEast - walkEast
            if (legNorth * legNorth + legEast * legEast).squareRoot() >= Self.shortestLeg {
                targetNorth = candidateNorth
                targetEast = candidateEast
                return
            }
        }
        // Nothing far enough came up: go back to where the hold is centred.
        targetNorth = 0
        targetEast = 0
    }
}
