import SwiftUI
import MapKit
import CloakKit

/// Everything about a route that is drawn on the map: the line coloured by how
/// fast the car is going, the road signs it stops at, the other routes on
/// offer, and the stops the person placed.
///
/// Nothing here is worked out while the map draws. The map redraws once a
/// second for the whole of a drive, so the coloured stretches, the signs and
/// which signs fit at each zoom are built once per route off the main thread
/// by `RouteMapStore`, and `body` only picks the ready answer up.
struct RouteMapContent: MapContent {
    let model: AppModel
    let overlay: [CLLocationCoordinate2D]?
    /// How far the map camera is from the ground, in metres, as
    /// `onMapCameraChange` reports it. It decides how many road signs fit on
    /// screen. Without it the signs are thinned for the scale the map opens
    /// at, which is right until somebody zooms well out.
    var cameraDistance: CLLocationDistance? = nil

    var body: some MapContent {
        let store = RouteMapStore.shared
        let route = model.activePlan.flatMap { store.route(for: $0, model: model) }
        let others = store.alternates(model: model)

        // The routes not taken, underneath the chosen one.
        if let others {
            ForEach(others.lines) { line in
                MapPolyline(coordinates: line.coordinates)
                    .stroke(RouteInk.casing.opacity(0.7), style: RouteInk.alternateCasingStroke)
                    .mapOverlayLevel(level: .aboveRoads)
                MapPolyline(coordinates: line.coordinates)
                    .stroke(RouteInk.alternate, style: RouteInk.alternateStroke)
                    .mapOverlayLevel(level: .aboveRoads)
            }
        }

        // MapKit stacks lines by when they were added, not by the order they
        // are written in, and the other routes arrive after the chosen one.
        // Naming the chosen route's lines after the set of others puts them
        // back on the map, on top, whenever that set changes.
        let stacking = others?.key ?? "alone"

        if let route, !route.lines.isEmpty {
            // A dark edge under the whole line first, so every colour on top
            // of it holds against a pale park as well as a dark street.
            ForEach(route.casings.map { Stacked(id: "\(stacking)/c\($0.id)", item: $0) }) { layer in
                MapPolyline(coordinates: layer.item.coordinates)
                    .stroke(RouteInk.casing, style: layer.item.onFoot ? RouteInk.walkCasingStroke : RouteInk.driveCasingStroke)
                    .mapOverlayLevel(level: .aboveRoads)
            }
            ForEach(route.lines.map { Stacked(id: "\(stacking)/l\($0.id)", item: $0) }) { layer in
                MapPolyline(coordinates: layer.item.coordinates)
                    .stroke(layer.item.color, style: layer.item.style)
                    .mapOverlayLevel(level: .aboveRoads)
            }
        } else if let overlay {
            // The route is known but its speeds are still being worked out,
            // which takes a moment the first time: show the plain line rather
            // than nothing.
            MapPolyline(coordinates: overlay)
                .stroke(RouteInk.casing, style: RouteInk.driveCasingStroke)
                .mapOverlayLevel(level: .aboveRoads)
            MapPolyline(coordinates: overlay)
                .stroke(Palette.accent.opacity(0.85), style: RouteInk.driveStroke)
                .mapOverlayLevel(level: .aboveRoads)
        }

        if let others {
            ForEach(others.lines) { line in
                Annotation("Other route, \(line.duration)", coordinate: line.labelCoordinate) {
                    AlternateRouteLabel(duration: line.duration) {
                        model.selectRoute(line.index)
                    }
                }
                .annotationTitles(.hidden)
            }
        }

        if let route {
            ForEach(route.signs(metresPerPoint: metresPerPoint(route))) { sign in
                Annotation(sign.title, coordinate: sign.coordinate, anchor: .bottom) {
                    RoadSignPost(sign: sign.sign, emphasis: sign.emphasis)
                        .accessibilityLabel(Text(sign.spoken))
                }
                .annotationTitles(.hidden)
            }
        }

        ForEach(Array(model.routeWaypoints.enumerated()), id: \.element.id) { index, waypoint in
            Annotation(waypoint.title, coordinate: waypoint.coordinate.clCoordinate) {
                let count = model.routeWaypoints.count
                if count > 1, index == 0 {
                    RouteEndPin(index: index + 1, role: .start)
                } else if count > 1, index == count - 1 {
                    RouteEndPin(index: index + 1, role: .destination)
                } else {
                    WaypointPin(index: index + 1)
                }
            }
        }

        #if DEBUG
        if TourRouteBuilder.isWanted, let first = model.routeWaypoints.first {
            Annotation("", coordinate: first.coordinate.clCoordinate) {
                TourRouteBuilder(model: model)
            }
            .annotationTitles(.hidden)
        }
        #endif
    }

