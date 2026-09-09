import Foundation

/// Grades a planned or recorded trace against the things that actually give a
/// simulated location away.
///
/// Every product in this category sells realism as an adjective. This turns it
/// into a number with reasons attached, which is both more honest and more
/// useful: it says which part of a plan is weak and what to change.
///
/// The checks are the ones a reviewer looking at a location history would
/// actually run, in roughly the order they would notice them.
public struct Believability: Sendable, Equatable {
    public struct Tell: Sendable, Equatable, Identifiable {
        public enum Severity: Int, Sendable, Comparable {
            case note = 0
            case weak = 1
            case bad = 2

            public static func < (lhs: Severity, rhs: Severity) -> Bool {
                lhs.rawValue < rhs.rawValue
            }
        }

        public var id: String { title }
        public var title: String
        public var detail: String
        public var fix: String
        public var severity: Severity
        /// How many points this costs.
        public var cost: Int

        public init(title: String, detail: String, fix: String, severity: Severity, cost: Int) {
            self.title = title
            self.detail = detail
            self.fix = fix
            self.severity = severity
            self.cost = cost
        }
    }

    /// Nought to a hundred. Not a probability of anything, just a tally.
    public var score: Int
    public var tells: [Tell]

    public var grade: String {
        switch score {
        case 90...: "Convincing"
        case 75..<90: "Solid"
        case 55..<75: "Passable"
        case 35..<55: "Weak"
        default: "Obvious"
        }
    }

    public var isClean: Bool { tells.isEmpty }

    // MARK: - Grading a plan before it runs

    /// What can be judged before anything has moved: the jump from where the
    /// phone really is, the shape of the route, and whether the timing is
    /// physically possible.
    public static func grade(
        plan points: [Coordinate],
        postedLimits: [Double],
        controls: [TrafficControl],
        mode: TravelMode,
        realPosition: Coordinate?,
        lastRunSignature: String? = nil,
        signature: String? = nil
    ) -> Believability {
        var tells: [Tell] = []

        guard points.count >= 2 else {
            return Believability(score: 100, tells: [])
        }

        let polyline = Polyline(points: points)
        let distance = polyline.length

        // 1. The seam. A phone that was in one city a second ago and another
        //    one now is the single loudest tell there is.
        if let real = realPosition, let start = points.first {
            let jump = real.distance(to: start)
            if jump > 2000 {
                let severity: Tell.Severity = jump > 40_000 ? .bad : .weak
                tells.append(Tell(
                    title: "It starts somewhere you are not",
                    detail: "The first point is \(readable(jump)) from where this phone actually is. Anything watching sees you cross that instantly.",
                    fix: "Turn on Bridge the gap in Settings, and Cloak walks the position across at a believable speed before the trip begins.",
                    severity: severity,
                    cost: severity == .bad ? 30 : 15
                ))
            }
        }

        // 2. Stops. Twenty minutes of city driving with nothing to stop for
        //    does not happen.
        if mode == .drive, distance > 3000, controls.isEmpty {
            tells.append(Tell(
                title: "Nothing to stop for",
                detail: "This route has no junctions, lights or crossings on it, so the drive runs \(readable(distance)) without ever slowing to a halt.",
                fix: "Road data did not load. Rebuild the route with a connection, or drive somewhere the map knows better.",
                severity: .weak,
                cost: 12
            ))
        }

        // 3. Speed limits. Without them everything moves at one made-up speed.
        if postedLimits.isEmpty || Set(postedLimits).count <= 1 {
            tells.append(Tell(
                title: "One speed the whole way",
                detail: "No posted limits were found, so every stretch is driven at the same pace whether it is a lane or a motorway.",
                fix: "Rebuild the route with a connection so Cloak can read the speed limits along it.",
                severity: .weak,
                cost: 14
            ))
        }

        // 4. Straightness. A route drawn between two far-apart points with no
        //    corners is a line, not a journey.
        if let first = points.first, let last = points.last {
            let asCrow = first.distance(to: last)
            if asCrow > 1500, distance < asCrow * 1.03 {
                tells.append(Tell(
                    title: "It runs dead straight",
                    detail: "The path is within three percent of a straight line over \(readable(asCrow)), which no road does.",
                    fix: "Add a stop or two so the route follows streets instead of cutting across them.",
                    severity: .bad,
                    cost: 25
                ))
            }
        }

        // 5. Repetition. The easiest thing to catch over weeks is a commute
        //    that is identical to the metre every single day.
        if let signature, let previous = lastRunSignature, signature == previous {
            tells.append(Tell(
                title: "Identical to last time",
                detail: "This is the same route, at the same speeds, in the same order as the last run. Repeated exactly, that pattern stands out more than the trip itself.",
                fix: "Turn on Vary each run so departure time and pace shift a little every time.",
                severity: .weak,
                cost: 10
            ))
        }

        // 6. Walking somewhere nobody walks.
        if mode == .walk, distance > 15_000 {
            tells.append(Tell(
                title: "That is a long walk",
                detail: "\(readable(distance)) on foot is about \(Int(distance / 1.35 / 3600)) hours of continuous walking.",
                fix: "Switch to driving, or split it up.",
                severity: .note,
                cost: 6
            ))
        }

        return Believability(score: tally(tells), tells: tells.sorted { $0.severity > $1.severity })
    }

