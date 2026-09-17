import SwiftUI
import CloakKit

// MARK: - Stops the person has crossed off

/// Names for the things on the road, so a stop somebody has crossed off stays
/// crossed off when the route is built again.
enum SuppressedControls {
    /// The key lives on `TrafficControl` itself, so the route plan, the
    /// rehearsal and this ribbon all name a crossed off stop the same way and
    /// cannot disagree about which ones are still in force.
    static func key(for control: TrafficControl) -> String { control.suppressionKey }
}

// MARK: - The expensive half, worked out once

/// The part of the reading that a crossing off cannot change.
///
/// Densifying the line to 5 m, reading a posted limit onto every one of those
/// points and running the curvature profile is the whole cost of this view,
/// and none of it depends on which stops are still in force. Crossing one off
/// changes which controls apply and nothing else, so this is held and only the
/// markers and the dips are worked out again.
///
/// A roundabout is the one exception: it is a stretch of slow road rather than
/// a halt, so it is baked into the ceiling. Crossing one off therefore has to
/// build this again, which is why the roundabouts are part of the key.
private struct RibbonBasis: Sendable {
    var key: String
    var profile: SpeedProfile
    var spans: [WalkingLegs.Span]
    var controls: [TrafficControl]
    /// Where the driving starts, which is where the clean start is measured
    /// from. See `SpeedProfile.cleanStartDistance`.
    var driveStarts: Double

    static func build(
        key: String,
        plan: RoutePlan,
        persona: DriverPersona,
        speedHelp: SpeedHelp,
        suppressingRoundabouts: Set<String>,
        seed: UInt64
    ) -> RibbonBasis {
        let profile = plan.speedProfile(
            persona: persona,
            speedHelp: speedHelp,
            suppressing: suppressingRoundabouts,
            seed: seed
        )
        let spans = profile.spans
        return RibbonBasis(
            key: key,
            profile: profile,
            spans: spans,
            controls: plan.metadata.snappedControls(to: profile.polyline),
            driveStarts: spans.first { $0.mode == .drive }?.start ?? 0
        )
    }
}

/// One held basis, because one route is on screen at a time.
///
/// An actor rather than anything on `AppModel`: the reading is built off the
/// main thread, and this also stops two builds of the same route racing each
/// other when the person changes driver and speed help in quick succession.
private actor RibbonBasisCache {
    static let shared = RibbonBasisCache()

    private var held: RibbonBasis?

    func basis(key: String, build: @Sendable () -> RibbonBasis) -> RibbonBasis {
        if let held, held.key == key { return held }
        let made = build()
        held = made
        return made
    }
}

// MARK: - What the drive actually does, as numbers

/// Everything the ribbon draws, worked out off the main thread.
///
/// No colours and no views live in here on purpose: this is the reading, and
/// the view decides how to paint it. That also keeps it `Sendable`.
struct RibbonReading: Sendable {
    /// One slice of the route, by distance.
    struct Sample: Sendable {
        var speed: Double
        var onFoot: Bool
    }

    /// A stretch of the route, as a fraction of the whole.
    struct Stretch: Sendable {
        var start: Double
        var end: Double
    }

    enum Kind: String, Sendable {
        case signal
        case stopSign
        case giveWay
        case crossing
        case roundabout
        case parking
        case boarding

        /// `nil` for the traffic light, which is drawn rather than set: there
        /// is no traffic light in the symbol set, and the nearest thing to one
        /// is a warning beacon that does not read as a light at this size.
        var symbolName: String? {
            switch self {
            case .signal: nil
            case .stopSign: "octagon.fill"
            case .giveWay: "triangle.fill"
            case .crossing: "figure.walk"
            case .roundabout: "arrow.clockwise"
            case .parking: "parkingsign"
            case .boarding: "car.fill"
            }
        }

        /// Roundabouts slow the car down rather than halting it, so they are
        /// not counted when the header says how many stops there are.
        var isAHalt: Bool { self != .roundabout }

        /// Which ones matter most when there is not room to draw them all.
        var weight: Int {
            switch self {
            case .parking, .boarding: 0
            case .stopSign: 1
            case .signal: 2
            case .roundabout: 3
            case .giveWay: 4
            case .crossing: 5
            }
        }
    }

    struct Marker: Identifiable, Sendable {
        var id: String
        /// Where it sits, 0 at the start of the route and 1 at the end.
        var fraction: Double
        var alongTrack: Double
        var kind: Kind
        var title: String
        var detail: String
        /// How often this one actually halts the car, 0 to 1. A stop sign and
        /// a parking handover are 1; a signal, a give way and a crossing are
        /// not, and the drive draws them again every time it runs.
        var probability: Double
        var suppressed: Bool
        /// The thing in the road data this came from. `nil` for the halt where
        /// the car is parked, which belongs to the walking leg rather than to
        /// anything on the road, and so cannot be crossed off by itself.
        var controlKey: String?

        var isCertain: Bool { probability >= 0.999 }
    }

