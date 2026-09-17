import Foundation

/// Which parts of a route are covered on foot.
///
/// A real trip is not one mode end to end. You drive to a car park, a drop
/// off or the nearest kerb, and then you walk: to the door, through the car
/// park, along the concourse. Cloak used to drive the whole line at driving
/// speeds, so the last two hundred metres into a terminal went past at 25 m/s.
///
/// The decision is made here rather than in the route builder because the
/// answer has to be reproducible. The builder runs in the app; the profile is
/// rebuilt again inside the simulation from nothing but the points, the
/// posted limits and the controls that were handed across. Deriving the modes
/// from those same three things means both sides agree without the payload
/// having to carry anything new.
public enum WalkingLegs {
    /// A posted limit at or under this is not a road anybody drives on.
    ///
    /// OpenStreetMap gives a footway, path, pedestrian way, steps or cycleway
    /// 3 mph by class, and `maxspeed=walk` parses to 4 mph. The slowest thing
    /// with a car on it is a service road or a living street at 15. Nothing
    /// drivable lands in between, so the gap is a clean divider.
    public static let notDrivableCeiling = Speed.mph(6)

    /// A whole route shorter than this is walked whatever it was asked for.
    ///
    /// This is only a floor, deliberately well under where the real decision
    /// is made. Whether a leg is short enough to walk rather than drive is a
    /// question about the leg, not about the line, so it belongs to the route
    /// builder, which knows what the two ends are and asks Apple Maps for a
    /// walking route when the answer is yes: see `LastMile.shortHop`. What is
    /// left here is the case nothing else can rescue, a line so short that
    /// driving it is absurd however it arrived.
    public static let walkWholeTripBelow: Double = 150

    /// The shortest stretch worth changing mode for. A handful of footway
    /// points where the route clips a corner of a plaza is map noise, not a
    /// walk, and swapping modes for it would read as a stutter.
    public static let shortestLeg: Double = 20

    /// The same, for a stretch with driving on both sides of it.
    ///
    /// The walk at either end of a leg is the one the route builder put there,
    /// and it is as short as it needs to be. A walk that turns up in the
    /// middle of a drive came from the road data alone, and the commonest way
    /// for that to happen is a mapped pavement running alongside the road and
    /// measuring nearer to the route line than the carriageway does. So the
    /// middle of a drive has to show a good deal more than a pavement's worth
    /// of footway before the car is parked for it.
    public static let shortestInteriorLeg: Double = 120

    /// Two walks with less driving than this between them are one walk with a
    /// gap in the map data, not two trips either side of a drive.
    public static let mergeGap: Double = 60
    /// How far past the ends of the spans a point may sit and still belong to
    /// them. Densifying a line changes its measured length slightly, and the
    /// route's own last point is the one that suffers.
    public static let edgeSlack: Double = 2

    /// A stretch of the route covered in one mode.
    public struct Span: Hashable, Codable, Sendable {
        public var mode: TravelMode
        public var start: Double
        public var end: Double

        public init(mode: TravelMode, start: Double, end: Double) {
            self.mode = mode
            self.start = start
            self.end = end
        }

        public var length: Double { max(0, end - start) }

        public func contains(_ distance: Double) -> Bool {
            distance >= start && distance <= end
        }
    }

    /// The mode at every point of the line.
    ///
    /// A trip that was asked for on foot stays on foot the whole way. Only a
    /// drive gets split, because only a drive has a part that has to be
    /// walked.
    public static func modes(
        polyline: Polyline,
        postedLimits: [Double],
        requested: TravelMode
    ) -> [TravelMode] {
        let count = polyline.points.count
        guard count > 0 else { return [] }
        guard requested == .drive, count > 1 else {
            return Array(repeating: requested, count: count)
        }
        if polyline.length <= walkWholeTripBelow {
            return Array(repeating: .walk, count: count)
        }
        return onFoot(polyline: polyline, postedLimits: postedLimits)
            .map { $0 ? .walk : .drive }
    }