    private func metresPerPoint(_ route: RouteDrawing) -> Double {
        guard let cameraDistance, cameraDistance > 0 else { return route.framedMetresPerPoint }
        return cameraDistance / RouteDrawing.cameraDistancePerPoint
    }
}

/// A line tagged with the stacking generation it belongs to.
private struct Stacked<Item>: Identifiable {
    let id: String
    let item: Item
}

// MARK: - Line styles

private enum RouteInk {
    static let casing = Color(red: 0.02, green: 0.03, blue: 0.05).opacity(0.72)
    static let alternate = Color(red: 0.56, green: 0.60, blue: 0.65)

    static let driveStroke = StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
    /// A coloured stretch in the middle of the route. Round ends on a run of
    /// short stretches stacked up into a string of beads, so the ends are
    /// square and each stretch runs a little under the next instead.
    static let driveSegmentStroke = StrokeStyle(lineWidth: 6, lineCap: .butt, lineJoin: .round)
    static let driveCasingStroke = StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round)

    /// On foot is a row of dots rather than a line, the way Maps draws a walk
    /// and the map's answer to the hatching on the ribbon. The casing dots sit
    /// at the same places as the fill dots, one size up.
    static let walkStroke = StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round, dash: [0.01, 9])
    static let walkCasingStroke = StrokeStyle(lineWidth: 7.5, lineCap: .round, lineJoin: .round, dash: [0.01, 9])

    static let alternateStroke = StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
    static let alternateCasingStroke = StrokeStyle(lineWidth: 7.5, lineCap: .round, lineJoin: .round)

    /// What a walk is painted in: the neutral the ribbon uses for on foot,
    /// lifted so the dots show on a dark map.
    static let walk = Color(red: 0.86, green: 0.89, blue: 0.92)
}

// MARK: - What is drawn, worked out once

/// The chosen route as map content: coloured stretches, casings and signs.
///
/// Built from the ribbon's own `RibbonReading`, never from a second speed
/// profile, so the map and the ribbon cannot disagree about where the car is
/// slow or where it stops.
struct RouteDrawing: Sendable {
    struct Line: Identifiable, Sendable {
        let id: Int
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
        let onFoot: Bool
        /// True for the first and last stretch, which end the route and get
        /// the round ends the casing has.
        let endsRoute: Bool

        var style: StrokeStyle {
            if onFoot { return RouteInk.walkStroke }
            return endsRoute ? RouteInk.driveStroke : RouteInk.driveSegmentStroke
        }
    }

    struct Casing: Identifiable, Sendable {
        let id: Int
        let coordinates: [CLLocationCoordinate2D]
        let onFoot: Bool
    }