    var length: Double = 0
    var samples: [Sample] = []
    var walkStretches: [Stretch] = []
    var markers: [Marker] = []
    /// The speed at the top of the band, in m/s.
    var scaleTop: Double = Speed.mph(30)
    var fastest: Double = 0
    var typical: Double = 0
    var walkingDistance: Double = 0
    var hasRoadData: Bool = true
    var isEntirelyOnFoot: Bool = false
    var isEmpty: Bool = true

    static let empty = RibbonReading()

    /// Stops that happen on every single drive.
    var certainHalts: Int {
        markers.filter { !$0.suppressed && $0.kind.isAHalt && $0.isCertain }.count
    }

    /// Stops that happen on some drives and not others.
    var chanceHalts: Int {
        markers.filter { !$0.suppressed && $0.kind.isAHalt && !$0.isCertain && $0.probability > 0 }.count
    }

    var hasSuppressed: Bool {
        markers.contains { $0.suppressed }
    }

    var hasUncertain: Bool {
        markers.contains { !$0.suppressed && !$0.isCertain }
    }

    /// The same information as the picture, said out loud.
    var spoken: String {
        guard !isEmpty else { return "No route drawn yet." }
        var parts: [String] = ["Speed along the route, \(RibbonFormat.distance(length))."]
        if isEntirelyOnFoot {
            parts.append("The whole way is on foot at about \(RibbonFormat.mph(typical)) miles an hour.")
        } else {
            parts.append("Typically \(RibbonFormat.mph(typical)) miles an hour, at most \(RibbonFormat.mph(fastest)).")
            if walkingDistance > 0 {
                parts.append("\(RibbonFormat.distance(walkingDistance)) of it on foot.")
            }
        }
        let certain = certainHalts
        let chance = chanceHalts
        if certain == 0, chance == 0 {
            parts.append("Nothing on the route stops you.")
        } else {
            parts.append("\(certain) places it stops every drive, and \(chance) it might stop at.")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Building the reading

extension RibbonReading {
    /// The same seed the rehearsal uses, so the two cards describe one drive
    /// rather than two different draws of it. Doubles as the name of the plan
    /// for the held basis, since it is built from the ends of the line and how
    /// many points are in it.
    static func identity(of plan: RoutePlan) -> UInt64 {
        let points = plan.polyline.points
        guard let first = points.first, let last = points.last else { return 1 }
        let signature = String(
            format: "%.4f,%.4f>%.4f,%.4f@%d",
            first.latitude, first.longitude,
            last.latitude, last.longitude,
            points.count
        )
        return UInt64(bitPattern: Int64(signature.hashValue))
    }

    static func make(
        plan: RoutePlan,
        persona: DriverPersona,
        speedHelp: SpeedHelp,
        suppressed: Set<String>
    ) async -> RibbonReading {
        guard plan.polyline.points.count > 1, plan.polyline.length > 5 else { return .empty }

        let seed = identity(of: plan)
        // A roundabout is baked into the ceiling rather than being a halt, so
        // crossing one off is the only removal that invalidates the basis.
        let roundabouts = suppressed.filter { $0.hasPrefix(TrafficControlKind.roundabout.rawValue + "@") }
        let help = "\(speedHelp.isEnabled)-\(speedHelp.mode.rawValue)-\(speedHelp.profile.rawValue)-\(Int(speedHelp.manualMaxMph))"
        let key = "\(seed)/\(persona.id)/\(help)/\(roundabouts.sorted().joined(separator: ","))"

        let basis = await RibbonBasisCache.shared.basis(key: key) {
            RibbonBasis.build(
                key: key,
                plan: plan,
                persona: persona,
                speedHelp: speedHelp,
                suppressingRoundabouts: roundabouts,
                seed: seed
            )
        }

        return assemble(basis: basis, persona: persona, plan: plan, suppressed: suppressed)
    }

    /// The cheap half. Runs again on every crossing off.
    private static func assemble(
        basis: RibbonBasis,
        persona: DriverPersona,
        plan: RoutePlan,
        suppressed: Set<String>
    ) -> RibbonReading {
        let profile = basis.profile
        let length = profile.polyline.length
        guard length > 5, !profile.ceiling.isEmpty else { return .empty }

        let markers = self.markers(basis: basis, persona: persona, suppressed: suppressed)

        let bucketCount = max(24, min(180, Int(length / 20)))
        let braking = max(0.5, min(persona.braking, persona.acceleration))
        // Only the halts still in force bend the speed down, and each one only
        // as far as it actually happens: a light that stops the car on a bit
        // over half of drives digs a bit over half a dip.
        let halts: [(at: Double, chance: Double)] = markers
            .filter { !$0.suppressed && $0.kind.isAHalt && $0.probability > 0 }
            .map { (at: $0.alongTrack, chance: $0.probability) }

        var samples: [Sample] = []
        samples.reserveCapacity(bucketCount)
        for index in 0..<bucketCount {
            let low = length * Double(index) / Double(bucketCount)
            let high = length * Double(index + 1) / Double(bucketCount)
            let mid = (low + high) / 2
            let onFoot = profile.mode(at: mid).isOnFoot
            var speed = (profile.speed(at: low) + profile.speed(at: mid) + profile.speed(at: high)) / 3
            let rate = onFoot ? 1.2 : braking
            for halt in halts {
                let full = (2 * rate * abs(halt.at - mid)).squareRoot()
                guard full < speed else { continue }
                speed -= (speed - full) * halt.chance
            }
            samples.append(Sample(speed: max(0, speed), onFoot: onFoot))
        }

        let onFootOnly = !samples.contains { !$0.onFoot }
        let fastest = samples.map(\.speed).max() ?? 0
        let moving = samples.map(\.speed).filter { $0 > Speed.mph(1) }
        let typical = moving.isEmpty ? 0 : moving.reduce(0, +) / Double(moving.count)
        let floorTop = onFootOnly ? Speed.mph(4) : Speed.mph(30)

        let stretches = basis.spans
            .filter { $0.mode.isOnFoot }
            .map { Stretch(start: $0.start / length, end: min(1, $0.end / length)) }

        var reading = RibbonReading()
        reading.length = length
        reading.samples = samples
        reading.walkStretches = stretches
        reading.markers = markers
        reading.scaleTop = max(floorTop, fastest * 1.08)
        reading.fastest = fastest
        reading.typical = typical
        reading.walkingDistance = profile.walkingDistance
        reading.hasRoadData = !plan.metadata.segments.isEmpty && !plan.metadata.wasFallback
        reading.isEntirelyOnFoot = onFootOnly
        reading.isEmpty = false
        return reading
    }

    // MARK: Markers

    /// How often each thing on the road actually stops the car.
    ///
    /// These are not copied any more. `StopOdds` in CloakKit is the one place
    /// they are written down, and `SpeedProfileBuilder.build` rolls against
    /// the same constants, so the picture and the drive cannot drift apart at
    /// all rather than only drifting apart without a comment.
    private typealias Odds = StopOdds

    private static func markers(
        basis: RibbonBasis,
        persona: DriverPersona,
        suppressed: Set<String>
    ) -> [Marker] {
        let profile = basis.profile
        let length = profile.polyline.length
        guard length > 0 else { return [] }

        var output: [Marker] = []

        // Where the car is parked and where it is picked up again, off the
        // seams between modes: the same places the profile builder puts its
        // handover halts. These happen on every drive.
        var handovers: [Double] = []
        let spans = basis.spans
        if spans.count > 1 {
            for index in 1..<spans.count {
                let leaving = spans[index - 1].mode
                let arriving = spans[index].mode
                let at = max(0, spans[index].start - SpeedProfileBuilder.handoverSetback)
                guard at > 10, at < length - 10 else { continue }
                let kind: Kind
                let detail: String
                if leaving == .drive, arriving.isOnFoot {
                    kind = .parking
                    detail = "The car is parked here and you carry on on foot. Every drive."
                } else if leaving.isOnFoot, arriving == .drive {
                    kind = .boarding
                    detail = "You get back into the car here. Every drive."
                } else {
                    kind = .parking
                    detail = "The trip changes from \(leaving.displayName.lowercased()) to \(arriving.displayName.lowercased()) here."
                }
                handovers.append(at)
                output.append(Marker(
                    id: "handover-\(Int(at))",
                    fraction: at / length,
                    alongTrack: at,
                    kind: kind,
                    title: kind == .boarding ? "Back in the car" : "Parking",
                    detail: detail,
                    probability: 1,
                    suppressed: false,
                    controlKey: nil
                ))
            }
        }

        let redPercent = percent(persona.redLightProbability)
        let signalLow = Int(persona.signalDwellRange.lowerBound.rounded())
        let signalHigh = Int(persona.signalDwellRange.upperBound.rounded())
        let stopLow = Int(persona.stopSignDwellRange.lowerBound.rounded())
        let stopHigh = Int(persona.stopSignDwellRange.upperBound.rounded())
        let cleanStartEnds = basis.driveStarts + SpeedProfile.cleanStartDistance

        for (index, control) in basis.controls.enumerated() {
            let here = profile.mode(at: control.alongTrack)
            // On foot there are no lights to obey and no lane to hold, so
            // everything except a crossing does nothing there at all. Drawing
            // it would be drawing a stop that never happens.
            if !here.obeysTrafficControl, control.kind != .crossing { continue }
            // A halt right where the car is being parked is the same halt
            // written twice, and the profile builder drops it for that reason.
            if handovers.contains(where: { abs($0 - control.alongTrack) < SpeedProfileBuilder.handoverClearance }) { continue }
            // The builder throws away any halt in the first or last ten metres
            // of the line. A roundabout is not a halt and keeps its slow road.
            if control.kind != .roundabout, control.alongTrack < 10 || control.alongTrack > length - 10 { continue }

            let kind: Kind
            let title: String
            var detail: String
            var chance: Double
            switch control.kind {
            case .signal:
                kind = .signal
                title = "Traffic light"
                chance = persona.redLightProbability
                detail = "Red on about \(redPercent) drives in 100, then a wait of \(signalLow) to \(signalHigh) seconds."
            case .stop:
                kind = .stopSign
                title = "Stop sign"
                chance = 1
                detail = "Stops every drive, for \(stopLow) to \(stopHigh) seconds."
            case .giveWay:
                kind = .giveWay
                title = "Give way"
                chance = Odds.giveWay
                detail = "Slows every drive, and comes to a halt on about \(percent(Odds.giveWay)) of them."
            case .crossing:
                kind = .crossing
                if here.obeysTrafficControl {
                    chance = control.isSignalled ? Odds.signalledCrossing : Odds.plainCrossing
                    title = control.isSignalled ? "Signalled crossing" : "Crossing"
                    detail = control.isSignalled
                        ? "Holds the car on about \(percent(Odds.signalledCrossing)) of drives while people cross."
                        : "Holds the car on about \(percent(Odds.plainCrossing)) of drives. Almost never."
                } else {
                    chance = Odds.crossingOnFoot
                    title = "Crossing"
                    detail = "You wait for a gap on about \(percent(Odds.crossingOnFoot)) of trips."
                }
            case .roundabout:
                kind = .roundabout
                title = "Roundabout"
                chance = 1
                detail = "No halt, but the car slows to about 15 mph through it."
            }

            // The first stretch of a drive is kept clean on purpose, so that a
            // watching app sees an unbroken run of movement and calls it
            // driving. Nothing but a stop sign halts the car inside it.
            if here == .drive, control.kind != .stop, control.kind != .roundabout,
               control.alongTrack < cleanStartEnds {
                chance = 0
                detail = "Inside the clean start, so this one never halts the drive. The first \(RibbonFormat.distance(SpeedProfile.cleanStartDistance)) of driving is left unbroken on purpose."
            }

            let key = control.suppressionKey
            output.append(Marker(
                id: "\(index)-\(key)",
                fraction: min(1, control.alongTrack / length),
                alongTrack: control.alongTrack,
                kind: kind,
                title: title,
                detail: detail,
                probability: chance,
                suppressed: suppressed.contains(key),
                controlKey: key
            ))
        }

        output.sort { $0.alongTrack < $1.alongTrack }
        return output
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))"
    }
}

// MARK: - Formatting

enum RibbonFormat {
    static func distance(_ metres: Double) -> String {
        let miles = metres / 1609.34
        if miles < 0.2 { return String(format: "%.0f ft", metres * 3.28084) }
        return String(format: "%.1f mi", miles)
    }

