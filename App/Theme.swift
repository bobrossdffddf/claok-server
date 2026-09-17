import SwiftUI

// MARK: - Colour

/// Dark first, on purpose: this app is opened in a car at night as often as
/// anywhere else. The ramp is a real elevation ramp rather than one flat
/// surface, because in dark mode shadows do almost nothing and lightening the
/// surface is what actually reads as "closer to you".
enum Palette {
    static let ground = Color(red: 0.047, green: 0.063, blue: 0.082)
    static let surface = Color(red: 0.086, green: 0.110, blue: 0.137)
    static let raised = Color(red: 0.125, green: 0.157, blue: 0.188)
    static let floating = Color(red: 0.161, green: 0.196, blue: 0.231)
    static let hairline = Color.white.opacity(0.10)

    static let accent = Color(red: 0.231, green: 0.878, blue: 0.784)
    static let accentDeep = Color(red: 0.086, green: 0.639, blue: 0.573)
    static let warn = Color(red: 0.984, green: 0.702, blue: 0.325)
    static let danger = Color(red: 1.0, green: 0.420, blue: 0.435)
    static let ok = Color(red: 0.310, green: 0.878, blue: 0.588)

    /// Secondary and tertiary text as real tokens rather than the primary
    /// colour at low opacity, so contrast stays predictable over glass.
    static let dim = Color(red: 0.663, green: 0.702, blue: 0.741)
    /// Measured, not eyeballed: the old value sat at 3.4:1 on `floating` and
    /// 3.9:1 on `raised`, which is under the 4.5:1 small text needs. This one
    /// clears 4.5:1 on every surface in the ramp and still reads a step
    /// quieter than `dim`.
    static let faint = Color(red: 0.565, green: 0.612, blue: 0.667)

    static var backdrop: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.063, green: 0.082, blue: 0.106), ground],
            startPoint: .top, endPoint: .bottom)
    }

    static var accentFill: LinearGradient {
        LinearGradient(colors: [accent, accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Type

extension Font {
    /// Six steps, and every one of them anchored to a system text style so
    /// Dynamic Type works and the whole app scales together.
    ///
    /// Call sites pass a point size because they always have. Rather than
    /// honouring twenty different sizes, each one snaps to the nearest step of
    /// the scale, which is what collapses the old twenty-size sprawl into
    /// something that reads as one typeface being used deliberately.
    private static func step(for size: CGFloat) -> (Font.TextStyle, CGFloat) {
        switch size {
        case ..<11.5: (.caption2, 11)
        case ..<13.5: (.caption, 12)
        case ..<15.5: (.subheadline, 15)
        case ..<18.5: (.body, 17)
        case ..<24: (.title3, 20)
        case ..<30: (.title2, 22)
        default: (.largeTitle, 34)
        }
    }

    /// Numbers: monospaced digits so a speed or a countdown does not jitter.
    static func readout(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(step(for: size).0, design: .rounded, weight: weight).monospacedDigit()
    }

    /// Everything else.
    static func label(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(step(for: size).0, design: .rounded, weight: weight)
    }
}

// MARK: - Layout

enum Metrics {
    /// A 4pt rhythm. Nothing in the app is allowed to invent a gap.
    static let hair: CGFloat = 4
    static let tight: CGFloat = 8
    static let snug: CGFloat = 12
    static let regular: CGFloat = 16
    static let card: CGFloat = 16
    static let loose: CGFloat = 24
    static let wide: CGFloat = 32

    /// Four radii, concentric: a 14pt control inside 16pt of padding sits in a
    /// 20pt card, and a 20pt card inside a 28pt sheet.
    static let chip: CGFloat = 10
    static let radius: CGFloat = 14
    static let cardRadius: CGFloat = 20
    static let sheetRadius: CGFloat = 28
}

// MARK: - Surfaces

/// Liquid Glass where iOS has it, a material where it does not, and a solid
/// fill when the person has asked for less transparency.
///
/// Deliberately only ever used as a *background*. A previous build wrapped
/// button labels in `glassEffect` and iOS 26 quietly stopped delivering taps to
/// them; a background is not hit-tested, so this cannot come back.
struct LiquidSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var radius: CGFloat
    var tint: Color?

    func body(content: Content) -> some View {
        content.background {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            if reduceTransparency {
                shape.fill(Palette.surface)
                shape.strokeBorder(Palette.hairline, lineWidth: 1)
            } else if #available(iOS 26.0, *) {
                // Glass alone over a bright map leaves white glyphs floating on
                // whatever happens to be behind them. A thin scrim underneath
                // holds the contrast without killing the refraction.
                shape.fill(Palette.ground.opacity(0.55))
                    .glassEffect(tint.map { .regular.tint($0.opacity(0.24)) } ?? .regular,
                                 in: .rect(cornerRadius: radius, style: .continuous))
            } else {
                shape.fill(.ultraThinMaterial)
                shape.fill(Palette.surface.opacity(0.5))
                shape.strokeBorder(Palette.hairline, lineWidth: 1)
            }
        }
    }
}

struct CircleSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var tint: Color?

    func body(content: Content) -> some View {
        content.background {
            if reduceTransparency {
                Circle().fill(Palette.raised)
                Circle().strokeBorder(Palette.hairline, lineWidth: 1)
            } else if #available(iOS 26.0, *) {
                Circle().fill(Palette.ground.opacity(0.55))
                    .glassEffect(tint.map { .regular.tint($0.opacity(0.24)) } ?? .regular, in: .circle)
            } else {
                Circle().fill(.ultraThinMaterial)
                Circle().strokeBorder(Palette.hairline, lineWidth: 1)
            }
        }
    }
}