    struct Sign: Identifiable, Sendable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let sign: RoadSign
        let emphasis: RoadSignIcon.Emphasis
        let title: String
        let spoken: String
        /// How much this sign matters: 0 happens every drive, 1 on a fair
        /// share of drives, 2 hardly ever or never, 3 crossed off.
        let tier: Int
        /// Lower goes first when there is not room for all of them.
        let rank: Int
        let alongTrack: Double
        /// Flat metres from the start of the route, for spacing signs apart.
        let x: Double
        let y: Double
    }

    let key: String
    let identity: UInt64
    let casings: [Casing]
    let lines: [Line]
    /// For each zoom step, the signs that fit on screen at it.
    let signsByStep: [[Sign]]
    /// A guess at the map's scale when the camera is not known: the route
    /// framed above the sheet, or the scale the map opens at if that is
    /// closer in.
    let framedMetresPerPoint: Double

    /// Camera distance over metres per point, for a flat map on a phone.
    ///
    /// Measured on an iPhone 17 Pro simulator rather than derived, because
    /// MapKit does not publish its field of view: a camera 1,500 m up showed
    /// about 0.9 m a point, which is also what a 30 degree view over the
    /// screen's height works out to. A phone a different height is off by
    /// its share of that, which the half octave zoom steps absorb.
    static let cameraDistancePerPoint: Double = 1_680

    // MARK: Zoom steps

    /// Half an octave apart, from half a metre a point (a few streets on
    /// screen) to a couple of hundred (a whole city).
    private static let stepCount = 18
    private static func metresPerPoint(step: Int) -> Double { 0.5 * pow(2, Double(step) / 2) }
    /// Past this the long shots go: a zebra that holds the car on three
    /// drives in a hundred, a light inside the clean start, a crossed off stop.
    private static let everythingBelow: Double = 2
    /// Past this only the stops that happen on every drive are drawn.
    private static let certainOnlyAbove: Double = 6
    /// A stop at least this likely counts as a fair share of drives. A red
    /// light for an ordinary driver is 0.55 and a give way 0.35; a crossing
    /// is 0.2 at most.
    private static let likelyChance: Double = 0.25
    /// Past this the route is too small on screen for signs to say anything.
    private static let hiddenAbove: Double = 16

    /// Whether a sign standing at `foot` would cover one already kept at
    /// `other`, both measured in points on a north up map.
    ///
    /// A sign stands on its post, so it covers a box above its foot rather
    /// than a circle round it, and the post of a sign just north of another
    /// disappears behind that one's face. MapKit draws the southern of two
    /// annotations in front, so this is the case that matters.
    private static func crowds(_ dx: Double, _ dy: Double) -> Bool {
        let faces = abs(dx) < RoadSignPost.width + 1 && abs(dy) < RoadSignPost.width + 1
        let posts = abs(dx) < RoadSignPost.width / 2 + 2 && abs(dy) < RoadSignPost.height + 1
        return faces || posts
    }

    /// Whether a sign would cover one of the person's own stops or its name.
    /// `dy` is how far north of the sign's foot the stop is.
    private static func covers(pinAt dx: Double, _ dy: Double) -> Bool {
        let nearFoot = hypot(dx, dy) < 16
        let underFace = abs(dx) < RoadSignPost.width / 2 + 14 && dy > -2 && dy < RoadSignPost.height + 22
        return nearFoot || underFace
    }

    func signs(metresPerPoint: Double) -> [Sign] {
        guard metresPerPoint.isFinite, metresPerPoint > 0, metresPerPoint <= Self.hiddenAbove else { return [] }
        let step = Int((2 * log2(metresPerPoint / 0.5)).rounded())
        return signsByStep[min(max(step, 0), signsByStep.count - 1)]
    }

    // MARK: Building

    /// Speed buckets in mph. Adjacent stretches in one bucket become one
    /// polyline, so a long route is tens of lines rather than one per sample.
    private static let bucketEdges: [Double] = [2, 5, 8, 12, 16, 20, 24, 28, 33, 38, 43]

    /// The spacing `RoutePlan.speedProfile` densifies the line to, which is
    /// what every distance in a `RibbonReading` is measured along.
    private static let readingSpacing: Double = 5

    private static func bucket(_ metresPerSecond: Double) -> Int {
        let mph = Speed.toMph(metresPerSecond)
        return bucketEdges.firstIndex { mph < $0 } ?? bucketEdges.count
    }

    static func fingerprint(_ plan: RoutePlan) -> String {
        let points = plan.polyline.points
        let middle = points.isEmpty ? Coordinate(latitude: 0, longitude: 0) : points[points.count / 2]
        return "\(RibbonReading.identity(of: plan)):\(Int(plan.polyline.length)):\(String(format: "%.5f,%.5f", middle.latitude, middle.longitude))"
    }

    static func build(key: String, identity: UInt64, plan: RoutePlan, reading: RibbonReading) -> RouteDrawing {
        let polyline = plan.polyline
        let framed = framedScale(polyline)
        let empty = RouteDrawing(
            key: key, identity: identity, casings: [], lines: [],
            signsByStep: Array(repeating: [], count: stepCount), framedMetresPerPoint: framed
        )
        let length = reading.length
        guard !reading.isEmpty, length > 5, polyline.points.count > 1, !reading.samples.isEmpty else { return empty }

        // The reading measures along the line densified to 5 m, which cuts a
        // little off every corner, so its distances are not the plan's. Point
        // `i` of the densified line is exactly `5 * i` metres along the plan,
        // which turns one into the other without any drift.
        let dense = polyline.densified(spacing: Self.readingSpacing)
        // The ribbon's held reading is named by the ends of the line and how
        // many points it has. Two offered routes between the same stops can
        // share both, and a reading for the other one would put every sign in
        // the wrong place. The densified length is computed the same way both
        // times, so anything but a match gives it away.
        guard abs(dense.length - length) < 0.5 else { return empty }
        let denseCumulative = dense.cumulative
        let planLength = polyline.length
        func onPlan(_ distance: Double) -> Double {
            guard denseCumulative.count > 1 else { return distance }
            if distance <= 0 { return 0 }
            if distance >= length { return planLength }
            var low = 0
            var high = denseCumulative.count - 1
            while low + 1 < high {
                let middle = (low + high) / 2
                if denseCumulative[middle] <= distance { low = middle } else { high = middle }
            }
            let lowAt = min(Double(low) * Self.readingSpacing, planLength)
            let highAt = high == denseCumulative.count - 1 ? planLength : min(Double(high) * Self.readingSpacing, planLength)
            let span = denseCumulative[high] - denseCumulative[low]
            let fraction = span > 0 ? (distance - denseCumulative[low]) / span : 0
            return lowAt + (highAt - lowAt) * fraction
        }

        // MARK: Stretches, by speed and by mode

        struct Piece {
            var start: Double
            var end: Double
            var onFoot: Bool
            var bucket: Int
            var speedSum: Double
            var weight: Double
        }

        let walks = reading.walkStretches.map { (start: $0.start * length, end: $0.end * length) }
        let samples = reading.samples
        let count = Double(samples.count)
        var pieces: [Piece] = []
        for (index, sample) in samples.enumerated() {
            let low = length * Double(index) / count
            let high = length * Double(index + 1) / count
            // A walk starts where the car is parked, not at a sample's edge,
            // so cut the sample there: the dots then begin at the P sign.
            var cuts = [low, high]
            for walk in walks {
                if walk.start > low, walk.start < high { cuts.append(walk.start) }
                if walk.end > low, walk.end < high { cuts.append(walk.end) }
            }
            cuts.sort()
            for cut in 0..<(cuts.count - 1) {
                let from = cuts[cut], to = cuts[cut + 1]
                guard to > from else { continue }
                let middle = (from + to) / 2
                let onFoot = walks.isEmpty ? sample.onFoot : walks.contains { middle >= $0.start && middle < $0.end }
                let bucket = onFoot ? -1 : Self.bucket(sample.speed)
                let weight = to - from
                if var last = pieces.last, last.onFoot == onFoot, last.bucket == bucket {
                    last.end = to
                    last.speedSum += sample.speed * weight
                    last.weight += weight
                    pieces[pieces.count - 1] = last
                } else {
                    pieces.append(Piece(start: from, end: to, onFoot: onFoot, bucket: bucket, speedSum: sample.speed * weight, weight: weight))
                }
            }
        }

        let table = SpeedRamp.table()
        var lines: [Line] = []
        lines.reserveCapacity(pieces.count)
        // Square ended stretches that only meet leave a hairline of the dark
        // casing showing through where their soft edges touch, so each one
        // runs this far under the one after it.
        let overlap = max(3, length / 2_000)
        for (index, piece) in pieces.enumerated() {
            let speed = piece.weight > 0 ? piece.speedSum / piece.weight : 0
            let isLast = index == pieces.count - 1
            let runsOn = !isLast && !piece.onFoot && !pieces[index + 1].onFoot
            let end = runsOn ? min(pieces[index + 1].end, piece.end + overlap) : piece.end
            lines.append(Line(
                id: index,
                coordinates: slice(polyline, from: onPlan(piece.start), to: onPlan(end)),
                color: piece.onFoot ? RouteInk.walk : SpeedRamp.color(speed, table: table),
                onFoot: piece.onFoot,
                endsRoute: index == 0 || isLast
            ))
        }

        var casings: [Casing] = []
        var runStart = pieces.first?.start ?? 0
        for (index, piece) in pieces.enumerated() {
            let isLast = index == pieces.count - 1
            if isLast || pieces[index + 1].onFoot != piece.onFoot {
                casings.append(Casing(
                    id: casings.count,
                    coordinates: slice(polyline, from: onPlan(runStart), to: onPlan(piece.end)),
                    onFoot: piece.onFoot
                ))
                if !isLast { runStart = pieces[index + 1].start }
            }
        }

        // MARK: Signs

        let origin = polyline.points.first ?? Coordinate(latitude: 0, longitude: 0)
        let metresPerDegreeLat = Coordinate.earthRadius * .pi / 180
        let metresPerDegreeLon = metresPerDegreeLat * cos(origin.latitude * .pi / 180)
        func flat(_ point: Coordinate) -> (x: Double, y: Double) {
            ((point.longitude - origin.longitude) * metresPerDegreeLon, (point.latitude - origin.latitude) * metresPerDegreeLat)
        }

        var signs: [Sign] = []
        for marker in reading.markers {
            let point = polyline.coordinate(at: onPlan(marker.alongTrack))
            let emphasis: RoadSignIcon.Emphasis = marker.suppressed ? .crossedOff : (marker.isCertain ? .certain : .chance)
            let sign = RoadSign(marker.kind)
            let tier: Int
            if marker.suppressed {
                tier = 3
            } else if marker.isCertain {
                tier = 0
            } else {
                tier = marker.probability >= Self.likelyChance ? 1 : 2
            }
            let position = flat(point)
            signs.append(Sign(
                id: marker.id,
                coordinate: point.clCoordinate,
                sign: sign,
                emphasis: emphasis,
                title: marker.title,
                spoken: spoken(marker),
                tier: tier,
                rank: tier * 10 + marker.kind.weight,
                alongTrack: marker.alongTrack,
                x: position.x,
                y: position.y
            ))
        }

        let pins = plan.waypoints.map { flat($0.coordinate) }
        let ordered = signs.sorted { left, right in
            if left.rank != right.rank { return left.rank < right.rank }
            return left.alongTrack < right.alongTrack
        }

        var byStep: [[Sign]] = []
        byStep.reserveCapacity(stepCount)
        for step in 0..<stepCount {
            let metres = metresPerPoint(step: step)
            guard metres <= hiddenAbove * 1.2 else {
                byStep.append([])
                continue
            }
            let deepestTier = metres > certainOnlyAbove ? 0 : (metres > everythingBelow ? 1 : 3)
            var kept: [Sign] = []
            for sign in ordered {
                if sign.tier > deepestTier { continue }
                if pins.contains(where: { covers(pinAt: ($0.x - sign.x) / metres, ($0.y - sign.y) / metres) }) { continue }
                if kept.contains(where: { crowds(($0.x - sign.x) / metres, ($0.y - sign.y) / metres) }) { continue }
                kept.append(sign)
            }
            kept.sort { $0.alongTrack < $1.alongTrack }
            byStep.append(kept)
        }

        return RouteDrawing(
            key: key,
            identity: identity,
            casings: casings,
            lines: lines,
            signsByStep: byStep,
            framedMetresPerPoint: framed
        )
    }

    /// The part of the line between two distances along it, with every bend in
    /// between.
    static func slice(_ polyline: Polyline, from start: Double, to end: Double) -> [CLLocationCoordinate2D] {
        let points = polyline.points
        let cumulative = polyline.cumulative
        guard points.count > 1, end > start else {
            return [polyline.coordinate(at: start).clCoordinate, polyline.coordinate(at: end).clCoordinate]
        }
        var output = [polyline.coordinate(at: start).clCoordinate]
        var low = 0
        var high = cumulative.count
        while low < high {
            let middle = (low + high) / 2
            if cumulative[middle] <= start { low = middle + 1 } else { high = middle }
        }
        var index = low
        while index < points.count, cumulative[index] < end {
            output.append(points[index].clCoordinate)
            index += 1
        }
        output.append(polyline.coordinate(at: end).clCoordinate)
        return output
    }

    private static func framedScale(_ polyline: Polyline) -> Double {
        guard polyline.points.count > 1 else { return 1 }
        let box = polyline.boundingBox()
        let south = Coordinate(latitude: box.minLatitude, longitude: box.minLongitude)
        let tall = south.distance(to: Coordinate(latitude: box.maxLatitude, longitude: box.minLongitude))
        let wide = south.distance(to: Coordinate(latitude: box.minLatitude, longitude: box.maxLongitude))
        // The whole route in the map left above the sheet at its resting
        // height, but never further out than the map opens: MapScreen frames
        // 2.5 km around the start, about 4 m a point, and a long route is
        // looked at from there far more often than framed whole.
        return min(max(tall, wide) / 340, 4)
    }

    private static func spoken(_ marker: RibbonReading.Marker) -> String {
        var text = "\(marker.title), \(RibbonFormat.distance(marker.alongTrack)) in"
        if marker.suppressed {
            text += ", taken off the drive"
        } else if marker.probability <= 0 {
            text += ", never halts this drive"
        } else if marker.isCertain {
            text += marker.kind.isAHalt ? ", every drive" : ""
        } else {
            text += ", on some drives only"
        }
        return text
    }
}

