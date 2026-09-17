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
        VStack(alignment: .leading, spacing: Metrics.tight) {
            Label {
                Text(friendly.headline)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.warn)
            }

            Text(friendly.advice)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Metrics.loose) {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { showsDetail.toggle() }
                } label: {
                    Label {
                        Text(showsDetail ? "Hide detail" : "Show detail")
                    } icon: {
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(showsDetail ? 180 : 0))
                    }
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }

                Button {
                    UIPasteboard.general.string = friendly.technical
                    onCopy?()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }

                Spacer(minLength: 0)
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.borderless)

            if showsDetail {
                ScrollView(.vertical) {
                    Text(friendly.technical)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(Metrics.tight)
                .background(Palette.ground.opacity(0.6), in: .rect(cornerRadius: Metrics.chip, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        VStack(alignment: .leading, spacing: Metrics.snug) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No local network")
                        .font(compact ? .subheadline.weight(.semibold) : .headline)
                        .foregroundStyle(.primary)
                    Text("Cloak reaches iOS over a local network. On cellular, turn on Personal Hotspot and it makes one, no Wi-Fi needed. Or switch Wi-Fi on without joining anything.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(compact ? .subheadline.weight(.semibold) : .body.weight(.semibold))
                    .foregroundStyle(Palette.warn)
            }

            HStack(spacing: Metrics.tight) {
                Button {
                    if let url = URL(string: "App-Prefs:INTERNET_TETHERING") { UIApplication.shared.open(url) }
                    else if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    Label("Turn on Hotspot", systemImage: "personalhotspot")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Palette.warn, in: .rect(cornerRadius: Metrics.radius, style: .continuous))
                        .foregroundStyle(Palette.ground)
                        .contentShape(.rect(cornerRadius: Metrics.radius, style: .continuous))
                }
                .buttonStyle(PressableStyle())

                Button {
                    if let url = URL(string: "App-Prefs:WIFI") { UIApplication.shared.open(url) }
                    else if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    Label("Wi-Fi", systemImage: "wifi")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Palette.raised, in: .rect(cornerRadius: Metrics.radius, style: .continuous))
                        .foregroundStyle(.primary)
                        .contentShape(.rect(cornerRadius: Metrics.radius, style: .continuous))
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(compact ? Metrics.snug : Metrics.regular)
        .background(Palette.warn.opacity(0.10), in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .strokeBorder(Palette.warn.opacity(0.3), lineWidth: 1)
        )
    }
}