    static func mph(_ metresPerSecond: Double) -> String {
        String(Int(Speed.toMph(metresPerSecond).rounded()))
    }
}

// MARK: - The colour ramp

/// Slow to fast, in the colours the app already owns.
///
/// The order follows the one every traffic map uses: red is not moving, amber
/// is crawling, green is getting on with it, teal is an open road. It is
/// labelled in the legend regardless, because a colour on its own is not an
/// explanation.
enum SpeedRamp {
    struct Anchor {
        var speed: Double
        var color: Color
    }

    /// Fixed speed bands, the same on every route, shared by the ribbon and
    /// the line on the map.
    ///
    /// The old bands only reached red under about six miles an hour, so a
    /// drive through town at thirty drew green from end to end and the map
    /// looked as if it had no colours at all. Red now holds through anything
    /// under twenty, which is stop and go, turns and side streets; amber is
    /// town driving; green is a main road; teal is open road.
    static let anchors: [Anchor] = [
        Anchor(speed: Speed.mph(0), color: Palette.danger),
        Anchor(speed: Speed.mph(18), color: Palette.danger),
        Anchor(speed: Speed.mph(30), color: Palette.warn),
        Anchor(speed: Speed.mph(45), color: Palette.ok),
        Anchor(speed: Speed.mph(62), color: Palette.accent)
    ]

