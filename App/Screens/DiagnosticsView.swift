import SwiftUI
import UIKit
import CloakKit

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var testing = false
    @State private var testResult: String?
    @State private var surveying = false
    @State private var survey: String?
    @State private var showsRemotePairing = false
    @State private var showsErrorDetail = false

    private var smoothnessDetail: String {
        let fixes = model.snapshot.fixesLastMinute ?? 0
        let gap = model.snapshot.longestGapLastMinute ?? 0
        return "\(fixes) fixes in the last minute (60 is perfect), longest gap \(String(format: "%.1f", gap))s"
    }

    /// The parts of the smoothness reading that only appear when something is
    /// wrong. They are advice, so they sit under the list rather than in it.
    private var smoothnessWarnings: [String] {
        guard model.snapshot.isRunning, let fixes = model.snapshot.fixesLastMinute else { return [] }
        let push = model.snapshot.slowestPushLastMinute ?? 0
        var notes: [String] = []
        if push > 0.8 { notes.append("Slowest push \(String(format: "%.1f", push))s, so the tunnel is slow.") }
        if fixes < 50 { notes.append("iOS is pausing Cloak: check Location is allowed and Low Power Mode is off.") }
        return notes
    }

    private var backgroundOK: Bool {
        model.locationAuthorization == .authorizedAlways || model.locationAuthorization == .authorizedWhenInUse
    }

    private var backgroundDetail: String {
        switch model.locationAuthorization {
        case .authorizedAlways: "Location is Always, so a drive keeps moving while you use other apps"
        case .authorizedWhenInUse: "Location is While Using, which still keeps a running drive alive in the background"
        case .denied, .restricted: "Location is off for Cloak. Allow it in Settings"
        default: "Location has not been allowed yet. Start a drive and allow it when asked"
        }
    }

    private var backgroundWarning: String? {
        switch model.locationAuthorization {
        case .denied, .restricted: "Without location access iOS suspends Cloak the moment you switch apps and the drive stops."
        default: nil
        }
    }

    var body: some View {
        NavigationStack {
            List {
                summarySection

                if let seen = model.observedLocation {
                    observedSection(seen)
                }

                chainSection

                if !model.hasLocalNetwork {
                    localNetworkSection
                }

                if let message = model.snapshot.linkMessage {
                    errorSection(message)
                }

                actionsSection

                if let survey {
                    SwiftUI.Section("What pairing can see") {
                        Text(survey)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            UIPasteboard.general.string = survey
                            model.banner = "Copied."
                        } label: {
                            Label("Copy this", systemImage: "doc.on.doc")
                        }
                    }
                }

                if let testResult {
                    SwiftUI.Section("Tunnel self test") {
                        Text(testResult)
                            .font(.caption.monospaced())
                            .foregroundStyle(testResult.hasPrefix("PASS") ? Palette.ok : Palette.warn)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsRemotePairing, onDismiss: { model.refreshPairingState() }) {
            PairWithoutComputerView()
        }
    }

    // MARK: - Sections

    private var summarySection: some View {
        SwiftUI.Section {
            HStack(spacing: 12) {
                Image(systemName: overallSymbol)
                    .font(.title2)
                    .foregroundStyle(overallTint)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(overallTitle)
                        .font(.headline)
                    Text(overallSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }

    private func observedSection(_ seen: AppModel.ObservedLocation) -> some View {
        SwiftUI.Section {
            if let derived = seen.derivedSpeed {
                let mph = derived * 2.23694
                LabeledContent("Movement apps can see") {
                    Text(String(format: "%.0f mph", mph))
                        .monospacedDigit()
                        .foregroundStyle(mph >= 15 ? Palette.ok : Palette.warn)
                }
                if let course = seen.derivedCourse {
                    LabeledContent("Direction of travel", value: String(format: "%.0f°", course))
                }
            }
            LabeledContent("Speed field", value: seen.speed < 0 ? "-1" : String(format: "%.1f mph", seen.speed * 2.23694))
            LabeledContent("Heading field", value: seen.course < 0 ? "-1" : String(format: "%.0f°", seen.course))
            LabeledContent("Accuracy", value: String(format: "%@, %.0fs ago", Units.feet(seen.horizontalAccuracy), Date.now.timeIntervalSince(seen.timestamp)))
        } header: {
            Text("What iOS tells apps right now")
        } footer: {
            let note = observedFooter(seen)
            if !note.isEmpty {
                Text(note)
            }
        }
    }

    private func observedFooter(_ seen: AppModel.ObservedLocation) -> String {
        var parts: [String] = []
        if let derived = seen.derivedSpeed {
            parts.append(derived * 2.23694 >= 15
                ? "Above the 15 mph that Life360 uses to decide you are driving. It also wants about half a mile of this in a row, and it needs to be receiving location in the background."
                : "Below the 15 mph Life360 needs before it calls this a drive. Speed limits along the route, or a stop, are holding it here.")
        }
        if seen.speed < 0 {
            parts.append("The speed field reads -1 because iOS never fills it in for a simulated fix, with any tool. Every app works speed out from movement, as above.")
        }
        return parts.joined(separator: " ")
    }

    private var chainSection: some View {
        let warnings = smoothnessWarnings + [backgroundWarning].compactMap { $0 }
        return SwiftUI.Section {
            chainRow("Pairing", ok: model.hasAnyPairing, detail: pairingDetail)
            chainRow("Developer image", ok: model.hasDeveloperImage, detail: model.hasDeveloperImage ? "Cached on this device" : "Not transferred yet")
            chainRow("Tunnel", ok: model.snapshot.linkMessage == nil && model.snapshot.isRunning, detail: tunnelDetail)
            chainRow("Location service", ok: model.snapshot.isRunning && model.snapshot.linkMessage == nil, detail: model.snapshot.isRunning ? "Pushing fixes" : "Idle")
            chainRow("Keeps running in background", ok: backgroundOK, detail: backgroundDetail)
            if model.snapshot.isRunning, let fixes = model.snapshot.fixesLastMinute {
                chainRow("Smoothness", ok: fixes >= 50 && (model.snapshot.longestGapLastMinute ?? 0) < 2.5, detail: smoothnessDetail)
            }
        } header: {
            Text("The chain")
        } footer: {
            if !warnings.isEmpty {
                Text(warnings.joined(separator: " "))
            }
        }
    }

    /// The same two ways out as the shared Wi-Fi notice, laid out as rows.
    private var localNetworkSection: some View {
        SwiftUI.Section {
            Label {
                Text("No local network")
            } icon: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(Palette.warn)
            }

            Button {
                if let url = URL(string: "App-Prefs:INTERNET_TETHERING") { UIApplication.shared.open(url) }
                else if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                Label("Turn on Hotspot", systemImage: "personalhotspot")
            }

            Button {
                if let url = URL(string: "App-Prefs:WIFI") { UIApplication.shared.open(url) }
                else if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                Label("Wi-Fi", systemImage: "wifi")
            }
        } footer: {
            Text("Cloak reaches iOS over a local network. On cellular, turn on Personal Hotspot and it makes one, no Wi-Fi needed. Or switch Wi-Fi on without joining anything.")
        }
    }

    /// The shared error card, as rows: the plain sentence, the raw text behind
    /// a disclosure, and a copy action.
    private func errorSection(_ message: String) -> some View {
        let friendly = FriendlyError.make(message)
        return SwiftUI.Section {
            Label {
                Text(friendly.headline)
                    .font(.headline)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.warn)
            }

            DisclosureGroup(showsErrorDetail ? "Hide detail" : "Show detail", isExpanded: $showsErrorDetail) {
                Text(friendly.technical)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                UIPasteboard.general.string = friendly.technical
                model.banner = "Copied."
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        } footer: {
            Text(friendly.advice)
        }
    }

    private var actionsSection: some View {
        Group {
            SwiftUI.Section {
                Button {
                    showsRemotePairing = true
                } label: {
                    Label("Pair without a computer", systemImage: "iphone.radiowaves.left.and.right")
                }

                Button {
                    Task {
                        busy = true
                        await model.retryLink()
                        busy = false
                    }
                } label: {
                    ActionLabel(title: busy ? "Retrying" : "Retry the link", symbol: "arrow.clockwise", working: busy)
                }
                .disabled(busy)

                Button {
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
                } label: {
                    ActionLabel(title: testing ? "Testing the tunnel" : "Test the tunnel itself", symbol: "checkmark.shield", working: testing)
                }
                .disabled(testing)

                Button {
                    Task {
                        surveying = true
                        survey = await RemotePairingDiscovery.survey()
                        surveying = false
                    }
                } label: {
                    ActionLabel(title: surveying ? "Looking" : "Check what pairing can see", symbol: "dot.radiowaves.left.and.right", working: surveying)
                }
                .disabled(surveying)
            } footer: {
                Text("Cloak reaches iOS's own developer location service over a loopback connection to this phone. If the tunnel will not come up, the usual causes are Developer Mode being off, the developer image not being mounted, or a stale pairing record.")
            }

            SwiftUI.Section {
                Button(role: .destructive) {
                    model.clearPairing()
                } label: {
                    Label("Forget pairing record", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Detail

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
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(ok ? AnyShapeStyle(Palette.ok) : AnyShapeStyle(.secondary))
                .accessibilityLabel(ok ? "Working" : "Not yet")
        }
        .accessibilityElement(children: .combine)
    }
}

/// A list action that shows a spinner while it runs, so a disabled row still
/// says why it is disabled.
private struct ActionLabel: View {
    let title: String
    let symbol: String
    let working: Bool

    var body: some View {
        HStack {
            Label(title, systemImage: symbol)
                .modifier(ActionRowStyle())
            Spacer(minLength: 8)
            if working {
                ProgressView()
            }
        }
    }
}

/// A list action's label that greys out when the action is unavailable. Left
/// to itself a disabled list button kept a white title beside a teal glyph,
/// which reads as a live row.
private struct ActionRowStyle: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.foregroundStyle(isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.tertiaryLabel)))
    }
}
