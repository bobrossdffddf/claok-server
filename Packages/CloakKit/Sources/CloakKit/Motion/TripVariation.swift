import Foundation

/// Replays a recorded trip, but never the same way twice.
///
/// A recording of your own driving is the most believable thing a simulator
/// can possibly emit, because it is real: the speeds are yours, the stops are
/// where you actually stopped, the pauses are as long as they actually were.
/// The catch is that replaying it verbatim turns the best asset into the worst
/// one, since a trace repeated to the metre and the second is easier to spot
/// than any single fake journey.
///
/// So this perturbs it. Departure slides, the pace scales a little, the path
/// drifts sideways by a few metres along a smooth random walk rather than
/// jittering point by point, and the stops get slightly different lengths.
/// Everything is drawn from a seed, so a given variation can be reproduced.
public struct TripVariation: Sendable {
    /// How much to shift the departure, in minutes either way.
    public var departureSlack: Double
    /// How much faster or slower the whole trip may run.
    public var paceSlack: Double
    /// How far the path may wander from the recorded line, in metres.
    public var lateralDrift: Double
    /// How much longer or shorter each pause may be.
    public var dwellSlack: Double

    public init(
        departureSlack: Double = 6,
        paceSlack: Double = 0.08,
        lateralDrift: Double = 7,
        dwellSlack: Double = 0.25
    ) {
        self.departureSlack = departureSlack
        self.paceSlack = paceSlack
        self.lateralDrift = lateralDrift
        self.dwellSlack = dwellSlack
    }

    public static let off = TripVariation(
        departureSlack: 0, paceSlack: 0, lateralDrift: 0, dwellSlack: 0)

    public func apply(to fixes: [SimulatedFix], seed: UInt64) -> [SimulatedFix] {
        guard fixes.count > 1 else { return fixes }
        var generator = SeededGenerator(seed: seed)

        let pace = 1.0 + generator.double(in: -paceSlack...paceSlack)
        let departure = generator.double(in: -departureSlack...departureSlack) * 60

        // The sideways drift is a random walk that is then pulled back towards
        // the line, so the path leans away and returns rather than shivering.
        var offsetNorth = 0.0
        var offsetEast = 0.0
        let pull = 0.04

        var output: [SimulatedFix] = []
        output.reserveCapacity(fixes.count)

        let start = fixes[0].timestamp
        var carried: TimeInterval = departure
        var previous: SimulatedFix?

        for fix in fixes {
            defer { previous = fix }

            var moved = fix
            let elapsed = fix.timestamp.timeIntervalSince(start)

            // Pauses stretch or shrink on their own, on top of the overall pace.
            if let last = previous {
                let gap = fix.timestamp.timeIntervalSince(last.timestamp)
                let metres = last.coordinate.distance(to: fix.coordinate)
                let stationary = gap > 2 && metres < 2
                if stationary, dwellSlack > 0 {
                    carried += gap * generator.double(in: -dwellSlack...dwellSlack)
                }
            }

            moved.timestamp = start.addingTimeInterval(elapsed * pace + carried)

            if lateralDrift > 0 {
                offsetNorth += generator.gaussian(mean: 0, deviation: 0.5) - offsetNorth * pull
                offsetEast += generator.gaussian(mean: 0, deviation: 0.5) - offsetEast * pull
                let magnitude = (offsetNorth * offsetNorth + offsetEast * offsetEast).squareRoot()
                if magnitude > lateralDrift {
                    let scale = lateralDrift / magnitude
                    offsetNorth *= scale
                    offsetEast *= scale
                }
                moved.coordinate = fix.coordinate.offset(metersNorth: offsetNorth, metersEast: offsetEast)
            }

            if pace != 1.0 {
                moved.speed = fix.speed / pace
            }

            // Accuracy wanders the way a real receiver's does: a slow walk
            // rather than a constant, because a column of identical accuracy
            // figures is its own giveaway.
            moved.horizontalAccuracy = (fix.horizontalAccuracy + generator.gaussian(mean: 0, deviation: 1.4))
                .clamped(to: 3.0...48.0)

            output.append(moved)
        }

        return output
    }

    /// A short description of what a given variation actually did, for the UI.
    public func describe() -> String {
        guard departureSlack > 0 || paceSlack > 0 || lateralDrift > 0 else {
            return "Replayed exactly as recorded."
        }
        return "Departure shifts up to \(Int(departureSlack)) min, pace up to \(Int(paceSlack * 100))%, path wanders up to \(Int(lateralDrift)) m."
    }
}
