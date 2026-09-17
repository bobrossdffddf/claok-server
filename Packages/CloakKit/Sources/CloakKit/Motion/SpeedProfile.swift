import Foundation

public struct SpeedProfile: Sendable {
    /// No signal or crossing stops within this distance of the start of a
    /// drive. See the note where stops are chosen.
    public static let cleanStartDistance: Double = 1_200

    public let polyline: Polyline
    public let ceiling: [Double]
    public let stops: [StopEvent]
    /// The mode at every point of the line. Empty on a profile built before
    /// routes could mix modes, which is read as driving throughout.
    public let modes: [TravelMode]

    public init(polyline: Polyline, ceiling: [Double], stops: [StopEvent], modes: [TravelMode] = []) {
        self.polyline = polyline
        self.ceiling = ceiling
        self.stops = stops
        self.modes = modes
    }

    public func speed(at distance: Double) -> Double {
        guard !ceiling.isEmpty else { return 0 }
        let cumulative = polyline.cumulative
        if distance <= 0 { return ceiling[0] }
        if distance >= polyline.length { return ceiling[ceiling.count - 1] }
        let index = Self.lowerIndex(cumulative, distance)
        let span = cumulative[index + 1] - cumulative[index]
        let fraction = span > 0 ? (distance - cumulative[index]) / span : 0
        return ceiling[index] + (ceiling[index + 1] - ceiling[index]) * fraction
    }

    /// How the person is getting along this part of the route.
    public func mode(at distance: Double) -> TravelMode {
        guard !modes.isEmpty else { return .drive }
        let cumulative = polyline.cumulative
        if distance <= 0 { return modes[0] }
        if distance >= polyline.length { return modes[modes.count - 1] }
        let index = min(Self.lowerIndex(cumulative, distance), modes.count - 1)
        return modes[index]
    }

    /// The stretches of the route, one mode each.
    public var spans: [WalkingLegs.Span] {
        WalkingLegs.spans(polyline: polyline, modes: modes)
    }

    /// How much of the route is covered on foot.
    public var walkingDistance: Double {
        WalkingLegs.walkingDistance(polyline: polyline, modes: modes)
    }

    public func minimumSpeed(from start: Double, to end: Double) -> Double {
        guard !ceiling.isEmpty else { return 0 }
        let low = min(start, end)
        let high = max(start, end)
        var result = min(speed(at: low), speed(at: high))
        let cumulative = polyline.cumulative
        var index = Self.lowerIndex(cumulative, low)
        while index < cumulative.count, cumulative[index] <= high {
            if cumulative[index] >= low { result = min(result, ceiling[index]) }
            index += 1
        }
        return result
    }

    private static func lowerIndex(_ cumulative: [Double], _ distance: Double) -> Int {
        var low = 0
        var high = cumulative.count - 1
        while low + 1 < high {
            let mid = (low + high) / 2
            if cumulative[mid] <= distance { low = mid } else { high = mid }
        }
        return low
    }
}

public enum SpeedProfileBuilder {
    /// How far short of a change of mode the handover happens. The car stops
    /// a few metres before the point the walk starts from rather than on it,
    /// the same reason a car waits short of the stop line.
    public static let handoverSetback: Double = 3
    /// Getting out of the car, locking it, picking the bag up.
    public static let parkingDwell: ClosedRange<Double> = 20...55
    /// Finding the car, getting in, setting off.
    public static let boardingDwell: ClosedRange<Double> = 15...40
    /// A control stop this close to a handover is the same halt twice.
    public static let handoverClearance: Double = 20

