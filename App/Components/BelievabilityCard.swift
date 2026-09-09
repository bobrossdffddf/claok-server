import SwiftUI
import CloakKit

/// Shows how convincing a plan looks, and what is wrong with it.
///
/// Every other product in this category sells realism as an adjective on a
/// landing page. This turns it into a number with reasons attached, which is
/// both more honest and more useful: it names the weak part and says what to
/// change.
struct BelievabilityCard: View {
    let reading: Believability
    @State private var expanded = false

    private var tint: Color {
        switch reading.score {
        case 80...: Palette.ok
        case 55..<80: Palette.warn
        default: Palette.danger
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.snug) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(spacing: Metrics.snug) {
                    ZStack {
                        Circle()
                            .stroke(Palette.raised, lineWidth: 4)
                            .frame(width: 42, height: 42)
                        Circle()
                            .trim(from: 0, to: CGFloat(reading.score) / 100)
                            .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 42, height: 42)
                        Text("\(reading.score)")
                            .font(.readout(14, weight: .bold))
                            .foregroundStyle(tint)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(reading.grade)
                            .font(.label(15, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(reading.isClean
                             ? "Nothing here stands out."
                             : "\(reading.tells.count) thing\(reading.tells.count == 1 ? "" : "s") worth knowing about")
                            .font(.label(12))
                            .foregroundStyle(Palette.dim)
                    }

                    Spacer(minLength: 0)

                    if !reading.isClean {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.dim)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                }
            }
            .buttonStyle(.plain)
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
        .padding(Metrics.card)
        .background(Palette.surface, in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
        )
    }

    private func tellRow(_ tell: Believability.Tell) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(colour(for: tell.severity))
                    .frame(width: 6, height: 6)
                Text(tell.title)
                    .font(.label(13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                Text("-\(tell.cost)")
                    .font(.readout(11))
                    .foregroundStyle(Palette.dim)
            }
            Text(tell.detail)
                .font(.label(12))
                .foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)
            Text(tell.fix)
                .font(.label(12))
                .foregroundStyle(Palette.accent)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Metrics.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.ground.opacity(0.5), in: .rect(cornerRadius: 12, style: .continuous))
    }

    private func colour(for severity: Believability.Tell.Severity) -> Color {
        switch severity {
        case .bad: Palette.danger
        case .weak: Palette.warn
        case .note: Palette.dim
        }
    }
}