    // MARK: - Grading a trace after the fact

    /// What can be judged once there are fixes: the physics of the movement
    /// itself, which is where most simulators come apart.
    public static func grade(trace fixes: [SimulatedFix]) -> Believability {
        var tells: [Tell] = []
        guard fixes.count > 4 else { return Believability(score: 100, tells: []) }

        var speeds: [Double] = []
        var accelerations: [Double] = []
        var previous: SimulatedFix?

        for fix in fixes {
            defer { previous = fix }
            guard let last = previous else { continue }
            let seconds = fix.timestamp.timeIntervalSince(last.timestamp)
            guard seconds > 0.05 else { continue }
            let metres = last.coordinate.distance(to: fix.coordinate)
            let speed = metres / seconds
            if let lastSpeed = speeds.last {
                accelerations.append((speed - lastSpeed) / seconds)
            }
            speeds.append(speed)
        }

        guard !speeds.isEmpty else { return Believability(score: 100, tells: []) }

        // Impossible speed anywhere in the trace.
        if let top = speeds.max(), top > 75 {
            tells.append(Tell(
                title: "Impossible speed",
                detail: "One stretch moves at \(Int(top * 2.237)) mph, which is faster than the road allows and faster than a phone should ever report.",
                fix: "Slow the playback rate down, or remove the stop that causes the jump.",
                severity: .bad,
                cost: 30
            ))
        }

        // Instant acceleration. Real vehicles are limited to a few metres per
        // second squared; a step from nought to speed between two fixes is not
        // a driving artefact, it is a teleport.
        if let hardest = accelerations.map(abs).max(), hardest > 6 {
            tells.append(Tell(
                title: "It changes speed instantly",
                detail: "Speed jumps by \(String(format: "%.1f", hardest)) metres per second per second between two fixes. A car manages about two and a half.",
                fix: "Lower the playback rate, which gives the engine room to accelerate properly.",
                severity: .weak,
                cost: 14
            ))
        }

        // A constant speed held for minutes is the signature of interpolation
        // between two points rather than of anybody driving.
        let moving = speeds.filter { $0 > 1 }
        if moving.count > 30 {
            let mean = moving.reduce(0, +) / Double(moving.count)
            let variance = moving.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(moving.count)
            if mean > 2, sqrt(variance) / mean < 0.04 {
                tells.append(Tell(
                    title: "The speed never varies",
                    detail: "The whole trace holds within four percent of one speed. Nothing driven by a person does that.",
                    fix: "Use a driver persona other than the flattest one, and let the route keep its speed limits.",
                    severity: .bad,
                    cost: 22
                ))
            }
        }

        // Accuracy that is the same every fix, or implausibly good.
        let accuracies = fixes.map(\.horizontalAccuracy).filter { $0 > 0 }
        if accuracies.count > 10 {
            let unique = Set(accuracies.map { ($0 * 10).rounded() })
            if unique.count <= 2 {
                tells.append(Tell(
                    title: "Accuracy never moves",
                    detail: "Every fix reports the same horizontal accuracy. Real GPS accuracy wanders with the sky and the buildings.",
                    fix: "Nothing to do by hand. Cloak varies this itself when the realism model is on.",
                    severity: .weak,
                    cost: 12
                ))
            }
        }

        // Course that disagrees with where the position actually went.
        var disagreements = 0
        var checks = 0
        previous = nil
        for fix in fixes {
            defer { previous = fix }
            guard let last = previous, fix.course >= 0, fix.speed > 2 else { continue }
            let bearing = last.coordinate.bearing(to: fix.coordinate)
            var delta = abs(bearing - fix.course).truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta = 360 - delta }
            checks += 1
            if delta > 40 { disagreements += 1 }
        }
        if checks > 20, Double(disagreements) / Double(checks) > 0.15 {
            tells.append(Tell(
                title: "Heading and movement disagree",
                detail: "The reported heading points somewhere other than the direction of travel on \(disagreements) of \(checks) moving fixes.",
                fix: "This is a bug rather than a setting. Worth reporting.",
                severity: .weak,
                cost: 12
            ))
        }

        // A trace with no pauses at all over a long stretch.
        if speeds.count > 200, moving.count == speeds.count {
            tells.append(Tell(
                title: "It never stops",
                detail: "Not one fix in the whole trace is stationary.",
                fix: "Routes built with road data pick up junctions and crossings on their own. This one had none.",
                severity: .note,
                cost: 8
            ))
        }

        return Believability(score: tally(tells), tells: tells.sorted { $0.severity > $1.severity })
    }

    private static func tally(_ tells: [Tell]) -> Int {
        max(0, 100 - tells.reduce(0) { $0 + $1.cost })
    }

    private static func readable(_ metres: Double) -> String {
        if metres < 950 { return "\(Int(metres.rounded())) m" }
        return String(format: "%.1f km", metres / 1000)
    }
}