    public static func build(
        polyline: Polyline,
        postedLimits: [Double],
        controls: [TrafficControl],
        persona: DriverPersona,
        mode: TravelMode,
        speedHelp: SpeedHelp = SpeedHelp(),
        /// Spans the route builder already decided are on foot, measured in
        /// metres along the route. When these are supplied they are the
        /// answer; the line is not re-examined. Inferring a walk from posted
        /// limits at simulation time reads a mapped pavement running beside
        /// the carriageway as a footway, and drops the car to walking pace in
        /// the middle of an ordinary drive.
        walkingSpans: [WalkingLegs.Span]? = nil,
        seed: UInt64
    ) -> SpeedProfile {
        var generator = SeededGenerator(seed: seed)
        let points = polyline.points
        guard points.count > 1 else {
            return SpeedProfile(polyline: polyline, ceiling: [0], stops: [], modes: [mode])
        }

        let cumulative = polyline.cumulative
        let modes: [TravelMode]
        if let walkingSpans {
            modes = WalkingLegs.modes(polyline: polyline, spans: walkingSpans, fallback: mode)
        } else {
            modes = WalkingLegs.modes(polyline: polyline, postedLimits: postedLimits, requested: mode)
        }
        let corner = Curvature.profile(for: polyline, lateralAcceleration: persona.lateralAcceleration)

        func modeAt(_ distance: Double) -> TravelMode {
            guard !modes.isEmpty else { return mode }
            if distance <= 0 { return modes[0] }
            if distance >= polyline.length { return modes[modes.count - 1] }
            var low = 0
            var high = cumulative.count - 1
            while low + 1 < high {
                let mid = (low + high) / 2
                if cumulative[mid] <= distance { low = mid } else { high = mid }
            }
            return modes[min(low, modes.count - 1)]
        }

        var ceiling = [Double](repeating: 0, count: points.count)
        for index in points.indices {
            let here = modes[index]
            let band = here.speedBand
            let posted = index < postedLimits.count ? postedLimits[index] : RoadClass.residential.defaultLimit
            let target: Double
            switch here {
            case .drive:
                // The persona's own habit is the starting point. Speed help,
                // when it is on, decides instead, and it decides per point, so
                // the drive follows the limits along the route rather than
                // holding one number the whole way.
                let habit = max(Speed.mph(5), posted + persona.speedOffset)
                target = speedHelp.target(postedLimit: posted, fallback: habit)
            case .walk, .run, .cycle:
                // Not the posted limit and not the top of the band. A person
                // walks at their own pace whatever the sign on the road says,
                // and that pace is the one thing here that must never read as
                // driving.
                target = here.cruisingSpeed
            }
            var value = min(target, band.upperBound)
            // Feet do not have a cornering limit worth modelling. A car does.
            if !here.cutsCorners { value = min(value, corner[index]) }
            ceiling[index] = value
        }

        // MARK: Stops for the things on the road

        var stops: [StopEvent] = []
        for control in controls {
            let here = modeAt(control.alongTrack)
            if here.obeysTrafficControl {
                switch control.kind {
                case .signal:
                    if generator.chance(persona.redLightProbability) {
                        stops.append(StopEvent(alongTrack: control.alongTrack, dwell: generator.double(in: persona.signalDwellRange), kind: .signal))
                    }
                case .stop:
                    stops.append(StopEvent(alongTrack: control.alongTrack, dwell: generator.double(in: persona.stopSignDwellRange), kind: .stop))
                case .giveWay:
                    if generator.chance(StopOdds.giveWay) {
                        stops.append(StopEvent(alongTrack: control.alongTrack, dwell: generator.double(in: 1.0...2.5), kind: .giveWay))
                    }
                case .crossing:
                    // A signalled crossing stops traffic now and then. A plain
                    // one almost never does; stopping at random zebra crossings
                    // was one of the things that looked wrong.
                    if control.isSignalled, generator.chance(StopOdds.signalledCrossing) {
                        stops.append(StopEvent(alongTrack: control.alongTrack, dwell: generator.double(in: 4.0...14.0), kind: .crossing))
                    } else if !control.isSignalled, generator.chance(StopOdds.plainCrossing) {
                        stops.append(StopEvent(alongTrack: control.alongTrack, dwell: generator.double(in: 2.0...5.0), kind: .crossing))
                    }
                case .roundabout:
                    applyCeiling(&ceiling, polyline: polyline, at: control.alongTrack, radius: 25, value: Speed.mph(15))
                }
            } else if control.kind == .crossing {
                // On foot there are no lights to obey and no lane to hold. The
                // only thing that stops a person is traffic, and they wait for
                // a gap rather than for a phase.
                if generator.chance(StopOdds.crossingOnFoot) {
                    stops.append(StopEvent(alongTrack: control.alongTrack, dwell: generator.double(in: here.stopDwellRange), kind: .crossing))
                }
            }
        }

        stops.sort { $0.alongTrack < $1.alongTrack }

        // Where the drive actually begins. A route that starts with a walk to
        // the car has its clean start measured from the car, not from the door.
        let driveStarts = modes.firstIndex(of: .drive).map { cumulative[$0] } ?? 0

        var deduped: [StopEvent] = []
        for stop in stops {
            if let last = deduped.last, stop.alongTrack - last.alongTrack < 15 { continue }
            if stop.alongTrack < 10 || stop.alongTrack > polyline.length - 10 { continue }
            // A clean start. iOS reports simulated fixes with no speed field,
            // so apps that watch for driving (Life360 wants over 15 mph for
            // more than half a mile) have to infer it from the position
            // moving steadily. A red light in the first mile breaks that run
            // before it counts, so the first stretch of a drive has none.
            if modeAt(stop.alongTrack) == .drive, stop.kind != .stop,
               stop.alongTrack < driveStarts + SpeedProfile.cleanStartDistance { continue }
            deduped.append(stop)
        }

        // MARK: Getting out of the car, and back into it

        let handovers = self.handovers(
            polyline: polyline,
            modes: modes,
            generator: &generator
        )
        if !handovers.isEmpty {
            // A halt for a traffic light right where the car is being parked
            // is the same halt written twice.
            deduped.removeAll { stop in
                handovers.contains { abs($0.alongTrack - stop.alongTrack) < handoverClearance }
            }
            deduped.append(contentsOf: handovers)
            deduped.sort { $0.alongTrack < $1.alongTrack }
        }

        ceiling[ceiling.count - 1] = 0
        smoothBackward(&ceiling, polyline: polyline, decel: persona.braking)
        smoothForward(&ceiling, polyline: polyline, accel: persona.acceleration)

        return SpeedProfile(polyline: polyline, ceiling: ceiling, stops: deduped, modes: modes)
    }

