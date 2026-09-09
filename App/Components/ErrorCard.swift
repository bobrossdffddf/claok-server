import SwiftUI
import CloakKit

/// One consistent way to show a failure: a plain sentence, what to do about it,
/// and the raw text tucked away for when it is genuinely needed.
struct ErrorCard: View {
    let raw: String
    var onCopy: (() -> Void)?

    @State private var showsDetail = false

    private var friendly: FriendlyError { FriendlyError.make(raw) }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.snug) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.warn)
                Text(friendly.headline)
                    .font(.label(16, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }

            Text(friendly.advice)
                .font(.label(14))
                .foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { showsDetail.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(showsDetail ? "Hide detail" : "Show detail")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(showsDetail ? 180 : 0))
                    }
                    .font(.label(12, weight: .semibold))
                    .foregroundStyle(Palette.dim)
                }
                .buttonStyle(.plain)

                Button {
                    UIPasteboard.general.string = friendly.technical
                    onCopy?()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.label(12, weight: .semibold))
                        .foregroundStyle(Palette.dim)
                }
                .buttonStyle(.plain)

                Spacer()
            }

            if showsDetail {
                ScrollView(.vertical) {
                    Text(friendly.technical)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.dim)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(10)
                .background(Palette.ground.opacity(0.6), in: .rect(cornerRadius: 10, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(Metrics.regular)
        .background(Palette.warn.opacity(0.09), in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .strokeBorder(Palette.warn.opacity(0.3), lineWidth: 1)
        )
    }
}

/// Shown wherever a missing Wi-Fi connection is about to stop something working.
struct WifiNotice: View {
    var compact = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: compact ? 15 : 18, weight: .semibold))
                .foregroundStyle(Palette.warn)

            VStack(alignment: .leading, spacing: 2) {
                Text("Wi-Fi is off")
                    .font(.label(compact ? 14 : 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Cloak cannot connect to iOS without it. It does not need to join a network, and Personal Hotspot works too.")
                    .font(.label(12))
                    .foregroundStyle(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(compact ? 12 : Metrics.regular)
        .background(Palette.warn.opacity(0.10), in: .rect(cornerRadius: Metrics.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                .strokeBorder(Palette.warn.opacity(0.3), lineWidth: 1)
        )
    }
}