extension RoadSign {
    init(_ kind: RibbonReading.Kind) {
        switch kind {
        case .signal: self = .signalAhead
        case .stopSign: self = .stop
        case .giveWay: self = .yield
        case .crossing: self = .pedestrianCrossing
        case .roundabout: self = .roundabout
        case .parking: self = .parking
        case .boarding: self = .backInCar
        }
    }
}

// MARK: - The other routes

struct AlternateDrawing: Sendable {
    struct Line: Identifiable, Sendable {
        var id: Int { index }
        /// Where this route sits in `AppModel.routeAlternatives`.
        let index: Int
        let coordinates: [CLLocationCoordinate2D]
        /// Where its label goes: the point furthest from every other line and
        /// label, so it sits on the part of this route only this route uses.
        let labelCoordinate: CLLocationCoordinate2D
        let duration: String
    }

    let key: String
    let lines: [Line]

    static func build(key: String, plans: [RoutePlan], chosen: Int, active: RoutePlan) -> AlternateDrawing {
        var lines: [Line] = []
        var placed: [Coordinate] = []
        for (index, plan) in plans.enumerated() where index != chosen {
            let polyline = plan.polyline
            guard polyline.points.count > 1 else { continue }
            // Every other line on the map: the chosen one and the other
            // routes not taken. Two alternatives often leave the chosen route
            // at the same junction, and a label placed only by its distance
            // from the chosen route put both labels on top of each other.
            let others = plans.enumerated().filter { $0.offset != index }.map(\.element.polyline)
            var best = polyline.coordinate(at: polyline.length / 2)
            var bestScore = -Double.greatestFiniteMagnitude
            let steps = 40
            for step in 0...steps {
                let fraction = 0.15 + 0.7 * Double(step) / Double(steps)
                let point = polyline.coordinate(at: polyline.length * fraction)
                let fromLines = others.map { $0.nearestDistance(to: point).offset }.min() ?? active.polyline.nearestDistance(to: point).offset
                let fromLabels = placed.map { $0.distance(to: point) }.min() ?? .greatestFiniteMagnitude
                // Nearer the middle wins a tie, so a label does not sit at
                // the far end of a pair of lines that only split briefly.
                let score = min(fromLines, fromLabels / 2) - abs(fraction - 0.5) * 40
                if score > bestScore {
                    bestScore = score
                    best = point
                }
            }
            placed.append(best)
            lines.append(Line(
                index: index,
                coordinates: polyline.points.map(\.clCoordinate),
                labelCoordinate: best.clCoordinate,
                duration: durationText(plan.expectedTravelTime)
            ))
        }
        return AlternateDrawing(key: key, lines: lines)
    }