    /// A halt wherever the route changes mode.
    ///
    /// The ceiling alone already ramps the car down to walking pace over the
    /// twenty metres before a walk starts, so nothing teleports either way.
    /// But a drive does not turn into a walk while still rolling: the car
    /// parks, and the person gets out. Putting a stop on the seam is both what
    /// really happens and the plainest possible guarantee that no single fix
    /// steps from driving speed to walking speed.
    private static func handovers(
        polyline: Polyline,
        modes: [TravelMode],
        generator: inout SeededGenerator
    ) -> [StopEvent] {
        guard modes.count == polyline.points.count, modes.count > 1 else { return [] }
        let cumulative = polyline.cumulative
        var output: [StopEvent] = []
        for index in 1..<modes.count where modes[index] != modes[index - 1] {
            let seam = cumulative[index]
            let at = max(0, seam - handoverSetback)
            guard at > 10, at < polyline.length - 10 else { continue }
            let leaving = modes[index - 1]
            let arriving = modes[index]
            let dwell: TimeInterval
            if leaving == .drive, arriving.isOnFoot {
                dwell = generator.double(in: parkingDwell)
            } else if leaving.isOnFoot, arriving == .drive {
                dwell = generator.double(in: boardingDwell)
            } else {
                dwell = generator.double(in: 4...12)
            }
            if let last = output.last, at - last.alongTrack < 15 { continue }
            output.append(StopEvent(alongTrack: at, dwell: dwell, kind: .stop))
        }
        return output
    }

    private static func applyCeiling(_ ceiling: inout [Double], polyline: Polyline, at distance: Double, radius: Double, value: Double) {
        let cumulative = polyline.cumulative
        for index in ceiling.indices where abs(cumulative[index] - distance) <= radius {
            ceiling[index] = min(ceiling[index], value)
        }
    }

    private static func smoothBackward(_ ceiling: inout [Double], polyline: Polyline, decel: Double) {
        let cumulative = polyline.cumulative
        guard ceiling.count > 1 else { return }
        for index in stride(from: ceiling.count - 2, through: 0, by: -1) {
            let ds = cumulative[index + 1] - cumulative[index]
            ceiling[index] = min(ceiling[index], sqrt(ceiling[index + 1] * ceiling[index + 1] + 2 * decel * ds))
        }
    }

    private static func smoothForward(_ ceiling: inout [Double], polyline: Polyline, accel: Double) {
        let cumulative = polyline.cumulative
        guard ceiling.count > 1 else { return }
        for index in 1..<ceiling.count {
            let ds = cumulative[index] - cumulative[index - 1]
            ceiling[index] = min(ceiling[index], sqrt(ceiling[index - 1] * ceiling[index - 1] + 2 * accel * ds))
        }
    }
}