extension View {
    /// Floating chrome: the status pill, the map controls, the live header.
    func liquidSurface(radius: CGFloat = Metrics.cardRadius, tint: Color? = nil) -> some View {
        modifier(LiquidSurface(radius: radius, tint: tint))
    }

    func circleSurface(tint: Color? = nil) -> some View {
        modifier(CircleSurface(tint: tint))
    }

    /// A card in the content layer. Solid, because glass belongs above content
    /// and never inside a scrolling list.
    func card(padding: CGFloat = Metrics.card, radius: CGFloat = Metrics.cardRadius) -> some View {
        self
            .padding(padding)
            .background(Palette.surface, in: .rect(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
    }

    /// Kept for the call sites that grew up with it; now the same card.
    func glassCard(padding: CGFloat = Metrics.card, radius: CGFloat = Metrics.cardRadius) -> some View {
        card(padding: padding, radius: radius)
    }

    /// One shadow definition, two elevations, and none at all when the surface
    /// is sitting flat on the background.
    func lift(_ level: Elevation = .resting) -> some View {
        shadow(color: .black.opacity(level.opacity), radius: level.radius, x: 0, y: level.offset)
    }
}

enum Elevation {
    case flat
    case resting
    case floating

    var opacity: Double {
        switch self {
        case .flat: 0
        case .resting: 0.22
        case .floating: 0.34
        }
    }

    var radius: CGFloat {
        switch self {
        case .flat: 0
        case .resting: 12
        case .floating: 22
        }
    }

    var offset: CGFloat {
        switch self {
        case .flat: 0
        case .resting: 4
        case .floating: 10
        }
    }
}

struct GlassCard: ViewModifier {
    var padding: CGFloat = Metrics.card
    var radius: CGFloat = Metrics.cardRadius

    func body(content: Content) -> some View {
        content.card(padding: padding, radius: radius)
    }
}

// MARK: - Motion

extension Animation {
    /// The app's two speeds. Anything the finger drives gets `press`;
    /// everything else gets `settle`.
    static let press = Animation.snappy(duration: 0.22, extraBounce: 0.05)
    static let settle = Animation.smooth(duration: 0.32)
}

// MARK: - Text

/// A quiet section heading. Sentence case, not tracked-out capitals: a wall of
/// ALL CAPS eyebrows is the single most recognisable sign of a template.
struct Eyebrow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.label(15, weight: .semibold))
            .foregroundStyle(Palette.dim)
            .accessibilityAddTraits(.isHeader)
    }
}