    /// The same words the route card uses for its drive time.
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(total)s"
    }
}

// MARK: - The store

/// Holds what the map draws for the current route, keyed on exactly what can
/// change it: the plan, the driver, the speed help and the stops crossed off.
///
/// `MapContent` cannot hold state of its own, and one route is on screen at a
/// time, so this is one shared object. Asking for a key it does not have yet
/// starts the work off the main thread and returns whatever still fits in the
/// meantime; the answer arriving is what redraws the map.
@MainActor
@Observable
final class RouteMapStore {
    static let shared = RouteMapStore()

    private(set) var route: RouteDrawing?
    private(set) var alternateLines: AlternateDrawing?

    @ObservationIgnored private var routeWanted: String?
    @ObservationIgnored private var alternatesWanted: String?

    func route(for plan: RoutePlan, model: AppModel) -> RouteDrawing? {
        let identity = RibbonReading.identity(of: plan)
        let help = model.speedHelp
        let persona = model.persona
        let crossed = model.suppressedControls
        let key = [
            RouteDrawing.fingerprint(plan),
            persona.id,
            "\(help.isEnabled)-\(help.mode.rawValue)-\(help.profile.rawValue)-\(Int(help.manualMaxMph))",
            crossed.sorted().joined(separator: "|")
        ].joined(separator: "/")

        if let route, route.key == key { return route }
        if routeWanted != key {
            routeWanted = key
            Task.detached(priority: .userInitiated) {
                let reading = await RibbonReading.make(plan: plan, persona: persona, speedHelp: help, suppressed: crossed)
                let drawing = RouteDrawing.build(key: key, identity: identity, plan: plan, reading: reading)
                await RouteMapStore.shared.deliver(drawing)
            }
        }
        // Same line, different driver or a stop crossed off: keep the old
        // colours up until the new ones land rather than flashing plain.
        if let route, route.identity == identity { return route }
        return nil
    }