    /// Which points sit on something only a person can use, after the short
    /// runs and the short gaps have been tidied away.
    public static func onFoot(polyline: Polyline, postedLimits: [Double]) -> [Bool] {
        let count = polyline.points.count
        guard count > 1 else { return Array(repeating: false, count: count) }
        let cumulative = polyline.cumulative

        var flags = (0..<count).map { index -> Bool in
            guard index < postedLimits.count else { return false }
            let limit = postedLimits[index]
            return limit > 0 && limit <= notDrivableCeiling
        }

        // A short stretch of road next to a walk is not a drive. In the
        // middle it is the map losing the footway for a few metres; at either
        // end it is the handful of points where the footway runs out just
        // before the route does. Neither is worth starting a car for.
        for run in runs(of: false, in: flags) {
            let length = cumulative[run.upperBound] - cumulative[run.lowerBound]
            guard length < mergeGap else { continue }
            let walkBefore = run.lowerBound > 0 && flags[run.lowerBound - 1]
            let walkAfter = run.upperBound < count - 1 && flags[run.upperBound + 1]
            guard walkBefore || walkAfter else { continue }
            for index in run { flags[index] = true }
        }

        // A walk too short to be worth getting out of the car for is noise.
        for run in runs(of: true, in: flags) {
            let length = cumulative[run.upperBound] - cumulative[run.lowerBound]
            let touchesAnEnd = run.lowerBound == 0 || run.upperBound == count - 1
            if length < (touchesAnEnd ? shortestLeg : shortestInteriorLeg) {
                for index in run { flags[index] = false }
            }
        }

        return flags
    }

    /// The route broken into stretches of one mode each.
    /// The mode at every point of `polyline`, read off spans measured in
    /// metres along the route.
    ///
    /// Spans are the honest carrier for a walk decision. Modes-per-point only
    /// mean anything against the exact point list they were computed from, and
    /// the live simulation densifies the route to 4 m before it runs, so a
    /// per-point array would have to be resampled and would drift. A distance
    /// range does not care how the line was sampled.
    ///
    /// Anything not covered by a span is `fallback`, so a payload carrying no
    /// spans behaves exactly as it did before spans existed.
    public static func modes(
        polyline: Polyline,
        spans: [Span],
        fallback: TravelMode
    ) -> [TravelMode] {
        let cumulative = polyline.cumulative
        guard !cumulative.isEmpty else { return [] }
        guard !spans.isEmpty else {
            return [TravelMode](repeating: fallback, count: cumulative.count)
        }
        let ordered = spans.sorted { $0.start < $1.start }
        guard let first = ordered.first, let last = ordered.last else {
            return [TravelMode](repeating: fallback, count: cumulative.count)
        }

        // Spans are measured on the line the builder had; the line here has
        // been densified, and a geodesic length recomputed over many more
        // points does not land on the same number to the metre. Without this
        // tolerance the final point of a route sits a few centimetres past the
        // end of the last span and falls back to driving, which is the last
        // stride of the walk to the door.
        let slack = max(edgeSlack, cumulative[cumulative.count - 1] * 0.002)

        var result = [TravelMode](repeating: fallback, count: cumulative.count)
        var cursor = 0
        for index in cumulative.indices {
            var distance = cumulative[index]
            if distance < first.start, first.start - distance <= slack { distance = first.start }
            if distance > last.end, distance - last.end <= slack { distance = last.end }
            while cursor < ordered.count, ordered[cursor].end < distance {
                cursor += 1
            }
            if cursor < ordered.count, ordered[cursor].contains(distance) {
                result[index] = ordered[cursor].mode
            }
        }
        return result
    }

    public static func spans(polyline: Polyline, modes: [TravelMode]) -> [Span] {
        guard modes.count == polyline.points.count, modes.count > 1 else { return [] }
        let cumulative = polyline.cumulative
        var output: [Span] = []
        var start = 0
        for index in 1..<modes.count {
            if modes[index] != modes[start] {
                output.append(Span(mode: modes[start], start: cumulative[start], end: cumulative[index]))
                start = index
            }
        }
        output.append(Span(mode: modes[start], start: cumulative[start], end: cumulative[modes.count - 1]))
        return output
    }

    /// How much of the route is walked.
    public static func walkingDistance(polyline: Polyline, modes: [TravelMode]) -> Double {
        spans(polyline: polyline, modes: modes)
            .filter(\.mode.isOnFoot)
            .reduce(0) { $0 + $1.length }
    }

    /// Maximal runs of one value, as index ranges.
    private static func runs(of value: Bool, in flags: [Bool]) -> [ClosedRange<Int>] {
        var output: [ClosedRange<Int>] = []
        var index = 0
        while index < flags.count {
            guard flags[index] == value else { index += 1; continue }
            var end = index
            while end + 1 < flags.count, flags[end + 1] == value { end += 1 }
            output.append(index...end)
            index = end + 1
        }
        return output
    }
}