    /// The anchors broken into components once, so a hundred and eighty bars
    /// cost that many lerps rather than that many colour space conversions.
    static func table() -> [(speed: Double, red: Double, green: Double, blue: Double)] {
        anchors.map { anchor in
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            UIColor(anchor.color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return (anchor.speed, Double(red), Double(green), Double(blue))
        }
    }

    static func color(
        _ speed: Double,
        table: [(speed: Double, red: Double, green: Double, blue: Double)]
    ) -> Color {
        guard let first = table.first, let last = table.last else { return Palette.accent }
        if speed <= first.speed { return Color(red: first.red, green: first.green, blue: first.blue) }
        if speed >= last.speed { return Color(red: last.red, green: last.green, blue: last.blue) }
        for index in 1..<table.count where speed <= table[index].speed {
            let low = table[index - 1]
            let high = table[index]
            let span = high.speed - low.speed
            let t = span > 0 ? (speed - low.speed) / span : 0
            return Color(
                red: low.red + (high.red - low.red) * t,
                green: low.green + (high.green - low.green) * t,
                blue: low.blue + (high.blue - low.blue) * t
            )
        }
        return Color(red: last.red, green: last.green, blue: last.blue)
    }

    static var swatch: LinearGradient {
        LinearGradient(colors: anchors.map(\.color), startPoint: .leading, endPoint: .trailing)
    }
}

// MARK: - The ribbon

/// The whole drive as one strip: how fast, where it slows, where it stops and
/// what stops it, which parts are on foot, and which of the stops are a
/// certainty rather than a chance.
///
/// Speed is drawn twice over, as height and as colour, so it still reads
/// without colour vision and still reads in bright sun. Everything the picture
/// says is also written underneath in words.
struct RouteRibbon: View {
    let plan: RoutePlan