struct Readout: View {
    let title: String
    let value: String
    var unit: String?
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.hair) {
            Text(title)
                .font(.label(12, weight: .medium))
                .foregroundStyle(Palette.faint)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.readout(20, weight: .bold))
                    .foregroundStyle(tint)
                if let unit {
                    Text(unit)
                        .font(.label(12))
                        .foregroundStyle(Palette.faint)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Buttons

/// The press state for anything that draws its own background and would
/// otherwise use `.plain`, which gives no feedback at all. It also stamps a
/// rectangular content shape over the whole label, so the gaps between a glyph
/// and its text are part of the target rather than dead space.
struct PressableStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .contentShape(.rect)
            .opacity(isEnabled ? (pressed ? 0.75 : 1) : 0.45)
            .scaleEffect(reduceMotion ? 1 : (pressed ? scale : 1))
            .animation(.press, value: pressed)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var tint: Color = Palette.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(isEnabled ? Palette.ground : Palette.faint)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background {
                RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                    .fill(isEnabled
                          ? (tint == Palette.accent ? AnyShapeStyle(Palette.accentFill) : AnyShapeStyle(tint))
                          : AnyShapeStyle(Palette.raised))
            }
            .opacity(configuration.isPressed ? 0.9 : 1)
            .lift(isEnabled && !configuration.isPressed ? .resting : .flat)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
            .animation(.press, value: configuration.isPressed)
            .contentShape(.rect(cornerRadius: Metrics.radius, style: .continuous))
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var tint: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.label(15, weight: .medium))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                Color.white.opacity(configuration.isPressed ? 0.14 : 0.07),
                in: .rect(cornerRadius: Metrics.radius, style: .continuous)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.98 : 1))
            .animation(.press, value: configuration.isPressed)
            .contentShape(.rect(cornerRadius: Metrics.radius, style: .continuous))
    }
}

/// Round map chrome. Pressed with a thumb, at arm's length, in a moving car,
/// so it is 48pt and it is never subtle.
///
/// On iOS 26 this is the system glass button style rather than a hand-built
/// glass background. Putting `glassEffect` behind a symbol ourselves refracted
/// the symbol along with the map and left an unreadable smear; the system
/// style composites the symbol above the material, which is the entire reason
/// Apple ships it.
struct CircleControl: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let symbol: String
    var tint: Color = .white
    var active: Bool = false
    var action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            Button(action: action) {
                glyph
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(active ? tint : Palette.ground)
            .lift(.floating)
        } else {
            LegacyCircleControl(symbol: symbol, tint: tint, active: active, action: action)
        }
    }

    private var glyph: some View {
        Image(systemName: symbol)
            .font(.system(.body, weight: .semibold))
            .foregroundStyle(active ? Palette.ground : tint)
            .frame(width: 26, height: 26)
            .padding(11)
    }
}

/// The same control below iOS 26, and whenever the person has asked for less
/// transparency.
private struct LegacyCircleControl: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let symbol: String
    var tint: Color = .white
    var active: Bool = false
    var action: () -> Void

    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(active ? Palette.ground : tint)
                .frame(width: 48, height: 48)
                .background {
                    Circle().fill(active ? AnyShapeStyle(tint) : AnyShapeStyle(Palette.raised.opacity(0.92)))
                    Circle().strokeBorder(Palette.hairline, lineWidth: 1)
                }
                .scaleEffect(reduceMotion ? 1 : (pressed ? 0.94 : 1))
                .animation(.press, value: pressed)
        }
        .buttonStyle(.plain)
        .contentShape(.circle)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
        .lift(.floating)
    }
}

// MARK: - Grouped rows

// The hand-drawn grouped `Section` that used to live here is gone. It had
// the same name as SwiftUI's, so inside any file that imported both, every
// `Section` quietly meant this one, and a real `List` section had to be
// spelled `SwiftUI.Section`. Nothing uses it now that the screens are
// native lists.

/// One row inside a `Section`. Leading glyph, title, optional subtitle,
/// trailing accessory, and never shorter than a 44pt touch target.
struct Row<Trailing: View>: View {
    let symbol: String
    let title: String
    var subtitle: String?
    var tint: Color = Palette.accent
    var showsDivider: Bool = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.snug) {
                ZStack {
                    RoundedRectangle(cornerRadius: Metrics.chip, style: .continuous)
                        .fill(tint.opacity(0.16))
                        .frame(width: 32, height: 32)
                    Image(systemName: symbol)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.label(17))
                        .foregroundStyle(.white)
                    if let subtitle {
                        Text(subtitle)
                            .font(.label(13))
                            .foregroundStyle(Palette.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: Metrics.tight)

                trailing
            }
            .padding(.horizontal, Metrics.regular)
            .padding(.vertical, Metrics.snug)
            .frame(minHeight: 44)

            if showsDivider {
                Rectangle()
                    .fill(Palette.hairline)
                    .frame(height: 0.5)
                    .padding(.leading, 60)
            }
        }
    }
}

