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
}

extension Font {
    static func readout(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    static func label(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

struct GlassCard: ViewModifier {
    var padding: CGFloat = 14
    var radius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
            )
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
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
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
            .padding(.vertical, 14)
            .background(tint.opacity(configuration.isPressed ? 0.75 : 1), in: .rect(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
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
                .font(.system(size: 16, weight: .semibold))
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
                        .font(.system(size: 14, weight: .semibold))
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
                    .font(.system(size: 12, weight: .semibold))
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
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(ok ? okTint : Palette.dim)
        }
    }
}
