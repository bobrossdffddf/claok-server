import SwiftUI

// MARK: - Which sign

/// The road signs Cloak draws on the map, one per kind of stop on a route.
///
/// Drawn rather than bundled: these follow the public domain US MUTCD designs
/// (R1-1, R1-2, W3-3, W11-2, W2-6) closely enough to be recognised at a glance,
/// and a vector drawing stays sharp at any display scale and any zoom, where a
/// bitmap would have to be shipped at every size.
enum RoadSign: String, CaseIterable, Sendable {
    /// R1-1: red octagon, white border, white STOP.
    case stop
    /// R1-2: a red bordered white triangle standing on its point.
    case yield
    /// W3-3: the yellow diamond with a traffic light on it.
    case signalAhead
    /// W11-2: the yellow-green diamond with a person walking.
    case pedestrianCrossing
    /// W2-6: the yellow diamond with three arrows chasing round a circle.
    case roundabout
    /// The blue square with a white P, where the car is left.
    case parking
    /// A car on a plain square, where the walk ends and the drive picks up.
    case backInCar

    var accessibilityName: String {
        switch self {
        case .stop: "Stop sign"
        case .yield: "Give way sign"
        case .signalAhead: "Traffic light sign"
        case .pedestrianCrossing: "Pedestrian crossing sign"
        case .roundabout: "Roundabout sign"
        case .parking: "Parking sign"
        case .backInCar: "Back in the car sign"
        }
    }
}

// MARK: - The icon

/// One road sign, drawn to scale in a single canvas.
///
/// Built for 22 to 26 points on a map. Everything, lettering included, is
/// measured as a fraction of the sign rather than in points, so STOP always
/// fits its octagon exactly. Dynamic Type grows the whole sign a little and
/// then stops: past that point a bigger sign only covers the road it is
/// telling you about, and the words are said in full to VoiceOver anyway.
struct RoadSignIcon: View {
    enum Emphasis: Sendable {
        /// Happens on every drive.
        case certain
        /// Happens on some drives: drawn a step smaller and quieter, the way
        /// the ribbon fades the markers it is not sure of.
        case chance
        /// Taken off the drive by the person: grey and struck through, the
        /// same as on the ribbon.
        case crossedOff
    }

    let sign: RoadSign
    var size: CGFloat = 24
    var emphasis: Emphasis = .certain

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let side = (size * typeScale * emphasisScale).rounded()
        Canvas { context, canvasSize in
            Self.draw(sign, in: &context, side: min(canvasSize.width, canvasSize.height))
        }
        .frame(width: side, height: side)
        .saturation(emphasis == .crossedOff ? 0 : 1)
        .opacity(emphasisOpacity)
        .overlay {
            if emphasis == .crossedOff { strike(side) }
        }
        // One soft shadow for the whole sign, so it lifts off a pale park or a
        // white highway as well as off the dark streets.
        .compositingGroup()
        .shadow(color: .black.opacity(0.45), radius: 1.2, x: 0, y: 0.6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(sign.accessibilityName))
    }

    private var typeScale: CGFloat {
        if typeSize >= .accessibility1 { return 1.2 }
        if typeSize >= .xLarge { return 1.1 }
        return 1
    }

    private var emphasisScale: CGFloat {
        switch emphasis {
        case .certain: 1
        case .chance: 0.88
        case .crossedOff: 0.84
        }
    }

    private var emphasisOpacity: Double {
        switch emphasis {
        case .certain: 1
        case .chance: 0.8
        case .crossedOff: 0.6
        }
    }

    private func strike(_ side: CGFloat) -> some View {
        Capsule()
            .fill(Color(white: 0.92))
            .overlay(Capsule().strokeBorder(Color.black.opacity(0.7), lineWidth: 0.75))
            .frame(width: side * 1.2, height: max(2.5, side * 0.12))
            .rotationEffect(.degrees(-45))
    }
}

// MARK: - Drawing

extension RoadSignIcon {
    /// Standard sign colours, not the app palette: a stop sign is that red
    /// whatever colour the app happens to be.
    enum SignColor {
        static let red = Color(red: 0.757, green: 0.110, blue: 0.145)
        static let white = Color.white
        static let yellow = Color(red: 0.992, green: 0.788, blue: 0.075)
        static let yellowGreen = Color(red: 0.788, green: 0.886, blue: 0.086)
        static let black = Color(red: 0.07, green: 0.07, blue: 0.08)
        static let blue = Color(red: 0.0, green: 0.314, blue: 0.639)
        static let lensRed = Color(red: 0.93, green: 0.17, blue: 0.15)
        static let lensAmber = Color(red: 1.0, green: 0.62, blue: 0.05)
        static let lensGreen = Color(red: 0.10, green: 0.78, blue: 0.38)
        static let neutral = Color(red: 0.925, green: 0.933, blue: 0.945)
        static let neutralEdge = Color(red: 0.62, green: 0.65, blue: 0.69)
    }

