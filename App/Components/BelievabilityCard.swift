import SwiftUI
import CloakKit

/// Shows how convincing a plan looks, and what is wrong with it.
///
/// Every other product in this category sells realism as an adjective on a
/// landing page. This turns it into a number with reasons attached, which is
/// both more honest and more useful: it names the weak part and says what to
/// change.
///
/// A serious problem is never left behind a chevron. A card that scores badly
/// and says nothing about why until it is tapped is a card nobody taps, so
/// anything graded `bad` opens the list by itself and puts the worst of it on
/// a red strip across the top, where it cannot be read as decoration.
struct BelievabilityCard: View {
    let reading: Believability
    /// Nil until somebody opens or closes it themselves. Until then the card
    /// decides, and it decides to open when there is something serious.
    @State private var openedByHand: Bool?

    /// The tells that are enough on their own.
    private var serious: [Believability.Tell] {
        reading.tells.filter { $0.severity == .bad }
    }

    private var expanded: Bool { openedByHand ?? !serious.isEmpty }

    private var tint: Color {
        // `Believability` has no standing cap of its own; the guard above is
        // what makes a serious tell read red whatever the score says.
        if !serious.isEmpty { return Palette.danger }
        switch reading.score {
        case 80...: return Palette.ok
        case 55..<80: return Palette.warn
        default: return Palette.danger
        }
    }

    private var subtitle: String {
        if reading.isClean { return "Nothing here stands out." }
        if serious.isEmpty {
            return "\(reading.tells.count) thing\(reading.tells.count == 1 ? "" : "s") worth knowing about"
        }
        let rest = reading.tells.count - serious.count
        let head = serious.count == 1 ? "1 serious problem" : "\(serious.count) serious problems"
        return rest == 0 ? head : head + ", \(rest) smaller"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.snug) {
            if !serious.isEmpty { alarm }

            Button {
                withAnimation(.snappy(duration: 0.25)) { openedByHand = !expanded }
            } label: {
                HStack(spacing: Metrics.snug) {
                    ZStack {
                        Circle()
                            .stroke(.quaternary, lineWidth: 4)
                            .frame(width: 42, height: 42)
                        Circle()
                            .trim(from: 0, to: CGFloat(reading.score) / 100)
                            .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 42, height: 42)
                        Text("\(reading.score)")
                            .font(.live(.subheadline))
                            .foregroundStyle(tint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(reading.grade)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(serious.isEmpty ? Color.secondary : Palette.danger)
                    }

                    Spacer(minLength: 0)

                    if !reading.isClean {
                        Image(systemName: "chevron.down")
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(PressableStyle(scale: 0.99))
            .disabled(reading.isClean)

            if expanded {
                VStack(alignment: .leading, spacing: Metrics.snug) {
                    ForEach(reading.tells) { tell in
                        tellRow(tell)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // No card of its own: it is placed in a grouped list row, and the row
        // is the container. RouteTab tints that row red when anything here is
        // serious, so the alarm is carried by the whole group, not a border.
        .padding(.vertical, Metrics.hair)
    }

    /// The part that is meant to stop somebody starting the run.
    private var alarm: some View {
        HStack(alignment: .top, spacing: Metrics.tight) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Palette.ground)
            VStack(alignment: .leading, spacing: 2) {
                Text(serious.count == 1 ? "This will give you away" : "\(serious.count) things will give you away")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ground)
                Text(serious.map(\.title).joined(separator: ". "))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.ground.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Metrics.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.danger, in: .rect(cornerRadius: Metrics.radius, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func tellRow(_ tell: Believability.Tell) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: symbol(for: tell.severity))
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(colour(for: tell.severity))
                    .accessibilityLabel(name(for: tell.severity))
                Text(tell.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tell.severity == .bad ? Palette.danger : Color.primary)
                Spacer(minLength: 0)
                Text("-\(tell.cost)")
                    .font(.live(.caption2))
                    .foregroundStyle(.secondary)
            }
            Text(tell.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(tell.fix)
                .font(.caption)
                .foregroundStyle(.tint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Metrics.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (tell.severity == .bad ? AnyShapeStyle(Palette.danger.opacity(0.12)) : AnyShapeStyle(.fill.quaternary)),
            in: .rect(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tell.severity == .bad ? Palette.danger.opacity(0.45) : .clear, lineWidth: 1)
        )
    }

    private func colour(for severity: Believability.Tell.Severity) -> Color {
        switch severity {
        case .bad: Palette.danger
        case .weak: Palette.warn
        case .note: .secondary
        }
    }

    /// Shape as well as colour. Red and amber at six points across are the same
    /// dot to anyone who does not separate the two hues.
    private func symbol(for severity: Believability.Tell.Severity) -> String {
        switch severity {
        case .bad: "exclamationmark.triangle.fill"
        case .weak: "exclamationmark.circle.fill"
        case .note: "info.circle.fill"
        }
    }

    private func name(for severity: Believability.Tell.Severity) -> String {
        switch severity {
        case .bad: "Serious"
        case .weak: "Worth knowing"
        case .note: "Note"
        }
    }
}