    func alternates(model: AppModel) -> AlternateDrawing? {
        let plans = model.routeAlternatives
        let chosen = model.selectedRouteIndex
        guard plans.count > 1, plans.indices.contains(chosen), let active = model.activePlan else { return nil }
        let activePrint = RouteDrawing.fingerprint(active)
        let prints = plans.map(RouteDrawing.fingerprint)
        // Offered routes left over from stops that have since moved are not
        // alternatives to anything on screen.
        guard prints[chosen] == activePrint else { return nil }
        let key = prints.joined(separator: ",") + "#\(chosen)"

        if let alternateLines, alternateLines.key == key { return alternateLines }
        if alternatesWanted != key {
            alternatesWanted = key
            Task.detached(priority: .userInitiated) {
                let drawing = AlternateDrawing.build(key: key, plans: plans, chosen: chosen, active: active)
                await RouteMapStore.shared.deliverAlternates(drawing)
            }
        }
        return nil
    }

    private func deliver(_ drawing: RouteDrawing) {
        guard drawing.key == routeWanted else { return }
        route = drawing
    }

    private func deliverAlternates(_ drawing: AlternateDrawing) {
        guard drawing.key == alternatesWanted else { return }
        alternateLines = drawing
    }
}

// MARK: - Views on the map

/// A road sign on a short post, standing on the spot the car stops.
///
/// The foot of the post is the stop itself. Standing the sign above it rather
/// than on it leaves the red of the slowdown showing where it matters.
private struct RoadSignPost: View {
    let sign: RoadSign
    let emphasis: RoadSignIcon.Emphasis

