import Foundation

public enum Curvature {
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
        guard radius.isFinite else { return .greatestFiniteMagnitude }
        return sqrt(max(lateralAcceleration, 0.1) * max(radius, 1))
    }

    public static func profile(for polyline: Polyline, lateralAcceleration: Double) -> [Double] {
        let points = polyline.points
        guard points.count > 2 else { return Array(repeating: .greatestFiniteMagnitude, count: points.count) }
        var speeds = Array(repeating: Double.greatestFiniteMagnitude, count: points.count)
        for index in 1..<(points.count - 1) {
            let r = radius(points[index - 1], points[index], points[index + 1])
            speeds[index] = cornerSpeed(radius: r, lateralAcceleration: lateralAcceleration)
        }
        speeds[0] = speeds.count > 1 ? speeds[1] : .greatestFiniteMagnitude
        speeds[points.count - 1] = speeds[points.count - 2]
        return speeds
    }
}
