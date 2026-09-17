import SwiftUI
import CoreLocation
import CloakKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(LicenseController.self) private var licensing
    @Environment(\.dismiss) private var dismiss

    @State private var showsDiagnostics = false
    @State private var showsSigning = false
    @State private var showsPairing = false
    @State private var showsCellular = false
    @State private var showsExposure = false
    @State private var showsPaywall = false
    @State private var confirmsReset = false

    var body: some View {
        NavigationStack {
            List {
                // What used to float over the map as capsules. The map now
                // shows only a red dot on the settings button, and this is
                // where that dot leads.
                if !AttentionItem.current(model: model).isEmpty {
                    attentionSection
                }

                if !model.canRunInBackground {
                    backgroundSection
                }

                statusSection
                tunnelSection
                safetySection
                speedHelpSection
                drivingSection
                licenseSection
                setupSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsDiagnostics) { DiagnosticsView() }
        .sheet(isPresented: $showsSigning) { SigningView() }
        .sheet(isPresented: $showsCellular) { CellularView() }
        .sheet(isPresented: $showsExposure) { ExposureView() }
        // The map's own paywall sheet cannot present while Settings is itself
        // a sheet, so Settings needs one of its own.
        .sheet(isPresented: $showsPaywall) { PaywallView() }
        .sheet(isPresented: $showsPairing, onDismiss: { model.refreshPairingState() }) {
            PairWithoutComputerView()
        }
        .alert("Run setup again?", isPresented: $confirmsReset) {
            Button("Run setup", role: .destructive) {
                model.restartOnboarding()
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Cloak will walk you through Developer Mode, pairing and the tunnel again. Your pairing and saved places are kept.")
        }
    }

    // MARK: - Sections

    /// `Section` on its own is the app's hand-drawn card group from Theme, so
    /// every section here names the system one explicitly.
    private var backgroundSection: some View {
        SwiftUI.Section {
            SettingsLabel(
                title: "Simulation stops when you leave the app",
                subtitle: "Location access is \(authorizationName)",
                symbol: "exclamationmark.triangle.fill",
                symbolColor: Palette.warn)
            .accessibilityElement(children: .combine)

            Button {
                model.openLocationSettings()
            } label: {
                Label("Open Location settings", systemImage: "arrow.up.forward.app")
            }
        } footer: {
            Text("Without location access, iOS suspends Cloak the moment you switch apps and the drive stops. While Using the App is enough. It is currently \(authorizationName).")
        }
    }

    private var attentionSection: some View {
        SwiftUI.Section("Needs attention") {
            ForEach(AttentionItem.current(model: model)) { item in
                Button {
                    switch item {
                    case .link: showsDiagnostics = true
                    case .cellular: showsCellular = true
                    case .signing: showsSigning = true
                    case .trial:
                        TrialController.shared.paywallReason = nil
                        showsPaywall = true
                    }
                } label: {
                    HStack(spacing: 12) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .foregroundStyle(Color(.label))
                                Text(item.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(Color(.secondaryLabel))
                                    .lineLimit(2)
                            }
                        } icon: {
                            Image(systemName: item.symbol)
                                .foregroundStyle(Palette.danger)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color(.tertiaryLabel))
                    }
                }
            }
        }
    }

    private var statusSection: some View {
        SwiftUI.Section("Status") {
            SettingsRow(title: "Pairing", subtitle: pairingDetail, symbol: "link") {
                StatusMark(ok: model.hasAnyPairing)
            }
            SettingsRow(title: "Developer image", subtitle: DeveloperImageBundle.source, symbol: "externaldrive.fill") {
                StatusMark(ok: model.hasDeveloperImage)
            }
            SettingsRow(title: "Location access", subtitle: authorizationName, symbol: "location.fill") {
                StatusMark(ok: model.canRunInBackground)
            }
        }
    }

    private var tunnelSection: some View {
        let provider = model.reflector.provider
        let up = model.reflector.isUp

        return SwiftUI.Section {
            SettingsRow(
                title: provider == .localDevVPN ? "LocalDevVPN" : "Cloak's own tunnel",
                subtitle: up ? "Running" : "Not running",
                symbol: up ? "shield.lefthalf.filled" : "shield.slash"
            ) {
                StatusMark(ok: up)
            }

            if provider == .localDevVPN {
                if model.reflector.localDevVPNInstalled {
                    Button {
                        Task { _ = await model.ensureTunnelUp() }
                    } label: {
                        Label(up ? "Restart the tunnel" : "Turn the tunnel on", systemImage: "power")
                    }
                } else {
                    Button {
                        model.reflector.openAppStoreForLocalDevVPN()
                    } label: {
                        Label("Get LocalDevVPN, free", systemImage: "arrow.down.app")
                    }
                }
            } else if !up {
                Button {
                    Task { _ = await model.ensureTunnelUp() }
                } label: {
                    Label("Turn the tunnel on", systemImage: "power")
                }
            }
        } header: {
            Text("Tunnel")
        } footer: {
            Text(provider == .localDevVPN
                 ? "iOS will not answer a connection this phone makes to itself. LocalDevVPN loops it back so it does. It carries no internet traffic and Cloak only asks it to switch on."
                 : "Cloak's own loopback tunnel. Nothing is proxied and no traffic leaves this phone.")
        }
    }

    private var safetySection: some View {
        SwiftUI.Section {
            Toggle(isOn: Binding(
                get: { model.geofence.isEnabled },
                set: { model.setGeofenceEnabled($0) }
            )) {
                SettingsLabel(
                    title: "Geofence guard",
                    subtitle: "Stops if your real position leaves the area",
                    symbol: "shield.lefthalf.filled")
            }

            VStack(alignment: .leading, spacing: 4) {
                LabeledContent {
                    Text(Units.distance(model.geofence.radius))
                        .monospacedDigit()
                } label: {
                    Label("Radius", systemImage: "circle.dashed")
                        .labelStyle(SettingsIconLabelStyle())
                }
                Slider(
                    value: Binding(get: { model.geofence.radius }, set: { model.geofence.radius = $0 }),
                    in: 1000...200_000,
                    step: 1000
                )
                .accessibilityLabel("Geofence radius")
                .accessibilityValue(Units.distance(model.geofence.radius))
            }

            Button {
                model.saveGeofenceHere()
            } label: {
                Label("Centre it where I am", systemImage: "scope")
            }

            Button {
                Task { await model.peekRealLocation() }
            } label: {
                Label(model.isPeeking ? "Peeking" : "Peek at my real location", systemImage: "eye")
                    .modifier(ActionRowStyle())
            }
            .disabled(model.isPeeking)
        } header: {
            Text("Safety")
        } footer: {
            Text("Peeking clears the simulation for about two seconds, because iOS hands Cloak the same fake fix it gives every other app.")
        }
    }

    private var speedHelpSection: some View {
        SwiftUI.Section {
            Toggle(isOn: Binding(
                get: { model.speedHelp.isEnabled },
                set: { model.setSpeedHelp(model.speedHelp.with(isEnabled: $0)) }
            )) {
                SettingsLabel(title: "Speed help", subtitle: model.speedHelp.summary, symbol: "gauge.with.dots.needle.33percent")
            }

            if model.speedHelp.isEnabled {
                Picker("Mode", selection: Binding(
                    get: { model.speedHelp.mode },
                    set: { model.setSpeedHelp(model.speedHelp.with(mode: $0)) }
                )) {
                    Text("Auto").tag(SpeedHelp.Mode.auto)
                    Text("Manual").tag(SpeedHelp.Mode.manual)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch model.speedHelp.mode {
                case .auto:
                    ForEach(SpeedHelp.Profile.allCases) { profile in
                        let selected = model.speedHelp.profile == profile
                        Button {
                            model.setSpeedHelp(model.speedHelp.with(profile: profile))
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name)
                                        .foregroundStyle(Color(.label))
                                    Text(profile.detail)
                                        .font(.subheadline)
                                        .foregroundStyle(Color(.secondaryLabel))
                                }
                                Spacer(minLength: 8)
                                if selected {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }

                case .manual:
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent {
                            Text("\(Int(model.speedHelp.manualMaxMph.rounded())) mph")
                                .monospacedDigit()
                        } label: {
                            Label("Never above", systemImage: "speedometer")
                                .labelStyle(SettingsIconLabelStyle())
                        }
                        Slider(
                            value: Binding(
                                get: { model.speedHelp.manualMaxMph },
                                set: { model.setSpeedHelp(model.speedHelp.with(manualMaxMph: $0)) }
                            ),
                            in: 15...85,
                            step: 5
                        )
                        .accessibilityLabel("Never above")
                        .accessibilityValue("\(Int(model.speedHelp.manualMaxMph.rounded())) miles per hour")
                        Text("The road still applies. A 30 limit stays a 30 limit.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } footer: {
            Text("Sets how fast a simulated drive goes against the speed limit of each road it passes along, adjusting as the limits change. It shapes the drive Cloak plays back and does not read how the phone is really moving.")
        }
    }

    private var drivingSection: some View {
        SwiftUI.Section {
            Toggle(isOn: Binding(
                get: { model.pauseWhenCoverBreaks },
                set: { model.pauseWhenCoverBreaks = $0 }
            )) {
                SettingsLabel(
                    title: "Pause when cover breaks",
                    subtitle: model.pauseWhenCoverBreaks ? "Pauses if your connection stops matching the pin" : "Keeps reporting even when exposed",
                    symbol: "pause.circle")
            }

            VStack(alignment: .leading, spacing: 4) {
                LabeledContent {
                    Text(model.autoStopMinutes == 0 ? "Off" : "\(model.autoStopMinutes) min")
                        .monospacedDigit()
                } label: {
                    Label("Auto stop", systemImage: "timer")
                        .labelStyle(SettingsIconLabelStyle())
                }
                Slider(
                    value: Binding(
                        get: { Double(model.autoStopMinutes) },
                        set: { model.autoStopMinutes = Int($0) }
                    ),
                    in: 0...180,
                    step: 15
                )
                .accessibilityLabel("Auto stop")
                .accessibilityValue(model.autoStopMinutes == 0 ? "Off" : "\(model.autoStopMinutes) minutes")
            }
        } header: {
            Text("Driving")
        } footer: {
            Text("Auto stop ends a simulation on its own, so a drive left running does not carry on all day. Pause on cover break stops reporting the moment your connection no longer matches the pin, which is what happens when a VPN drops.")
        }
    }

    @ViewBuilder
    private var licenseSection: some View {
        if licensing.isEnforced {
            SwiftUI.Section {
                SettingsRow(title: "Licence", subtitle: licenseDetail, symbol: "key.fill") {
                    StatusMark(ok: licensing.isUnlocked)
                }

                Button(role: .destructive) {
                    Task { await licensing.release() }
                } label: {
                    Label("Release this phone", systemImage: "arrow.up.right.square")
                }
            } header: {
                Text("Licence")
            } footer: {
                Text("One licence covers one phone. Releasing it here frees it for another, and Cloak locks until a licence is entered again.")
            }
        }
    }

    private var setupSection: some View {
        Group {
            SwiftUI.Section("Setup") {
                SheetRow(title: "Signing", subtitle: signingSubtitle, symbol: "signature") {
                    showsSigning = true
                }
                SheetRow(
                    title: "Pairing",
                    subtitle: model.hasAnyPairing ? "Paired with this phone" : "Not paired yet",
                    symbol: "iphone.radiowaves.left.and.right"
                ) {
                    showsPairing = true
                }
                SheetRow(
                    title: "Cellular",
                    subtitle: CellularAssist.shared.learned.map { "Relinks with: \($0.title)" } ?? "Set up linking away from Wi-Fi",
                    symbol: "antenna.radiowaves.left.and.right"
                ) {
                    showsCellular = true
                }
                SheetRow(
                    title: "Exposure",
                    subtitle: "Where your connection comes out, your clock, your motion",
                    symbol: "eye.slash"
                ) {
                    showsExposure = true
                }
                SheetRow(title: "Diagnostics", subtitle: "See every step of the chain", symbol: "stethoscope") {
                    showsDiagnostics = true
                }
            }

            SwiftUI.Section {
                Button {
                    confirmsReset = true
                } label: {
                    Label("Run setup again", systemImage: "sparkles")
                }
            } footer: {
                Text("Walk through Developer Mode, pairing and the tunnel.")
            }
        }
    }

    private var signingSubtitle: String {
        guard let info = SignatureInfo.fromBundle() else { return "Keep Cloak signed" }
        if info.hasExpired { return "Expired, refresh now" }
        return "\(info.daysLeft) \(info.daysLeft == 1 ? "day" : "days") until it needs a refresh"
    }

    private var licenseDetail: String {
        guard let token = licensing.token else { return "Not activated" }
        return "Checked in, good for \(token.daysLeft) more days offline"
    }

    private var aboutSection: some View {
        SwiftUI.Section {
            LabeledContent("Version", value: versionText)
        } header: {
            Text("About")
        } footer: {
            Text("Nothing leaves this phone. No account, no analytics, no servers.")
        }
    }

    // MARK: - Detail

    private var pairingDetail: String {
        if model.hasRemotePairing { return "This phone paired with itself" }
        if model.hasPairing { return "Imported from a Mac" }
        return "Not paired yet"
    }

    private var authorizationName: String {
        switch model.locationAuthorization {
        case .authorizedAlways: "Always"
        case .authorizedWhenInUse: "While Using the App"
        case .denied: "Denied"
        case .restricted: "Restricted"
        default: "Not set"
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}

// MARK: - Rows

/// Title over a one line subtitle, with an optional leading symbol in the
/// accent colour. Plain text styles, so the row sizes with Dynamic Type.
private struct SettingsLabel: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    /// A status colour for the symbol, when the row is a warning. Otherwise
    /// the symbol takes the accent.
    var symbolColor: Color?

    var body: some View {
        if let symbol {
            Label {
                text
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(symbolColor.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tint))
            }
        } else {
            text
        }
    }

    /// The label colours are named outright rather than `.primary` and
    /// `.secondary`: inside a list button those hierarchical styles resolve
    /// against the button's tint, which turns a whole navigation row teal.
    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .foregroundStyle(Color(.label))
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color(.secondaryLabel))
            }
        }
    }
}

/// A read-only row: label on the left, a status accessory on the right.
private struct SettingsRow<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            SettingsLabel(title: title, subtitle: subtitle, symbol: symbol)
            Spacer(minLength: 8)
            accessory
        }
        .accessibilityElement(children: .combine)
    }
}

/// A row that opens another screen as a sheet. It reads like a navigation row
/// because that is what it is to the person tapping it.
private struct SheetRow: View {
    let title: String
    var subtitle: String?
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SettingsLabel(title: title, subtitle: subtitle, symbol: symbol)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            .contentShape(.rect)
        }
    }
}

/// Keeps a plain `Label` icon in the accent colour inside `LabeledContent`.
private struct SettingsIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
                .foregroundStyle(.primary)
        } icon: {
            configuration.icon
                .foregroundStyle(.tint)
        }
    }
}

/// Ready or not, as a system symbol. Shape as well as colour.
private struct StatusMark: View {
    let ok: Bool

    var body: some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .foregroundStyle(ok ? Palette.ok : Palette.warn)
            .accessibilityLabel(ok ? "Ready" : "Needs attention")
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