    /// The footprint the thinning in `RouteDrawing` plans around, in points.
    nonisolated static let width: Double = 24
    nonisolated static let height: Double = 24 + 9 + 6

    var body: some View {
        VStack(spacing: 0) {
            RoadSignIcon(sign: sign, size: 24, emphasis: emphasis)
            // Tall enough that the face stands clear of the few metres either
            // side of the stop, where the line turns red.
            Rectangle()
                .fill(Color(white: 0.78))
                .frame(width: 1.5, height: 9)
                .overlay(Rectangle().stroke(Color.black.opacity(0.45), lineWidth: 0.5))
            // Dark with a light ring, so the foot never reads as one of the
            // white dots of a walk.
            Circle()
                .fill(Palette.ground)
                .frame(width: 6, height: 6)
                .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
        }
        .opacity(emphasis == .crossedOff ? 0.85 : 1)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
    }
}

/// The first and last stops, as a route planner draws them: green where you
/// set off, red where you arrive. The same size and type as `WaypointPin`, so
/// the stops in between still read as one set with these.
private struct RouteEndPin: View {
    enum Role { case start, destination }

    let index: Int
    let role: Role

    var body: some View {
        Text("\(index)")
            .font(.live(.caption))
            .foregroundStyle(Palette.ground)
            .frame(width: 24, height: 24)
            .background(Circle().fill(role == .start ? Palette.ok : Palette.danger))
            .overlay(Circle().stroke(Palette.ground, lineWidth: 2))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(role == .start ? "Start, stop \(index)" : "Destination, stop \(index)"))
    }
}

