import SwiftUI
import CloakKit

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var testing = false
    @State private var testResult: String?
    @State private var showsRemotePairing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summaryCard

                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow(text: "The chain")
                        chainRow("Pairing", ok: model.hasAnyPairing, detail: pairingDetail)
                        chainRow("Developer image", ok: model.hasDeveloperImage, detail: model.hasDeveloperImage ? "Cached on this device" : "Not transferred yet")
                        chainRow("Tunnel", ok: model.snapshot.linkMessage == nil && model.snapshot.isRunning, detail: tunnelDetail)
                        chainRow("Location service", ok: model.snapshot.isRunning && model.snapshot.linkMessage == nil, detail: model.snapshot.isRunning ? "Pushing fixes" : "Idle")
                    }

                    if !model.hasLocalNetwork {
                        WifiNotice(compact: true)
                    }

                    if let message = model.snapshot.linkMessage {
                        ErrorCard(raw: message) { model.banner = "Copied." }
                    }

                    VStack(spacing: 10) {
                        Button {
                            showsRemotePairing = true
                        } label: {
                            Label("Pair without a computer", systemImage: "iphone.radiowaves.left.and.right")
                        }
                        .buttonStyle(PrimaryButtonStyle())

                        Button(busy ? "Retrying" : "Retry the link") {
                            Task {
                                busy = true
                                await model.retryLink()
                                busy = false
                            }
                        }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(busy)

                        Button(testing ? "Testing the tunnel" : "Test the tunnel itself") {
                            Task {
                                testing = true
                                testResult = nil
                                do { try await model.startTunnelOnly() } catch {
                                    testResult = "Tunnel would not start: \(error.localizedDescription)"
                                    testing = false
                                    return
                                }
                                let reflector = await ReflectorTest.run()
                                let scan = await ServiceScan.run()
                                let rsd = await RsdProbe.run()
                                testResult = reflector + "\n\n" + scan + "\n\n" + rsd
                                testing = false
                            }
                        }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(testing)

                        Button("Forget pairing record") {
                            model.clearPairing()
                        }
                        .buttonStyle(QuietButtonStyle(tint: Palette.danger))
                    }

                    if let testResult {
                        VStack(alignment: .leading, spacing: 8) {
                            Eyebrow(text: "Tunnel self test")
                            Text(testResult)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(testResult.hasPrefix("PASS") ? Palette.ok : Palette.warn)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(14)
                        .background(Palette.surface, in: .rect(cornerRadius: 16, style: .continuous))
                    }

                    Text("Cloak reaches iOS's own developer location service over a loopback connection to this phone. If the tunnel will not come up, the usual causes are Developer Mode being off, the developer image not being mounted, or a stale pairing record.")
                        .font(.label(12))
                        .foregroundStyle(Palette.dim)
                }
                .padding(18)
            }
            .background(Palette.ground)
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Palette.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsRemotePairing, onDismiss: { model.refreshPairingState() }) {
            PairWithoutComputerView()
        }
    }

    private var pairingDetail: String {
        if model.hasRemotePairing { return "This phone paired with itself" }
        if model.hasPairing { return "Imported from a Mac" }
        return "Not paired yet"
    }

    private var tunnelDetail: String {
        if let message = model.snapshot.linkMessage { return message }
        if model.snapshot.reconnectCount > 0 { return "\(model.snapshot.reconnectCount) reconnects this session" }
        return model.snapshot.isRunning ? "Up" : "Comes up when you start simulating"
    }

    private var summaryCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(overallTint.opacity(0.18)).frame(width: 52, height: 52)
                Image(systemName: overallSymbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(overallTint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(overallTitle).font(.label(17, weight: .semibold)).foregroundStyle(.white)
                Text(overallSubtitle).font(.label(13)).foregroundStyle(Palette.dim)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Palette.surface, in: .rect(cornerRadius: 18, style: .continuous))
    }

    private var overallTint: Color {
        if model.snapshot.linkMessage != nil { return Palette.danger }
        if !model.hasAnyPairing || !model.hasDeveloperImage { return Palette.warn }
        return Palette.ok
    }

    private var overallSymbol: String {
        if model.snapshot.linkMessage != nil { return "exclamationmark.triangle.fill" }
        if !model.hasAnyPairing || !model.hasDeveloperImage { return "clock.badge.exclamationmark" }
        return "checkmark.shield.fill"
    }

    private var overallTitle: String {
        if model.snapshot.linkMessage != nil { return "Something is broken" }
        if !model.hasAnyPairing || !model.hasDeveloperImage { return "Setup incomplete" }
        return "Everything is in place"
    }

    private var overallSubtitle: String {
        if model.snapshot.linkMessage != nil { return "Read the error below and retry" }
        if !model.hasAnyPairing { return "This phone is not paired yet" }
        if !model.hasDeveloperImage { return "The developer image is missing" }
        return model.snapshot.isRunning ? "Simulating now" : "Ready when you are"
    }

    private func chainRow(_ title: String, ok: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dotted")
                .font(.system(size: 16))
                .foregroundStyle(ok ? Palette.ok : Palette.dim)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.label(15)).foregroundStyle(.white)
                Text(detail)
                    .font(.label(12))
                    .foregroundStyle(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Palette.surface.opacity(0.6), in: .rect(cornerRadius: 12, style: .continuous))
    }
}
