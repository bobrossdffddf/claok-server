import Foundation

/// Runs a planned drive through the very engine that will play it, offline and
/// in an instant, and grades the trace it would produce before a single fix
/// goes out.
///
/// Every other product in this category makes you run the drive live and hope
/// nothing looked wrong. Cloak already emits a physically modelled trace and
/// already knows how to grade one. Rehearsal joins the two: step the motion
/// engine over the whole route at the same one-a-second cadence a real run
/// uses, collect the fixes it hands out, and put them through the trace grader.
/// The result is the same drive, judged, with the weakest second found, before
/// it has happened.
///
/// This is not a second physics model. It is the real one, played fast with no
/// device attached, so what it grades is exactly what would be sent.
public struct Rehearsal: Sendable, Equatable {
    /// The believability of the trace this plan would produce.
    public var trace: Believability
    /// The single least convincing moment, if there is one worth naming.
    public var weakest: Moment?
    /// How long the drive would take, start to arrival, in seconds.
    public var duration: TimeInterval
    /// How far the drive covers, in metres.
    public var distance: Double
    /// The top speed reached.
    public var topSpeed: Double
    /// How many times it comes to a stop.
    public var stops: Int
    /// Every fix, for drawing the trace. Sampled, not the full second-by-second
    /// run, so the array stays a sensible size for a long drive.
    public var samples: [SimulatedFix]

    public struct Moment: Sendable, Equatable {
        /// Seconds from the start of the drive.
        public var at: TimeInterval
        /// How far along, in metres.
        public var distance: Double
        /// Where on the map.
        public var coordinate: Coordinate
        /// What is weak about it, in a few words.
        public var reason: String
        /// The speed at that instant.
        public var speed: Double

        public init(at: TimeInterval, distance: Double, coordinate: Coordinate, reason: String, speed: Double) {
            self.at = at
            self.distance = distance
            self.coordinate = coordinate
            self.reason = reason
            self.speed = speed
        }
    }

    public var grade: String { trace.grade }
    public var score: Int { trace.score }

    /// The wording for the top of a rehearsal card.
    public var headline: String {
        switch trace.score {
        case 90...: "This drive looks real"
        case 75..<90: "This drive holds up"
        case 55..<75: "This drive has soft spots"
        default: "This drive would stand out"
        }
    }

    // MARK: - Running it

    /// The most fixes a rehearsal keeps for drawing. A cross-country drive is
    /// tens of thousands of seconds; nobody needs every one to see the shape.
    public static let maxSamples = 400
    /// The step the offline run uses. One second, the same as a live run.
    public static let cadence: TimeInterval = 1
    /// A rehearsal will not step more than this many times, so a pathological
    /// route cannot spin forever. At one second a step this is many hours.
    public static let stepCeiling = 60 * 60 * 12

    public static func run(
        profile: SpeedProfile,
        persona: DriverPersona,
        mode: TravelMode,
        seed: UInt64
    ) -> Rehearsal {
        guard profile.polyline.length > 0, profile.ceiling.count > 1 else {
            return Rehearsal(trace: Believability(score: 100, tells: []), weakest: nil, duration: 0, distance: 0, topSpeed: 0, stops: 0, samples: [])
        }

        var engine = MotionEngine(profile: profile, persona: persona, mode: mode, seed: seed)
        var fixes: [SimulatedFix] = []
        var topSpeed = 0.0
        // A fixed clock so the timestamps are exactly one second apart, which
        // is what the trace grader expects to see from a clean run.
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        var steps = 0

        while !engine.state.finished, steps < stepCeiling {
            let fix = engine.step(deltaTime: cadence, now: clock)
            fixes.append(fix)
            topSpeed = max(topSpeed, fix.speed)
            clock = clock.addingTimeInterval(cadence)
            steps += 1
        }

        let trace = Believability.grade(trace: fixes)
        let weakest = findWeakest(in: fixes, profile: profile)
        let stops = engine.state.stopsMade

        return Rehearsal(
            trace: trace,
            weakest: weakest,
            duration: Double(fixes.count) * cadence,
            distance: profile.polyline.length,
            topSpeed: topSpeed,
            stops: stops,
            samples: sample(fixes)
        )
    }

    /// The least convincing single second of the run.
    ///
    /// The trace grade already names what is wrong across the whole drive.
    /// This finds where the worst of it happens, by scoring each second on the
    /// two things a reviewer's eye actually catches frame to frame: a speed
    /// that jumps between neighbouring fixes, and a heading that disagrees with
    /// the direction the position is moving.
    static func findWeakest(in fixes: [SimulatedFix], profile: SpeedProfile) -> Moment? {
        guard fixes.count > 3 else { return nil }

        var worstScore = 0.0
        var worst: Moment?

        for index in 1..<(fixes.count - 1) {
            let previous = fixes[index - 1]
            let fix = fixes[index]
            let next = fixes[index + 1]

            var penalty = 0.0
            var reason = ""

            // A jump in speed between two one-second fixes. Real acceleration
            // is bounded; a big step is a physics break.
            let accel = abs(fix.speed - previous.speed) / cadence
            if accel > 4.5 {
                penalty += accel
                reason = fix.speed > previous.speed ? "Speeds up hard here" : "Slows down hard here"
            }

            // Course that disagrees with where the position actually went.
            if fix.speed > 3, previous.coordinate.distance(to: next.coordinate) > 2 {
                let travelled = previous.coordinate.bearing(to: next.coordinate)
                let stated = fix.course
                if stated >= 0 {
                    let diff = angleDifference(travelled, stated)
                    if diff > 35 {
                        let weight = diff / 10
                        if weight > penalty {
                            penalty = weight
                            reason = "Heading and movement disagree"
                        }
                    }
                }
            }

            if penalty > worstScore {
                worstScore = penalty
                worst = Moment(
                    at: Double(index) * cadence,
                    distance: 0,
                    coordinate: fix.coordinate,
                    reason: reason,
                    speed: fix.speed
                )
            }
        }

        return worst
    }

    static func angleDifference(_ a: Double, _ b: Double) -> Double {
        var diff = abs(a - b).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff = 360 - diff }
        return diff
    }

    static func sample(_ fixes: [SimulatedFix]) -> [SimulatedFix] {
        guard fixes.count > maxSamples else { return fixes }
        let stride = Double(fixes.count) / Double(maxSamples)
        var result: [SimulatedFix] = []
        var cursor = 0.0
        while Int(cursor) < fixes.count {
            result.append(fixes[Int(cursor)])
            cursor += stride
        }
        if let last = fixes.last, result.last != last { result.append(last) }
        return result
    }
}
