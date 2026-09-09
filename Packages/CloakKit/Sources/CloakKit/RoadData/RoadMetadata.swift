import Foundation

public struct RoadSegment: Hashable, Codable, Sendable {
    public var roadClass: RoadClass
    public var limit: Double?
    public var nodes: [Coordinate]

    public init(roadClass: RoadClass, limit: Double?, nodes: [Coordinate]) {
        self.roadClass = roadClass
        self.limit = limit
        self.nodes = nodes
    }

    public var effectiveLimit: Double { limit ?? roadClass.defaultLimit }
}

public struct RoadMetadata: Hashable, Codable, Sendable {
    public var segments: [RoadSegment]
    public var controls: [TrafficControl]
    public var fetchedAt: Date
    public var wasFallback: Bool

    public init(segments: [RoadSegment] = [], controls: [TrafficControl] = [], fetchedAt: Date = .now, wasFallback: Bool = false) {
        self.segments = segments
        self.controls = controls
        self.fetchedAt = fetchedAt
        self.wasFallback = wasFallback
    }

    public static let empty = RoadMetadata(wasFallback: true)

    public func limits(along polyline: Polyline, fallback: RoadClass = .residential) -> [Double] {
        guard !segments.isEmpty else {
            return Array(repeating: fallback.defaultLimit, count: polyline.points.count)
        }
        var output: [Double] = []
        output.reserveCapacity(polyline.points.count)
        for point in polyline.points {
            var bestDistance = Double.greatestFiniteMagnitude
            var bestLimit = fallback.defaultLimit
            for segment in segments {
                for node in segment.nodes {
                    let candidate = node.distance(to: point)
                    if candidate < bestDistance {
                        bestDistance = candidate
                        bestLimit = segment.effectiveLimit
                    }
                }
            }
            output.append(bestDistance < 40 ? bestLimit : fallback.defaultLimit)
        }
        return output
    }

    public func snappedControls(to polyline: Polyline, tolerance: Double = 15) -> [TrafficControl] {
        var output: [TrafficControl] = []
        for control in controls {
            let match = polyline.nearestDistance(to: control.coordinate)
            guard match.offset <= tolerance else { continue }
            output.append(TrafficControl(kind: control.kind, coordinate: control.coordinate, alongTrack: match.alongTrack))
        }
        output.sort { $0.alongTrack < $1.alongTrack }
        var deduped: [TrafficControl] = []
        for control in output {
            if let last = deduped.last, abs(last.alongTrack - control.alongTrack) < 12 { continue }
            deduped.append(control)
        }
        return deduped
    }
}
