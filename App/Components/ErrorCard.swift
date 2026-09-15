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
                    .font(.system(.subheadline, weight: .semibold))
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
                            .font(.system(.caption2, weight: .bold))
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
                        .font(.system(.caption2, design: .monospaced))
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(compact ? .subheadline : .body, weight: .semibold))
                    .foregroundStyle(Palette.warn)

                VStack(alignment: .leading, spacing: 2) {
                    Text("No local network")
                        .font(.label(compact ? 14 : 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Cloak reaches iOS over a local network. On cellular, turn on Personal Hotspot and it makes one, no Wi-Fi needed. Or switch Wi-Fi on without joining anything.")
                        .font(.label(12))
                        .foregroundStyle(Palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button {
                    if let url = URL(string: "App-Prefs:INTERNET_TETHERING") { UIApplication.shared.open(url) }
                    else if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    Label("Turn on Hotspot", systemImage: "personalhotspot")
                        .font(.label(13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Palette.warn.opacity(0.9), in: .rect(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(Palette.ground)
                }
                .buttonStyle(.plain)

                Button {
                    if let url = URL(string: "App-Prefs:WIFI") { UIApplication.shared.open(url) }
                    else if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    Label("Wi-Fi", systemImage: "wifi")
                        .font(.label(13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.10), in: .rect(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(compact ? 12 : Metrics.regular)
        .background(Palette.warn.opacity(0.10), in: .rect(cornerRadius: Metrics.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                .strokeBorder(Palette.warn.opacity(0.3), lineWidth: 1)
        )
    }
}
