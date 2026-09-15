import SwiftUI

enum Palette {
    static let ground = Color(red: 0.043, green: 0.059, blue: 0.078)
    static let surface = Color(red: 0.078, green: 0.106, blue: 0.133)
    static let raised = Color(red: 0.114, green: 0.149, blue: 0.180)
    static let hairline = Color(red: 0.180, green: 0.227, blue: 0.263)
    static let accent = Color(red: 0.231, green: 0.878, blue: 0.784)
    static let accentDeep = Color(red: 0.086, green: 0.639, blue: 0.573)
    static let warn = Color(red: 0.961, green: 0.647, blue: 0.141)
    static let danger = Color(red: 1.0, green: 0.353, blue: 0.373)
    static let ok = Color(red: 0.231, green: 0.878, blue: 0.541)
    static let dim = Color.white.opacity(0.55)

    /// A soft vertical wash for the app background, a touch of depth instead of
    /// one flat colour.
    static var backdrop: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.055, green: 0.075, blue: 0.098), ground],
            startPoint: .top, endPoint: .bottom)
    }

    /// The accent as a gradient, for primary buttons and the ring.
    static var accentFill: LinearGradient {
        LinearGradient(colors: [accent, accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Font {
    /// The text style whose default size is nearest the size a screen asked
    /// for. Every font in the app used to be a fixed point size, which means
    /// the Larger Text setting did nothing anywhere. Anchoring each size to a
    /// text style keeps the design at the default setting and lets it scale.
    private static func style(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<11.5: .caption2
        case ..<12.5: .caption
        case ..<14.5: .footnote
        case ..<15.5: .subheadline
        case ..<16.5: .callout
        case ..<19: .body
        case ..<21: .title3
        case ..<25: .title2
        case ..<31: .title
        default: .largeTitle
        }
    }

    static func readout(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(style(for: size), design: .rounded, weight: weight).monospacedDigit()
    }

    static func label(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(style(for: size), design: .rounded, weight: weight)
    }
}

struct GlassCard: ViewModifier {
    var padding: CGFloat = 14
    var radius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Palette.surface.opacity(0.92), in: .rect(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.03)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 8)
    }
}

extension View {
    func glassCard(padding: CGFloat = 14, radius: CGFloat = 18) -> some View {
        modifier(GlassCard(padding: padding, radius: radius))
    }
}

struct Eyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(.caption2, design: .rounded, weight: .semibold))
            .tracking(1.3)
            .foregroundStyle(Palette.dim)
    }
}

struct Readout: View {
    let title: String
    let value: String
    var unit: String?
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Eyebrow(text: title)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.readout(20))
                    .foregroundStyle(tint)
                if let unit {
                    Text(unit)
                        .font(.label(11))
                        .foregroundStyle(Palette.dim)
                }
            }
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Palette.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.label(16, weight: .semibold))
            .foregroundStyle(Palette.ground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(tint == Palette.accent
                          ? AnyShapeStyle(Palette.accentFill)
                          : AnyShapeStyle(tint))
                    .opacity(configuration.isPressed ? 0.8 : 1)
            }
            .shadow(color: tint.opacity(configuration.isPressed ? 0.1 : 0.35), radius: 10, x: 0, y: 4)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct QuietButtonStyle: ButtonStyle {
    var tint: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.label(15, weight: .medium))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.09), in: .rect(cornerRadius: 13, style: .continuous))
    }
}

struct CircleControl: View {
    let symbol: String
    var tint: Color = .white
    var active: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(active ? Palette.ground : tint)
                .frame(width: 44, height: 44)
                .background {
                    if active {
                        Circle().fill(tint)
                    } else {
                        Circle().fill(.ultraThinMaterial)
                        Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Layout

enum Metrics {
    /// One spacing scale, so nothing is eyeballed.
    static let tight: CGFloat = 8
    static let snug: CGFloat = 12
    static let regular: CGFloat = 16
    static let loose: CGFloat = 22
    static let card: CGFloat = 18
    static let radius: CGFloat = 16
    static let cardRadius: CGFloat = 20
}

/// A grouped section, the way iOS settings are grouped: a quiet header outside
/// the container, and the rows inside it sharing one surface with hairlines
/// between them rather than gaps.
struct Section<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.tight) {
            Eyebrow(text: title)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                content
            }
            .background(Palette.surface, in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            )

            if let footer {
                Text(footer)
                    .font(.label(12))
                    .foregroundStyle(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
            }
        }
    }
}

/// A single row inside a `Section`. Leading glyph, title, optional subtitle,
/// trailing accessory.
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
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tint.opacity(0.16))
                        .frame(width: 30, height: 30)
                    Image(systemName: symbol)
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.label(15))
                        .foregroundStyle(.white)
                    if let subtitle {
                        Text(subtitle)
                            .font(.label(12))
                            .foregroundStyle(Palette.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: Metrics.tight)

                trailing
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if showsDivider {
                Rectangle()
                    .fill(Palette.hairline.opacity(0.5))
                    .frame(height: 0.5)
                    .padding(.leading, 56)
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

/// A row that behaves as a button, with the chevron iOS users expect.
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
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Palette.dim)
            }
        }
        .buttonStyle(RowButtonStyle())
    }
}

struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.white.opacity(0.06) : .clear)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A status dot with a label, used wherever something is either true or not.
struct StatusDot: View {
    let ok: Bool
    var okTint: Color = Palette.ok

    var body: some View {
        ZStack {
            Circle().fill((ok ? okTint : Palette.dim).opacity(0.18)).frame(width: 22, height: 22)
            Image(systemName: ok ? "checkmark" : "exclamationmark")
                .font(.system(.caption2, weight: .black))
                .foregroundStyle(ok ? okTint : Palette.dim)
        }
    }
}