/// How long another route takes, on that route. Tapping it drives that one.
private struct AlternateRouteLabel: View {
    let duration: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(duration)
                .font(.live(.caption))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, Metrics.tight)
                .padding(.vertical, Metrics.hair)
                .background(Capsule().fill(Palette.raised))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
                // The capsule is small; the target is not.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(PressableStyle(scale: 0.94))
        .accessibilityLabel(Text("Other route, \(duration)"))
        .accessibilityHint(Text("Switches the drive to this route"))
    }
}

#if DEBUG
/// Screenshot tours only. A tour that seeds stops (`CLOAK_TOUR_STOPS`) gets
/// its route built as well, so the route, its colours and its signs can be
/// captured without a finger on the simulator. `CLOAK_TOUR_BUILD=0` leaves
/// the stops unbuilt, the way they used to be.
private struct TourRouteBuilder: View {
    let model: AppModel

    static let isWanted: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["CLOAK_TOUR"] == "map" && env["CLOAK_TOUR_STOPS"] != nil && env["CLOAK_TOUR_BUILD"] != "0"
    }()

    @MainActor private static var hasRun = false

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
            .task {
                guard !Self.hasRun else { return }
                Self.hasRun = true
                try? await Task.sleep(for: .milliseconds(300))
                guard model.activePlan == nil, model.routeWaypoints.count >= 2 else { return }
                await model.previewRoute()
            }
    }
}
#endif