    @Environment(AppModel.self) private var model

    @State private var reading = RibbonReading.empty
    @State private var selection: String?
    /// The pending regrade of the cards below, so crossing several stops off
    /// in a row costs one. Deliberately not cancelled when the view goes away:
    /// the cards it is bringing back in line outlive this one.
    @State private var regrade: Task<Void, Never>?

    private static let bandHeight: CGFloat = 58
    private static let markerSize: CGFloat = 26
    private static let markerGap: CGFloat = 27
    /// How long to wait for the person to stop crossing stops off before
    /// regrading the cards below. Six taps in a row cost one regrade.
    private static let regradeSettle = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if reading.isEmpty {
                placeholder
            } else {
                band
                ends
                legend
                notes
                detail
            }
        }
        .task(id: inputKey) { await rebuild() }
    }

    // MARK: Inputs

    /// Everything the reading depends on, as one value the task can watch.
    private var inputKey: String {
        let help = "\(model.speedHelp.isEnabled)-\(model.speedHelp.mode.rawValue)-\(model.speedHelp.profile.rawValue)-\(Int(model.speedHelp.manualMaxMph))"
        let crossed = model.suppressedControls.sorted().joined(separator: "|")
        return [
            String(RibbonReading.identity(of: plan)),
            model.persona.id,
            help,
            crossed
        ].joined(separator: "/")
    }

