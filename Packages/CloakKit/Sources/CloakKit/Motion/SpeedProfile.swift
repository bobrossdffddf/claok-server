import Foundation

public struct SpeedProfile: Sendable {
    public let polyline: Polyline
    public let ceiling: [Double]
    public let stops: [StopEvent]

    public init(polyline: Polyline, ceiling: [Double], stops: [StopEvent]) {
        self.polyline = polyline
        self.ceiling = ceiling
        self.stops = stops
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
    public static func build(
        polyline: Polyline,
        postedLimits: [Double],
        controls: [TrafficControl],
        persona: DriverPersona,
        mode: TravelMode,
        seed: UInt64
    ) -> SpeedProfile {
        var generator = SeededGenerator(seed: seed)
        let points = polyline.points
        guard points.count > 1 else {
            return SpeedProfile(polyline: polyline, ceiling: [0], stops: [])
        }

        let corner = Curvature.profile(for: polyline, lateralAcceleration: persona.lateralAcceleration)
        let band = mode.speedBand

        var ceiling = [Double](repeating: 0, count: points.count)
        for index in points.indices {
            let posted = index < postedLimits.count ? postedLimits[index] : RoadClass.residential.defaultLimit
            let target: Double
            switch mode {
            case .drive:
                target = max(Speed.mph(5), posted + persona.speedOffset)
            case .walk, .run, .cycle:
                target = band.upperBound
            }
            ceiling[index] = min(target, corner[index], band.upperBound)
        }

        var stops: [StopEvent] = []
        if mode.obeysTrafficControl {
            for control in controls {
                switch control.kind {
                case .signal:
                    if generator.chance(persona.redLightProbability) {
                        stops.append(StopEvent(alongTrack: control.alongTrack, dwell: generator.double(in: persona.signalDwellRange), kind: .signal))
                    }
                case .stop:
                    stops.append(StopEvent(alongTrack: control.alongTrack, dwell: generator.double(in: persona.stopSignDwellRange), kind: .stop))
                case .giveWay:
                    if generator.chance(0.35) {
                        stops.append(StopEvent(alongTrack: control.alongTrack, dwell: generator.double(in: 1.0...2.5), kind: .giveWay))
                    }
                case .crossing:
                    if generator.chance(0.12) {
                        stops.append(StopEvent(alongTrack: control.alongTrack, dwell: generator.double(in: 3.0...12.0), kind: .crossing))
                    }
                case .roundabout:
                    applyCeiling(&ceiling, polyline: polyline, at: control.alongTrack, radius: 25, value: Speed.mph(15))
                }
            }
        } else {
            for control in controls where control.kind == .crossing {
                if generator.chance(0.2) {
                    stops.append(StopEvent(alongTrack: control.alongTrack, dwell: generator.double(in: 4.0...20.0), kind: .crossing))
                }
            }
        }

        stops.sort { $0.alongTrack < $1.alongTrack }
        var deduped: [StopEvent] = []
        for stop in stops {
            if let last = deduped.last, stop.alongTrack - last.alongTrack < 15 { continue }
            if stop.alongTrack < 10 || stop.alongTrack > polyline.length - 10 { continue }
            deduped.append(stop)
        }

        ceiling[ceiling.count - 1] = 0
        smoothBackward(&ceiling, polyline: polyline, decel: persona.braking)
        smoothForward(&ceiling, polyline: polyline, accel: persona.acceleration)

        return SpeedProfile(polyline: polyline, ceiling: ceiling, stops: deduped)
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