extension Row where Trailing == EmptyView {
    init(symbol: String, title: String, subtitle: String? = nil, tint: Color = Palette.accent, showsDivider: Bool = true) {
        self.init(symbol: symbol, title: title, subtitle: subtitle, tint: tint, showsDivider: showsDivider) {
            EmptyView()
        }
    }
}

struct ActionRow: View {
    let symbol: String
    let title: String
    var subtitle: String?
    var tint: Color = Palette.accent
    var showsDivider: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Row(symbol: symbol, title: title, subtitle: subtitle, tint: tint, showsDivider: showsDivider) {
                Image(systemName: "chevron.right")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(Palette.faint)
            }
        }
        .buttonStyle(RowButtonStyle())
    }
}

struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.white.opacity(0.06) : .clear)
            .animation(.press, value: configuration.isPressed)
            .contentShape(.rect)
    }
}

/// True or not, at a glance. Shape as well as colour, so it still reads without
/// colour vision.
struct StatusDot: View {
    let ok: Bool
    var okTint: Color = Palette.ok

    var body: some View {
        ZStack {
            Circle().fill((ok ? okTint : Palette.faint).opacity(0.18)).frame(width: 24, height: 24)
            Image(systemName: ok ? "checkmark" : "exclamationmark")
                .font(.system(.caption2, weight: .black))
                .foregroundStyle(ok ? okTint : Palette.faint)
        }
        .accessibilityLabel(ok ? "Ready" : "Needs attention")
    }
}

// MARK: - Layout helpers

/// A row that wraps instead of running off the side of the phone.
///
/// Several places lay out a handful of small capsules whose number is not known
/// in advance. In an `HStack` the sixth one simply left the screen on a 320pt
/// phone; here it starts a new line.
struct WrapRow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, in: width)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, max(widest, 0)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, in: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, in width: CGFloat) -> [Line] {
        var rows: [Line] = []
        var line = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            if needed > width, !line.indices.isEmpty {
                rows.append(line)
                line = Line()
                line.indices = [index]
                line.width = size.width
                line.height = size.height
            } else {
                line.indices.append(index)
                line.width = needed
                line.height = max(line.height, size.height)
            }
        }
        if !line.indices.isEmpty { rows.append(line) }
        return rows
    }
}

// MARK: - Chrome

/// Floating map chrome. On iOS 26 every piece of glass in one of these blends
/// and animates together instead of each pane refracting on its own, which is
/// both how Apple says to do it and materially cheaper to draw.
struct Chrome<Content: View>: View {
    var spacing: CGFloat = Metrics.tight
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Native sheet vocabulary
//
// Everything below is additive. It exists so the main sheet can be built out
// of system components and still share one set of decisions: how tall the
// sheet rests, what floats over the map, what a search field and a pinned
// action look like. Nothing above this line depends on it.

/// The main sheet's heights, named once so the map and the sheet cannot
/// disagree about which one is "resting".
enum SheetHeight {
    /// Just the tab switch and whatever is running.
    static let peek: PresentationDetent = .fraction(0.16)
    /// Where the sheet sits by default. The map stays the larger half.
    static let resting: PresentationDetent = .fraction(0.42)
}

extension Font {
    /// A live number: a speed, a distance, a time. The only text in the app
    /// that is rounded, so it reads as an instrument rather than a label, and
    /// monospaced so it does not jitter as it changes.
    static func live(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        .system(style, design: .rounded, weight: weight).monospacedDigit()
    }
}

/// The surface the main sheet is drawn on, for anything that has to cover
/// scrolling content with the same material the sheet itself uses.
struct SheetSurface: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Palette.backdrop.opacity(0.5)
        }
    }
}

/// Below iOS 26: a floating control on a regular material, which is what the
/// system itself used over maps before Liquid Glass. With Reduce Transparency
/// it is an opaque fill instead.
struct MaterialFloatingButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var isEnabled
    /// Nil draws a circle.
    var radius: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius ?? 999, style: .continuous)
        return configuration.label
            .background {
                if reduceTransparency {
                    shape.fill(Color(.secondarySystemBackground))
                } else {
                    shape.fill(.regularMaterial)
                }
            }
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 4)
            .animation(.press, value: configuration.isPressed)
    }
}