    private func rebuild() async {
        let plan = plan
        let persona = model.persona
        let speedHelp = model.speedHelp
        let crossed = model.suppressedControls
        let built = await Task.detached(priority: .userInitiated) {
            await RibbonReading.make(plan: plan, persona: persona, speedHelp: speedHelp, suppressed: crossed)
        }.value
        reading = built
        if let selection, !built.markers.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("What the drive does")
                .font(.label(13, weight: .semibold))
                .foregroundStyle(Palette.dim)
            Spacer(minLength: 4)
            Text(headline)
                .font(.label(12))
                .foregroundStyle(Palette.faint)
        }
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        guard !reading.isEmpty else { return "" }
        if reading.isEntirelyOnFoot { return "All on foot" }
        let certain = reading.certainHalts
        let chance = reading.chanceHalts
        var text: String
        if certain == 0, chance == 0 {
            text = "No stops"
        } else if chance == 0 {
            text = certain == 1 ? "1 stop" : "\(certain) stops"
        } else {
            text = "\(certain) stops, \(chance) maybe"
        }
        if reading.walkingDistance > 0 {
            text += ", \(RibbonFormat.distance(reading.walkingDistance)) on foot"
        }
        return text
    }

    private var placeholder: some View {
        Text("There is not enough of a route here to draw yet.")
            .font(.label(12))
            .foregroundStyle(Palette.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
    }

    // MARK: Band

    private var band: some View {
        GeometryReader { geo in
            let placement = Self.place(reading.markers, width: geo.size.width)
            ZStack(alignment: .topLeading) {
                RibbonBand(reading: reading, selection: selection)
                    .frame(height: Self.bandHeight)

                ForEach(placement.placed) { placed in
                    marker(placed)
                        .offset(x: placed.x - Self.markerSize / 2, y: Self.bandHeight + 3)
                }
            }
        }
        .frame(height: Self.bandHeight + Self.markerSize + 3)
    }

    private func marker(_ placed: Placed) -> some View {
        Button {
            selection = selection == placed.marker.id ? nil : placed.marker.id
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            MarkerGlyph(
                kind: placed.marker.kind,
                certain: placed.marker.isCertain,
                suppressed: placed.marker.suppressed,
                selected: selection == placed.marker.id
            )
            // The glyph is 26 points because that is what fits between
            // neighbours along the band, but nothing stops the target being
            // 44 tall. The padding grows the tappable shape and the negative
            // padding gives the layout back, so nothing moves.
            .padding(.vertical, 9)
            .contentShape(.rect)
            .padding(.vertical, -9)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibleName(placed.marker)))
        .accessibilityHint(Text("Opens this stop so you can take it off the drive"))
    }

    private func accessibleName(_ marker: RibbonReading.Marker) -> String {
        var name = "\(marker.title), \(RibbonFormat.distance(marker.alongTrack)) in"
        if marker.suppressed {
            name += ", taken off the drive"
        } else if marker.probability <= 0 {
            name += ", never halts this drive"
        } else if !marker.isCertain {
            name += ", on some drives only"
        }
        return name
    }

    private var ends: some View {
        HStack {
            Text("Start").font(.label(11)).foregroundStyle(Palette.faint)
            Spacer()
            Text("End").font(.label(11)).foregroundStyle(Palette.faint)
        }
        .accessibilityHidden(true)
    }

    // MARK: Legend

    private var legend: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !reading.isEntirelyOnFoot {
                legendRow(
                    swatch: AnyView(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(SpeedRamp.swatch)
                            .frame(width: 64, height: 9)
                    ),
                    text: "Stopped to \(RibbonFormat.mph(reading.scaleTop)) mph. Taller and greener is faster."
                )
            }

            if reading.walkingDistance > 0 {
                legendRow(
                    swatch: AnyView(
                        HatchSwatch()
                            .frame(width: 64, height: 9)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    ),
                    text: "Hatched is on foot, not driven."
                )
            }

            if reading.hasUncertain {
                legendRow(
                    swatch: AnyView(
                        HStack(spacing: 4) {
                            MarkerGlyph(kind: .stopSign, certain: true, suppressed: false, selected: false)
                                .scaleEffect(0.62)
                            MarkerGlyph(kind: .signal, certain: false, suppressed: false, selected: false)
                                .scaleEffect(0.62)
                        }
                        .frame(width: 64, height: 18)
                    ),
                    text: "Solid markers stop you every drive. Faded ones happen on some drives, not every drive, so their dips are drawn shallower."
                )
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func legendRow(swatch: AnyView, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            swatch
            Text(text)
                .font(.label(11))
                .foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var notes: some View {
        if !reading.hasRoadData {
            note("No road data came back for this area, so the speeds are read off the road types Apple Maps gave, and nothing is known here about lights or signs.")
        } else if reading.markers.isEmpty {
            note("Nothing on this route stops you. No lights, signs or crossings were found on it.")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.label(11))
            .foregroundStyle(Palette.faint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Selected stop

    private var selectedMarker: RibbonReading.Marker? {
        guard let selection else { return nil }
        return reading.markers.first { $0.id == selection }
    }

    @ViewBuilder
    private var detail: some View {
        if let marker = selectedMarker {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    stepper("chevron.left", offset: -1)

                    MarkerGlyph(
                        kind: marker.kind,
                        certain: marker.isCertain,
                        suppressed: marker.suppressed,
                        selected: true
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(marker.suppressed ? "\(marker.title), taken off" : marker.title)
                            .font(.label(14, weight: .medium))
                            .foregroundStyle(.white)
                        Text("\(RibbonFormat.distance(marker.alongTrack)) in. \(marker.detail)")
                            .font(.label(11))
                            .foregroundStyle(Palette.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 4)

                    stepper("chevron.right", offset: 1)
                }

                removal(marker)
            }
            .padding(10)
            .background(Palette.raised.opacity(0.5), in: .rect(cornerRadius: 12, style: .continuous))
        } else if !reading.markers.isEmpty {
            HStack(spacing: 6) {
                Text("Tap a marker to see what it is, or to say you do not stop there.")
                    .font(.label(11))
                    .foregroundStyle(Palette.faint)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if reading.hasSuppressed { restoreAll }
            }
        }
    }

    @ViewBuilder
    private func removal(_ marker: RibbonReading.Marker) -> some View {
        if let key = marker.controlKey {
            Button {
                toggle(key)
            } label: {
                Label(
                    marker.suppressed ? "Put this one back" : "I do not stop here",
                    systemImage: marker.suppressed ? "arrow.uturn.backward" : "minus.circle.fill"
                )
            }
            .buttonStyle(QuietButtonStyle(tint: marker.suppressed ? .white : Palette.danger))
        } else {
            Text("This one is the walking leg, not something on the road. Change the walk to move it.")
                .font(.label(11))
                .foregroundStyle(Palette.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var restoreAll: some View {
        Button {
            for marker in reading.markers {
                if let key = marker.controlKey { model.suppressedControls.remove(key) }
            }
            scheduleRegrade()
        } label: {
            Text("Put all back")
                .font(.label(11, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .lineLimit(1)
                .padding(.horizontal, Metrics.tight)
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .padding(.horizontal, -Metrics.tight)
    }

    private func toggle(_ key: String) {
        if model.suppressedControls.contains(key) {
            model.suppressedControls.remove(key)
        } else {
            model.suppressedControls.insert(key)
        }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        scheduleRegrade()
    }

    /// Bring the believability and rehearsal cards back in line with what was
    /// just crossed off.
    ///
    /// Nothing else does this: `routeInputsChanged` is called when the driver,
    /// the mode or the speed help change, and a crossing off is none of those.
    /// Without it the ribbon says five stops and the card under it says six.
    /// It is held back a moment because regrading is not free and crossing off
    /// several in a row is the expected way to use this.
    private func scheduleRegrade() {
        regrade?.cancel()
        regrade = Task {
            try? await Task.sleep(for: .milliseconds(Self.regradeSettle))
            guard !Task.isCancelled else { return }
            model.routeInputsChanged(needsNewRoute: false)
        }
    }

    private func stepper(_ symbol: String, offset: Int) -> some View {
        Button {
            step(offset)
        } label: {
            Image(systemName: symbol)
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(Palette.dim)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .accessibilityLabel(Text(offset < 0 ? "Previous stop" : "Next stop"))
    }

    private func step(_ offset: Int) {
        let markers = reading.markers
        guard !markers.isEmpty else { return }
        guard let current = markers.firstIndex(where: { $0.id == selection }) else {
            selection = markers.first?.id
            return
        }
        let next = (current + offset + markers.count) % markers.count
        selection = markers[next].id
    }

    // MARK: Marker placement

    struct Placed: Identifiable {
        var id: String { marker.id }
        let marker: RibbonReading.Marker
        /// Where the glyph is drawn, which is not always where the stop is:
        /// two lights fifty metres apart are one glyph apart on screen and
        /// have to be pushed off each other. The tick on the band above is
        /// always at the true place.
        let x: CGFloat
    }

    struct Placement {
        var placed: [Placed] = []
        var hidden: Int = 0
    }

    /// Lays the glyphs out left to right, pushes them off each other, then
    /// pulls the overflow back from the right hand end.
    static func place(_ markers: [RibbonReading.Marker], width: CGFloat) -> Placement {
        let inset = markerSize / 2 + 1
        guard width > inset * 2, !markers.isEmpty else { return Placement() }

        let span = width - inset * 2
        let capacity = max(1, Int(span / markerGap) + 1)

        var chosen = markers
        var hidden = 0
        if chosen.count > capacity {
            // Too many to draw. Keep the ones that matter most; the ticks
            // still show every one of them and the arrows in the panel still
            // reach them.
            let order = chosen.enumerated().sorted { left, right in
                if left.element.kind.weight != right.element.kind.weight {
                    return left.element.kind.weight < right.element.kind.weight
                }
                return left.offset < right.offset
            }
            let keep = Set(order.prefix(capacity).map(\.offset))
            hidden = chosen.count - capacity
            chosen = chosen.enumerated().filter { keep.contains($0.offset) }.map(\.element)
        }

        var positions = chosen.map { inset + CGFloat($0.fraction) * span }
        for index in positions.indices where index > 0 {
            positions[index] = max(positions[index], positions[index - 1] + markerGap)
        }
        for index in positions.indices.reversed() {
            let limit = index == positions.count - 1 ? width - inset : positions[index + 1] - markerGap
            positions[index] = min(positions[index], limit)
        }
        for index in positions.indices {
            positions[index] = max(positions[index], inset)
        }

        var placed: [Placed] = []
        placed.reserveCapacity(chosen.count)
        for (index, marker) in chosen.enumerated() {
            placed.append(Placed(marker: marker, x: positions[index]))
        }
        return Placement(placed: placed, hidden: hidden)
    }
}

// MARK: - The band itself

/// The strip. Drawn in one canvas rather than a few hundred views.
private struct RibbonBand: View {
    let reading: RibbonReading
    let selection: String?

    private struct Bar {
        var x: Double
        var width: Double
        var height: Double
        var color: Color
    }

    private struct Tick {
        var x: Double
        var suppressed: Bool
        var selected: Bool
        var certain: Bool
        var short: Bool
    }

    var body: some View {
        let bars = self.bars()
        let ticks = self.ticks()
        let walks = reading.walkStretches

        Canvas { context, size in
            Self.draw(bars: bars, ticks: ticks, walks: walks, context: context, size: size)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .accessibilityElement()
        .accessibilityLabel(Text(reading.spoken))
    }

    private func bars() -> [Bar] {
        let samples = reading.samples
        guard !samples.isEmpty else { return [] }
        let table = SpeedRamp.table()
        let top = max(reading.scaleTop, 0.1)
        let step = 1.0 / Double(samples.count)
        var output: [Bar] = []
        output.reserveCapacity(samples.count)
        for (index, sample) in samples.enumerated() {
            let colour = sample.onFoot ? Palette.floating : SpeedRamp.color(sample.speed, table: table)
            output.append(Bar(
                x: Double(index) * step,
                width: step,
                height: min(1, sample.speed / top),
                color: colour
            ))
        }
        return output
    }

    private func ticks() -> [Tick] {
        reading.markers.map { marker in
            Tick(
                x: marker.fraction,
                suppressed: marker.suppressed,
                selected: marker.id == selection,
                certain: marker.isCertain,
                short: !marker.kind.isAHalt || marker.probability <= 0
            )
        }
    }

    private static func draw(
        bars: [Bar],
        ticks: [Tick],
        walks: [RibbonReading.Stretch],
        context: GraphicsContext,
        size: CGSize
    ) {
        let width = size.width
        let height = size.height
        guard width > 0, height > 0 else { return }

        context.fill(
            Path(CGRect(x: 0, y: 0, width: width, height: height)),
            with: .color(Palette.ground.opacity(0.55))
        )

        for walk in walks {
            let x0 = walk.start * width
            let x1 = max(x0 + 1, walk.end * width)
            let rect = CGRect(x: x0, y: 0, width: x1 - x0, height: height)
            context.fill(Path(rect), with: .color(Color.white.opacity(0.05)))
        }

        let usable = height - 3
        for bar in bars {
            let barHeight = max(2, bar.height * usable)
            let rect = CGRect(
                x: bar.x * width,
                y: height - barHeight,
                width: bar.width * width + 0.7,
                height: barHeight
            )
            context.fill(Path(rect), with: .color(bar.color))
        }

        for walk in walks {
            let x0 = walk.start * width
            let x1 = max(x0 + 1, walk.end * width)
            var sub = context
            sub.clip(to: Path(CGRect(x: x0, y: 0, width: x1 - x0, height: height)))
            sub.stroke(
                hatch(from: x0, to: x1, height: height),
                with: .color(Palette.dim.opacity(0.5)),
                lineWidth: 1
            )
        }

        for tick in ticks {
            let x = min(max(tick.x * width, 0.6), width - 0.6)
            let topY = tick.short ? height * 0.6 : 2
            var path = Path()
            path.move(to: CGPoint(x: x, y: topY))
            path.addLine(to: CGPoint(x: x, y: height - 1))
            if tick.suppressed {
                context.stroke(
                    path,
                    with: .color(Palette.faint.opacity(0.8)),
                    style: StrokeStyle(lineWidth: 1, dash: [2, 3])
                )
            } else if tick.certain {
                context.stroke(
                    path,
                    with: .color(Color.white.opacity(tick.selected ? 0.95 : 0.65)),
                    lineWidth: tick.selected ? 2.5 : 1.4
                )
            } else {
                // A chance rather than a certainty, so the line is a chance of
                // a line: dotted, and half the weight of one that always
                // happens.
                context.stroke(
                    path,
                    with: .color(Color.white.opacity(tick.selected ? 0.8 : 0.35)),
                    style: StrokeStyle(lineWidth: tick.selected ? 2 : 1, dash: [1.5, 2.5])
                )
            }
        }
    }

    static func hatch(from x0: Double, to x1: Double, height: Double) -> Path {
        var path = Path()
        var x = x0 - height
        while x < x1 {
            path.move(to: CGPoint(x: x, y: height))
            path.addLine(to: CGPoint(x: x + height, y: 0))
            x += 6
        }
        return path
    }
}

/// The on foot texture on its own, for the legend.
private struct HatchSwatch: View {
    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Palette.floating)
            )
            context.stroke(
                RibbonBand.hatch(from: 0, to: size.width, height: size.height),
                with: .color(Palette.dim.opacity(0.6)),
                lineWidth: 1
            )
        }
        .accessibilityHidden(true)
    }
}

// MARK: - One marker

/// Shape first, weight second, colour last.
///
/// A stop sign is an octagon, a give way is a triangle on its point, a
/// crossing is a person, a traffic light is three lights in a box: none of
/// that needs colour to be read. A stop that only happens on some drives is
/// hollow and dashed rather than solid, and one taken off the drive is struck
/// through.
private struct MarkerGlyph: View {
    let kind: RibbonReading.Kind
    let certain: Bool
    let suppressed: Bool
    let selected: Bool

    var body: some View {
        ZStack {
            Circle().fill(fill)
            Circle().strokeBorder(border, style: outline)
            glyph
                .font(.system(.caption2, weight: .bold))
                .foregroundStyle(suppressed ? Palette.faint : .white)
                .opacity(certain || suppressed ? 1 : 0.6)
            if suppressed {
                Capsule()
                    .fill(Palette.faint)
                    .frame(width: 17, height: 1.5)
                    .rotationEffect(.degrees(-45))
            }
        }
        .frame(width: 26, height: 26)
    }

    @ViewBuilder
    private var glyph: some View {
        if kind == .signal {
            TrafficLightGlyph()
        } else if kind == .giveWay {
            symbol.rotationEffect(.degrees(180))
        } else {
            symbol
        }
    }

    @ViewBuilder
    private var symbol: some View {
        if let name = kind.symbolName {
            Image(systemName: name)
        }
    }

    private var fill: Color {
        if suppressed { return Palette.raised.opacity(0.45) }
        return certain ? Palette.raised : Palette.raised.opacity(0.35)
    }

    private var outline: StrokeStyle {
        let width: CGFloat = selected ? 2 : 1
        return certain && !suppressed
            ? StrokeStyle(lineWidth: width)
            : StrokeStyle(lineWidth: width, dash: [2.5, 2])
    }

    private var border: Color {
        if suppressed { return Palette.hairline }
        if selected { return Palette.accent }
        switch kind {
        case .stopSign: return Palette.danger.opacity(0.8)
        case .signal: return Palette.warn.opacity(certain ? 0.8 : 0.55)
        case .parking, .boarding: return Palette.accent.opacity(0.7)
        default: return Palette.hairline
        }
    }
}

/// Three lights in a box.
///
/// There is no traffic light in the symbol set. The nearest thing is a warning
/// beacon, which at this size reads as a hazard rather than as a signal, so
/// this is drawn instead: unmistakable at any size, and it inherits whatever
/// colour the marker is using.
private struct TrafficLightGlyph: View {
    var body: some View {
        VStack(spacing: 1.2) {
            Circle().frame(width: 3, height: 3)
            Circle().frame(width: 3, height: 3)
            Circle().frame(width: 3, height: 3)
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .strokeBorder(lineWidth: 1)
        )
    }
}
