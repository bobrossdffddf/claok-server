import Foundation

/// Builds a believable drive from a single starting point, no destination.
///
/// SHIELD press-and-go needs a road to follow the moment the car pulls out,
/// and asking the driver to set a route first defeats the point. This walks
/// the road graph from where the phone is: it snaps to the nearest road, picks
/// the way the car is most likely already pointing, and keeps taking the
/// straightest continuation at each junction until it has enough road to drive
/// on. Real streets, real limits, generated in a moment.
public enum AutoDrive {
    /// A path of at least `metres` metres starting at `origin`, following the
    /// roads in `metadata`. Returns nil only when no road is near the origin.
    public static func path(
        from origin: Coordinate,
        heading: Double? = nil,
        metres target: Double,
        metadata: RoadMetadata
    ) -> [Coordinate]? {
        guard !metadata.segments.isEmpty else { return nil }

        // The node nearest the origin, and the segment it belongs to.
        var nodes: [Coordinate] = []
        guard let start = nearestNode(to: origin, in: metadata) else { return nil }

        // Direction to leave in: the driver's heading if we have one, else the
        // way that leads away from the origin along the first road.
        var current = start
        var previous: Coordinate? = heading.flatMap { h in
            current.node.moved(bearing: h + 180, distance: 15)
        }
        nodes.append(current.node)

        var travelled = 0.0
        var guardCount = 0
        while travelled < target && guardCount < 4000 {
            guardCount += 1
            guard let next = step(from: current, avoiding: previous, in: metadata) else { break }
            travelled += current.node.distance(to: next.node)
            previous = current.node
            current = next
            nodes.append(current.node)
        }

        return nodes.count >= 2 ? nodes : nil
    }

    private struct Anchor {
        var segment: Int
        var index: Int
        var node: Coordinate
    }

    private static func nearestNode(to point: Coordinate, in metadata: RoadMetadata) -> Anchor? {
        var best: Anchor?
        var bestDistance = Double.greatestFiniteMagnitude
        for (segmentIndex, segment) in metadata.segments.enumerated() {
            for (nodeIndex, node) in segment.nodes.enumerated() {
                let d = point.distance(to: node)
                if d < bestDistance {
                    bestDistance = d
                    best = Anchor(segment: segmentIndex, index: nodeIndex, node: node)
                }
            }
        }
        return bestDistance < 120 ? best : nil
    }

    /// The next node to drive to: the neighbour, on this or a connecting road,
    /// that keeps going the same way, never turning straight back.
    private static func step(from anchor: Anchor, avoiding previous: Coordinate?, in metadata: RoadMetadata) -> Anchor? {
        let bearingIn = previous.map { $0.bearing(to: anchor.node) }

        var candidates: [(Anchor, Double)] = []
        for (segmentIndex, segment) in metadata.segments.enumerated() {
            for (nodeIndex, node) in segment.nodes.enumerated() {
                // A node shares a place with the anchor if it is essentially
                // on top of it (roads meet by sharing coordinates in OSM).
                guard node.distance(to: anchor.node) < 6 else { continue }
                for neighbourIndex in [nodeIndex - 1, nodeIndex + 1] where segment.nodes.indices.contains(neighbourIndex) {
                    let neighbour = segment.nodes[neighbourIndex]
                    if let previous, neighbour.distance(to: previous) < 6 { continue }
                    if neighbour.distance(to: anchor.node) < 3 { continue }
                    let outBearing = anchor.node.bearing(to: neighbour)
                    let turn = bearingIn.map { angleBetween($0, outBearing) } ?? 0
                    candidates.append((Anchor(segment: segmentIndex, index: neighbourIndex, node: neighbour), turn))
                }
            }
        }
        // Straightest continuation wins; a big turn is a last resort.
        return candidates.min(by: { $0.1 < $1.1 })?.0
    }

    private static func angleBetween(_ a: Double, _ b: Double) -> Double {
        var diff = abs(a - b).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff = 360 - diff }
        return diff
    }
}