extension View {
    /// Styles a `Button` that floats over the map: system Liquid Glass on iOS
    /// 26, a regular material on 17 through 25. Pass a radius for a rounded
    /// rectangle, or leave it nil for a circle.
    @ViewBuilder
    func floatingControl(radius: CGFloat? = nil) -> some View {
        if #available(iOS 26.0, *) {
            if let radius {
                self.buttonStyle(.glass).buttonBorderShape(.roundedRectangle(radius: radius))
            } else {
                self.buttonStyle(.glass).buttonBorderShape(.circle)
            }
        } else {
            self.buttonStyle(MaterialFloatingButtonStyle(radius: radius))
        }
    }
}

/// A round map control: one symbol, never smaller than 44 points, and a
/// system glass button where the system has one.
struct MapButton: View {
    let symbol: String
    /// A status colour for the glyph, only when the control means a status.
    var tint: Color?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(.body, weight: .semibold))
                // A concrete colour: inside a glass button the hierarchical
                // `.primary` resolves to the accent.
                .foregroundStyle(tint ?? Color.primary)
                .frame(width: glyphSide, height: glyphSide)
                .contentShape(.circle)
        }
        .floatingControl()
    }

    /// The glass style pads its label itself; the material fallback does not.
    private var glyphSide: CGFloat {
        if #available(iOS 26.0, *) { return 32 }
        return 48
    }
}

/// The frame of a search field in the sheet: a magnifying glass, the field,
/// then a spinner or a 44 point clear button. The field itself is passed in so
/// each call site keeps its own submit, change and keyboard behaviour.
struct SearchFieldBox<Field: View>: View {
    var isEmpty: Bool
    var isSearching: Bool
    var onClear: () -> Void
    @ViewBuilder var field: Field

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            field
                .textFieldStyle(.plain)
                .font(.body)
            if isSearching {
                ProgressView().controlSize(.small)
            } else if !isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, (isEmpty || isSearching) ? 10 : 0)
        .frame(minHeight: 44)
        .background(.fill.tertiary, in: .rect(cornerRadius: GroupedMetrics.searchRadius, style: .continuous))
    }
}

extension View {
    /// A `List` that sits on the sheet's material rather than on an opaque
    /// grouped background, with the top gap tightened so the first row is up
    /// against the tab switch.
    func sheetList() -> some View {
        self
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .listSectionSpacing(.compact)
            .contentMargins(.top, Metrics.tight, for: .scrollContent)
    }

    /// One action pinned to the bottom of a scrolling tab, so it is on screen
    /// at every sheet height without scrolling past everything above it.
    @ViewBuilder
    func pinnedAction<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.hard, for: .bottom)
            .safeAreaBar(edge: .bottom) {
                bar()
                    .padding(.horizontal, Metrics.regular)
                    .padding(.vertical, Metrics.tight)
            }
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) {
                bar()
                    .padding(.horizontal, Metrics.regular)
                    .padding(.vertical, Metrics.tight)
                    .background(SheetSurface())
            }
        }
    }

    /// A grouped block outside a `List` that matches a `List` row group: the
    /// same hierarchical fill, so it picks up the sheet's vibrancy.
    func groupedBlock(padding: CGFloat = Metrics.regular) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: .rect(cornerRadius: GroupedMetrics.radius, style: .continuous))
    }
}

enum GroupedMetrics {
    /// The corner a grouped list section draws on this system.
    static var radius: CGFloat {
        if #available(iOS 26.0, *) { return 26 }
        return 12
    }

    /// A search field's corner: a capsule on iOS 26, where system search
    /// fields are capsules, and the older rounded rectangle before it. It also
    /// has to be no tighter than a grouped section's own corner, or a field
    /// placed in a list row has its corners cut off by the section.
    static var searchRadius: CGFloat {
        if #available(iOS 26.0, *) { return 22 }
        return 10
    }
}

/// `PrimaryButtonStyle` at control height, for a row that has other controls
/// in it: the same dark text on the accent, but a 44 point capsule sized to
/// its label instead of a full-width 50 point slab.
struct CompactPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var tint: Color = Palette.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(isEnabled ? Palette.ground : Palette.faint)
            .padding(.horizontal, Metrics.regular)
            .frame(minHeight: 44)
            .background {
                Capsule()
                    .fill(isEnabled
                          ? (tint == Palette.accent ? AnyShapeStyle(Palette.accentFill) : AnyShapeStyle(tint))
                          : AnyShapeStyle(Palette.raised))
            }
            .opacity(configuration.isPressed ? 0.9 : 1)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.96 : 1))
            .animation(.press, value: configuration.isPressed)
            .contentShape(.capsule)
    }
}