    static func draw(_ sign: RoadSign, in context: inout GraphicsContext, side s: CGFloat) {
        guard s > 0 else { return }
        switch sign {
        case .stop: drawStop(&context, s)
        case .yield: drawYield(&context, s)
        case .signalAhead:
            drawWarningDiamond(&context, s, fill: SignColor.yellow)
            drawSignal(&context, s)
        case .pedestrianCrossing:
            drawWarningDiamond(&context, s, fill: SignColor.yellowGreen)
            drawWalker(&context, s)
        case .roundabout:
            drawWarningDiamond(&context, s, fill: SignColor.yellow)
            drawRoundabout(&context, s)
        case .parking: drawParking(&context, s)
        case .backInCar: drawCar(&context, s)
        }
    }

    // MARK: R1-1

    /// A regular octagon with a flat top, its flat sides touching a square of
    /// `apothem * 2`.
    static func octagon(center: CGPoint, apothem: CGFloat) -> Path {
        let radius = apothem / cos(.pi / 8)
        var path = Path()
        for index in 0..<8 {
            let angle = CGFloat.pi / 8 + CGFloat(index) * .pi / 4
            let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    private static func drawStop(_ context: inout GraphicsContext, _ s: CGFloat) {
        let center = CGPoint(x: s / 2, y: s / 2)
        context.fill(octagon(center: center, apothem: s / 2), with: .color(SignColor.red))
        // The white border sits just in from the edge, with a sliver of red
        // outside it, as on the real sign.
        let border = max(1, s * 0.05)
        context.stroke(
            octagon(center: center, apothem: s / 2 - s * 0.045 - border / 2),
            with: .color(SignColor.white),
            style: StrokeStyle(lineWidth: border, lineJoin: .miter)
        )
        drawFitted(
            "STOP",
            in: &context,
            center: CGPoint(x: s / 2, y: s / 2 + s * 0.01),
            width: s * 0.70,
            height: s * 0.34,
            weight: .heavy,
            color: SignColor.white
        )
    }

    /// Lettering scaled to a box on the sign rather than to Dynamic Type, so
    /// it can never outgrow the shape it is printed on.
    private static func drawFitted(
        _ string: String,
        in context: inout GraphicsContext,
        center: CGPoint,
        width: CGFloat,
        height: CGFloat,
        weight: Font.Weight,
        color: Color
    ) {
        func resolved(_ size: CGFloat) -> GraphicsContext.ResolvedText {
            context.resolve(
                Text(string)
                    .font(.system(size: size, weight: weight).width(.condensed))
                    .foregroundColor(color)
            )
        }
        var fontSize = height
        var text = resolved(fontSize)
        let measured = text.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        if measured.width > width, measured.width > 0 {
            fontSize *= width / measured.width
            text = resolved(fontSize)
        }
        context.draw(text, at: center, anchor: .center)
    }

    // MARK: R1-2

    private static func roundedPolygon(_ points: [CGPoint], radius: CGFloat) -> Path {
        var path = Path()
        guard points.count > 2 else { return path }
        let count = points.count
        let startMid = CGPoint(
            x: (points[count - 1].x + points[0].x) / 2,
            y: (points[count - 1].y + points[0].y) / 2
        )
        path.move(to: startMid)
        for index in 0..<count {
            let corner = points[index]
            let next = points[(index + 1) % count]
            path.addArc(tangent1End: corner, tangent2End: next, radius: radius)
        }
        path.closeSubpath()
        return path
    }

    private static func drawYield(_ context: inout GraphicsContext, _ s: CGFloat) {
        let height = s * 0.866
        let top = (s - height) / 2
        let outer = [
            CGPoint(x: 0, y: top),
            CGPoint(x: s, y: top),
            CGPoint(x: s / 2, y: top + height)
        ]
        context.fill(roundedPolygon(outer, radius: s * 0.06), with: .color(SignColor.red))
        // The white field is the same triangle at half size about the middle,
        // which leaves the border the proportion the real sign has.
        let centroid = CGPoint(x: s / 2, y: top + height / 3)
        let inner = outer.map { point in
            CGPoint(x: centroid.x + (point.x - centroid.x) * 0.5, y: centroid.y + (point.y - centroid.y) * 0.5)
        }
        context.fill(roundedPolygon(inner, radius: s * 0.02), with: .color(SignColor.white))
    }

    // MARK: Warning diamonds

    private static func diamond(_ s: CGFloat, inset: CGFloat, radius: CGFloat) -> Path {
        roundedPolygon([
            CGPoint(x: s / 2, y: inset),
            CGPoint(x: s - inset, y: s / 2),
            CGPoint(x: s / 2, y: s - inset),
            CGPoint(x: inset, y: s / 2)
        ], radius: radius)
    }

    private static func drawWarningDiamond(_ context: inout GraphicsContext, _ s: CGFloat, fill: Color) {
        context.fill(diamond(s, inset: 0, radius: s * 0.07), with: .color(fill))
        let border = max(0.9, s * 0.045)
        context.stroke(
            diamond(s, inset: s * 0.075 + border / 2, radius: s * 0.04),
            with: .color(SignColor.black),
            lineWidth: border
        )
    }

    /// W3-3: a signal head, red over amber over green.
    private static func drawSignal(_ context: inout GraphicsContext, _ s: CGFloat) {
        let housing = CGRect(x: s * 0.40, y: s * 0.265, width: s * 0.20, height: s * 0.47)
        context.fill(
            Path(roundedRect: housing, cornerRadius: s * 0.045, style: .continuous),
            with: .color(SignColor.black)
        )
        let lens = s * 0.125
        let colours = [SignColor.lensRed, SignColor.lensAmber, SignColor.lensGreen]
        for (index, colour) in colours.enumerated() {
            let centreY = s * 0.5 + CGFloat(index - 1) * s * 0.145
            let rect = CGRect(x: s / 2 - lens / 2, y: centreY - lens / 2, width: lens, height: lens)
            context.fill(Path(ellipseIn: rect), with: .color(colour))
        }
    }

    /// W11-2: a person mid stride, facing left.
    private static func drawWalker(_ context: inout GraphicsContext, _ s: CGFloat) {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
        let ink = GraphicsContext.Shading.color(SignColor.black)

        let head = s * 0.062
        context.fill(
            Path(ellipseIn: CGRect(x: p(0.50, 0.25).x - head, y: p(0.50, 0.25).y - head, width: head * 2, height: head * 2)),
            with: ink
        )

        var torso = Path()
        torso.move(to: p(0.485, 0.35))
        torso.addLine(to: p(0.515, 0.535))
        context.stroke(torso, with: ink, style: StrokeStyle(lineWidth: s * 0.11, lineCap: .round))

        var limbs = Path()
        // Leading leg, out in front.
        limbs.move(to: p(0.515, 0.54))
        limbs.addLine(to: p(0.455, 0.635))
        limbs.addLine(to: p(0.395, 0.735))
        // Trailing leg, pushing off.
        limbs.move(to: p(0.515, 0.54))
        limbs.addLine(to: p(0.565, 0.635))
        limbs.addLine(to: p(0.635, 0.715))
        // Arms swing against the legs.
        limbs.move(to: p(0.485, 0.37))
        limbs.addLine(to: p(0.555, 0.445))
        limbs.addLine(to: p(0.60, 0.515))
        limbs.move(to: p(0.485, 0.37))
        limbs.addLine(to: p(0.425, 0.445))
        limbs.addLine(to: p(0.385, 0.50))
        context.stroke(limbs, with: ink, style: StrokeStyle(lineWidth: s * 0.068, lineCap: .round, lineJoin: .round))
    }

    /// W2-6: three arrows running anticlockwise round a ring, the direction
    /// traffic goes round one in the US.
    private static func drawRoundabout(_ context: inout GraphicsContext, _ s: CGFloat) {
        let centre = CGPoint(x: s / 2, y: s / 2)
        let radius = s * 0.15
        let ink = GraphicsContext.Shading.color(SignColor.black)
        let sweep = CGFloat.pi * 0.42
        for index in 0..<3 {
            // Screen angles grow clockwise because y points down, so going
            // anticlockwise is going down in angle.
            let start = -CGFloat.pi / 2 + CGFloat(index) * 2 * .pi / 3 + sweep / 2
            let end = start - sweep
            var arc = Path()
            let steps = 12
            for step in 0...steps {
                let angle = start + (end - start) * CGFloat(step) / CGFloat(steps)
                let point = CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
                if step == 0 { arc.move(to: point) } else { arc.addLine(to: point) }
            }
            context.stroke(arc, with: ink, style: StrokeStyle(lineWidth: s * 0.062, lineCap: .butt, lineJoin: .round))

            let tipAngle = end
            let base = CGPoint(x: centre.x + radius * cos(tipAngle), y: centre.y + radius * sin(tipAngle))
            // Direction of travel at the end of the arc, and out from the ring.
            let forward = CGPoint(x: sin(tipAngle), y: -cos(tipAngle))
            let outward = CGPoint(x: cos(tipAngle), y: sin(tipAngle))
            let length = s * 0.10
            let half = s * 0.068
            var head = Path()
            head.move(to: CGPoint(x: base.x + forward.x * length, y: base.y + forward.y * length))
            head.addLine(to: CGPoint(x: base.x + outward.x * half, y: base.y + outward.y * half))
            head.addLine(to: CGPoint(x: base.x - outward.x * half, y: base.y - outward.y * half))
            head.closeSubpath()
            context.fill(head, with: ink)
        }
    }

    // MARK: Handovers

    private static func drawParking(_ context: inout GraphicsContext, _ s: CGFloat) {
        let rect = CGRect(x: 0, y: 0, width: s, height: s)
        context.fill(Path(roundedRect: rect, cornerRadius: s * 0.16, style: .continuous), with: .color(SignColor.blue))
        let border = max(0.9, s * 0.045)
        context.stroke(
            Path(roundedRect: rect.insetBy(dx: s * 0.07 + border / 2, dy: s * 0.07 + border / 2), cornerRadius: s * 0.1, style: .continuous),
            with: .color(SignColor.white),
            lineWidth: border
        )

        // The P as strokes rather than type, so its weight and position are
        // exact at every size.
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
        let weight = s * 0.12
        var stem = Path()
        stem.move(to: p(0.395, 0.235))
        stem.addLine(to: p(0.395, 0.775))
        context.stroke(stem, with: .color(SignColor.white), style: StrokeStyle(lineWidth: weight, lineCap: .butt))

        let bowlRadius = s * 0.138
        let bowlCentre = p(0.53, 0.435)
        var bowl = Path()
        bowl.move(to: CGPoint(x: s * 0.395, y: bowlCentre.y - bowlRadius))
        bowl.addLine(to: CGPoint(x: bowlCentre.x, y: bowlCentre.y - bowlRadius))
        bowl.addArc(center: bowlCentre, radius: bowlRadius, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        bowl.addLine(to: CGPoint(x: s * 0.395, y: bowlCentre.y + bowlRadius))
        context.stroke(bowl, with: .color(SignColor.white), style: StrokeStyle(lineWidth: weight, lineCap: .butt, lineJoin: .miter))
    }

    private static func drawCar(_ context: inout GraphicsContext, _ s: CGFloat) {
        let rect = CGRect(x: 0, y: 0, width: s, height: s)
        context.fill(Path(roundedRect: rect, cornerRadius: s * 0.2, style: .continuous), with: .color(SignColor.neutral))
        context.stroke(
            Path(roundedRect: rect.insetBy(dx: s * 0.03, dy: s * 0.03), cornerRadius: s * 0.17, style: .continuous),
            with: .color(SignColor.neutralEdge),
            lineWidth: max(0.75, s * 0.035)
        )

        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
        let ink = GraphicsContext.Shading.color(SignColor.black)
        let paper = GraphicsContext.Shading.color(SignColor.neutral)

        // Side on, facing right: body, cabin, two windows, two wheels.
        context.fill(
            Path(roundedRect: CGRect(x: s * 0.15, y: s * 0.455, width: s * 0.70, height: s * 0.2), cornerRadius: s * 0.07, style: .continuous),
            with: ink
        )
        context.fill(roundedPolygon([p(0.27, 0.47), p(0.36, 0.30), p(0.61, 0.30), p(0.74, 0.47)], radius: s * 0.04), with: ink)
        context.fill(roundedPolygon([p(0.34, 0.45), p(0.395, 0.345), p(0.48, 0.345), p(0.48, 0.45)], radius: s * 0.012), with: paper)
        context.fill(roundedPolygon([p(0.52, 0.45), p(0.52, 0.345), p(0.595, 0.345), p(0.67, 0.45)], radius: s * 0.012), with: paper)
        for x in [0.33, 0.67] {
            let centre = p(CGFloat(x), 0.665)
            let ring = s * 0.105
            let tyre = s * 0.07
            context.fill(Path(ellipseIn: CGRect(x: centre.x - ring, y: centre.y - ring, width: ring * 2, height: ring * 2)), with: paper)
            context.fill(Path(ellipseIn: CGRect(x: centre.x - tyre, y: centre.y - tyre, width: tyre * 2, height: tyre * 2)), with: ink)
        }
    }
}
