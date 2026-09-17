import Foundation

public enum Curvature {
    /// How far either side of a point the line is sampled to measure its bend.
    ///
    /// Taking the bend from neighbouring points of a route line measures the
    /// map rather than the road. The line handed to the profile is densified
    /// every four or five metres, and a road drawn with even ten centimetres
    /// of digitising wobble turns each of those steps into a visible kink: the
    /// circle through three points 4 m apart with 0.1 m of wobble has a radius
    /// around 100 m, which caps a dead straight road at about 39 mph. That is
    /// the "45 limit showing 39" report.
    ///
    /// A car turns on a scale of tens of metres, so the bend is measured
    /// across that span instead. Three points on a curve give that curve's
    /// radius whatever their spacing, so genuine corners come out unchanged
    /// while the wobble averages out over the span.
    public static let baseline: Double = 25

    public static func radius(_ a: Coordinate, _ b: Coordinate, _ c: Coordinate) -> Double {
        let ab = a.distance(to: b)
        let bc = b.distance(to: c)
        let ca = c.distance(to: a)
        guard ab > 0.5, bc > 0.5, ca > 0.5 else { return .greatestFiniteMagnitude }
        let s = (ab + bc + ca) / 2
        let squared = s * (s - ab) * (s - bc) * (s - ca)
        guard squared > 0 else { return .greatestFiniteMagnitude }
        let area = sqrt(squared)
        guard area > 0.01 else { return .greatestFiniteMagnitude }
        return (ab * bc * ca) / (4 * area)
    }

    public static func cornerSpeed(radius: Double, lateralAcceleration: Double) -> Double {
        // A radius this large is "straight" by any measure, and multiplying
        // the sentinel radius by an acceleration overflows to infinity.
        guard radius.isFinite, radius < 1_000_000 else { return .greatestFiniteMagnitude }
        return sqrt(max(lateralAcceleration, 0.1) * max(radius, 1))
    }

    public static func profile(
        for polyline: Polyline,
        lateralAcceleration: Double,
        baseline: Double = Curvature.baseline
    ) -> [Double] {
        let points = polyline.points
        guard points.count > 2 else { return Array(repeating: .greatestFiniteMagnitude, count: points.count) }
        let cumulative = polyline.cumulative
        let length = polyline.length
        // A route shorter than a couple of spans still gets a reading, just
        // over whatever span fits.
        let span = max(1, min(baseline, length / 3))

        var speeds = Array(repeating: Double.greatestFiniteMagnitude, count: points.count)
        var firstMeasured: Int?
        var lastMeasured: Int?
        for index in points.indices {
            let along = cumulative[index]
            // Near the ends the span would have to be shortened, and a short
            // span is back to measuring the wobble. Those points take the
            // nearest real reading instead.
            guard along >= span, length - along >= span else { continue }
            let behind = polyline.coordinate(at: along - span)
            let ahead = polyline.coordinate(at: along + span)
            speeds[index] = cornerSpeed(
                radius: radius(behind, points[index], ahead),
                lateralAcceleration: lateralAcceleration
            )
            if firstMeasured == nil { firstMeasured = index }
            lastMeasured = index
        }

        guard let first = firstMeasured, let last = lastMeasured else { return speeds }
        for index in 0..<first { speeds[index] = speeds[first] }
        if last + 1 < points.count {
            for index in (last + 1)..<points.count { speeds[index] = speeds[last] }
        }
        return speeds
    }
}