// MARK: - Map cards and rails
//
// The map screen's floating pieces: filled rows with a caption over a value,
// the square secondary button beside a primary one, and the surface a card is
// drawn on. Additive, like everything below the sheet vocabulary.

enum CardMetrics {
    /// The card's own corner. Large and continuous, so the card reads as a
    /// piece of the phone's rounded glass rather than a box laid on the map.
    static let radius: CGFloat = 30
    /// A filled row inside a card: concentric with the card at 16 points in.
    static let rowRadius: CGFloat = 16
    /// How far the card and the chrome sit from the screen's edges.
    static let inset: CGFloat = 12
    /// The inner padding of a card.
    static let padding: CGFloat = 16
}

/// The dark surface a floating card is drawn on: a material, darkened enough
/// that white text holds over a bright map, with a hairline edge. With Reduce
/// Transparency it is opaque.
struct CardSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: CardMetrics.radius, style: .continuous)
        return content
            .background {
                if reduceTransparency {
                    shape.fill(Palette.surface)
                } else {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(Palette.ground.opacity(0.62))
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 8)
    }
}

extension View {
    func cardSurface() -> some View { modifier(CardSurface()) }

    /// The fill of a row inside a card: one step lighter than the card.
    func cardRowFill(radius: CGFloat = CardMetrics.rowRadius) -> some View {
        background(Color.white.opacity(0.075), in: .rect(cornerRadius: radius, style: .continuous))
    }
}

/// The small label over a value in a card row. Upper case and quiet, the one
/// place in the app that uses it, because inside a filled row it reads as the
/// field name rather than as a heading.
struct RowCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(Color(.secondaryLabel))
            .lineLimit(1)
    }
}

/// A filled card row: an optional leading mark, a caption over a value with
/// an optional detail line, and a trailing accessory. Colours are named
/// outright because inside a button label the hierarchical styles resolve
/// against the tint.
struct CardRow<Leading: View, Trailing: View>: View {
    var caption: String?
    let value: String
    var detail: String?
    var valueColor: Color = Color(.label)
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Metrics.snug) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                if let caption { RowCaption(text: caption) }
                Text(value)
                    .font(.body)
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(Color(.secondaryLabel))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(minHeight: 52)
        // No fill of its own. Rows sit in a `CardGroup`, which is the one
        // surface; a filled box per row inside a card was box inside box.
        .contentShape(.rect)
    }
}

extension CardRow where Trailing == EmptyView {
    init(caption: String? = nil, value: String, detail: String? = nil, valueColor: Color = Color(.label), @ViewBuilder leading: () -> Leading) {
        self.init(caption: caption, value: value, detail: detail, valueColor: valueColor, leading: leading, trailing: { EmptyView() })
    }
}

extension CardRow where Leading == EmptyView, Trailing == EmptyView {
    init(caption: String? = nil, value: String, detail: String? = nil, valueColor: Color = Color(.label)) {
        self.init(caption: caption, value: value, detail: detail, valueColor: valueColor, leading: { EmptyView() }, trailing: { EmptyView() })
    }
}

/// The chevron at the end of a row that opens something.
struct RowChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color(.tertiaryLabel))
            .frame(width: 28)
            .accessibilityHidden(true)
    }
}

/// A coloured dot marking the start or the end of a route.
struct RouteDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2))
            .frame(width: 20)
            .accessibilityHidden(true)
    }
}

/// A 44 point icon button inside a row, for remove, share, replay and the like.
struct RowIconButton: View {
    let symbol: String
    var tint: Color = Color(.secondaryLabel)
    let label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .accessibilityLabel(label)
    }
}

/// The square button beside a wide primary one: same height, one symbol.
struct SquareIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .foregroundStyle(isEnabled ? Color(.label) : Color(.tertiaryLabel))
            .frame(width: 50, height: 50)
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.1), in: .rect(cornerRadius: Metrics.radius, style: .continuous))
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.95 : 1))
            .animation(.press, value: configuration.isPressed)
            .contentShape(.rect(cornerRadius: Metrics.radius, style: .continuous))
    }
}

/// A heading between groups inside a card.
struct CardSectionTitle<Accessory: View>: View {
    let text: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center) {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(.secondaryLabel))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Metrics.tight)
            accessory
        }
        .padding(.horizontal, Metrics.hair)
        .padding(.top, Metrics.hair)
    }
}

extension CardSectionTitle where Accessory == EmptyView {
    init(_ text: String) {
        self.init(text: text) { EmptyView() }
    }
}

enum TripFormat {
    /// "12 min", "1h 5m", "40s".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(total)s"
    }
}

/// A segmented choice for the map cards: each segment a word, optionally with
/// a symbol, and the chosen one filled with the accent in dark text.
///
/// The system segmented control cannot put a symbol and a word in one
/// segment, and its selected segment is a grey pill that on a dark card over a
/// map reads as barely different from the rest. This keeps its behaviour,
/// one choice, a selection tick, a selected trait for VoiceOver, and every
/// segment a 44 point target.
struct CardSegmentedPicker<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String
        var symbol: String?
        var id: String { title }
    }

    let label: String
    let options: [Option]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let chosen = option.value == selection
                Button {
                    guard !chosen else { return }
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(.press) { selection = option.value }
                } label: {
                    HStack(spacing: 5) {
                        if let symbol = option.symbol {
                            Image(systemName: symbol)
                                .font(.footnote.weight(.semibold))
                        }
                        Text(option.title)
                            .font(.subheadline.weight(chosen ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(Color(.label))
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background {
                        // Neutral, not the accent: a card has one accent
                        // fill, and it belongs to the primary button.
                        if chosen {
                            RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.2))
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.075), in: .rect(cornerRadius: 13, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}

// MARK: - Grouped rows in cards

/// Rows that belong together, on one rounded surface with hairlines between
/// them, the way an inset-grouped list draws a section. The rows themselves
/// have no fill: the group is the only surface inside a card.
struct CardGroup<Content: View>: View {
    var title: String?
    /// False for rows that sit straight on the card with only hairlines
    /// between them, when the card holds nothing but that one list.
    var filled = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.secondaryLabel))
                    .padding(.leading, 14)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(filled ? 0.07 : 0), in: .rect(cornerRadius: CardMetrics.groupRadius, style: .continuous))
            // Unfilled rows sit on the card itself, so they take back the
            // inset a group would have drawn around them.
            .padding(.horizontal, filled ? 0 : -Metrics.tight)
        }
    }
}

extension CardMetrics {
    /// A group of rows inside a card, concentric with the card at 16 in.
    static let groupRadius: CGFloat = 14
}

/// The hairline between two rows in a `CardGroup`, starting where the text
/// does.
struct GroupDivider: View {
    var inset: CGFloat = 14

    var body: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(height: 0.5)
            .padding(.leading, inset)
            .accessibilityHidden(true)
    }
}

/// A plain row in a group that does one thing: a grey symbol, a title in the
/// primary colour, and a chevron when it opens something.
struct GroupActionRow: View {
    let title: String
    let symbol: String
    var detail: String?
    var showsChevron = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            CardRow(value: title, detail: detail) {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(Color(.secondaryLabel))
                    .frame(width: 24)
            } trailing: {
                if showsChevron { RowChevron() }
            }
        }
        .buttonStyle(RowButtonStyle())
    }
}

/// A secondary button in a card: neutral fill, primary text, the same height
/// as the primary button beside or above it.
struct CardSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    /// A status colour for the label, for Stop. Nil is the primary text colour.
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(isEnabled ? (tint ?? Color(.label)) : Color(.tertiaryLabel))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.1), in: .rect(cornerRadius: Metrics.radius, style: .continuous))
            .contentShape(.rect(cornerRadius: Metrics.radius, style: .continuous))
            .animation(.press, value: configuration.isPressed)
    }
}

/// A round header button in a card: the close X, or the more menu. A 30
/// point grey circle inside a 44 point target.
struct CardHeaderGlyph: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.footnote.weight(.bold))
            .foregroundStyle(Color(.secondaryLabel))
            .frame(width: 30, height: 30)
            .background(Color.white.opacity(0.12), in: Circle())
            .frame(width: 44, height: 44)
            .contentShape(.rect)
    }
}
