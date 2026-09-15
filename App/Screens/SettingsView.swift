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
    @State private var confirmsReset = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.loose) {
                    if !model.canRunInBackground {
                        backgroundWarning
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
                .padding(Metrics.card)
                .padding(.bottom, 24)
            }
            .background(Palette.ground)
            .scrollIndicators(.hidden)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Palette.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsDiagnostics) { DiagnosticsView() }
        .sheet(isPresented: $showsSigning) { SigningView() }
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

    private var backgroundWarning: some View {
        VStack(alignment: .leading, spacing: Metrics.snug) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.warn)
                Text("Simulation stops when you leave the app")
                    .font(.label(15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("iOS only keeps Cloak running in the background while location access is set to Always. It is currently \(authorizationName).")
                .font(.label(13))
                .foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)

            Button("Open Location settings") { model.openLocationSettings() }
                .buttonStyle(PrimaryButtonStyle(tint: Palette.warn))
        }
        .padding(Metrics.regular)
        .background(Palette.warn.opacity(0.10), in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .strokeBorder(Palette.warn.opacity(0.35), lineWidth: 1)
        )
    }

    private var statusSection: some View {
        Section(title: "Status") {
            Row(symbol: "link", title: "Pairing", subtitle: pairingDetail) {
                StatusDot(ok: model.hasAnyPairing)
            }
            Row(symbol: "externaldrive.fill", title: "Developer image", subtitle: DeveloperImageBundle.source) {
                StatusDot(ok: model.hasDeveloperImage)
            }
            Row(symbol: "location.fill", title: "Location access", subtitle: authorizationName, showsDivider: false) {
                StatusDot(ok: model.canRunInBackground, okTint: Palette.ok)
            }
        }
    }

    private var tunnelSection: some View {
        let provider = model.reflector.provider
        let up = model.reflector.isUp

        return Section(
            title: "Tunnel",
            footer: provider == .localDevVPN
                ? "iOS will not answer a connection this phone makes to itself. LocalDevVPN loops it back so it does. It carries no internet traffic and Cloak only asks it to switch on."
                : "Cloak's own loopback tunnel. Nothing is proxied and no traffic leaves this phone."
        ) {
            Row(symbol: up ? "shield.lefthalf.filled" : "shield.slash",
                title: provider == .localDevVPN ? "LocalDevVPN" : "Cloak's own tunnel",
                subtitle: up ? "Running" : "Not running",
                tint: up ? Palette.ok : Palette.warn,
                showsDivider: provider == .localDevVPN || !up) {
                StatusDot(ok: up)
            }

            if provider == .localDevVPN {
                if model.reflector.localDevVPNInstalled {
                    ActionRow(symbol: "power", title: up ? "Restart the tunnel" : "Turn the tunnel on", showsDivider: false) {
                        Task { _ = await model.ensureTunnelUp() }
                    }
                } else {
                    ActionRow(symbol: "arrow.down.app", title: "Get LocalDevVPN, free", tint: Palette.warn, showsDivider: false) {
                        model.reflector.openAppStoreForLocalDevVPN()
                    }
                }
            } else if !up {
                ActionRow(symbol: "power", title: "Turn the tunnel on", showsDivider: false) {
                    Task { _ = await model.ensureTunnelUp() }
                }
            }
        }
    }

    private var safetySection: some View {
        Section(
            title: "Safety",
            footer: "Peeking clears the simulation for about two seconds, because iOS hands Cloak the same fake fix it gives every other app."
        ) {
            Row(symbol: "shield.lefthalf.filled", title: "Geofence guard", subtitle: "Stops if your real position leaves the area") {
                Toggle("", isOn: Binding(
                    get: { model.geofence.isEnabled },
                    set: { model.setGeofenceEnabled($0) }
                ))
                .labelsHidden()
                .tint(Palette.accent)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Radius").font(.label(14)).foregroundStyle(.white)
                    Spacer()
                    Text("\(Int(model.geofence.radius / 1000)) km")
                        .font(.readout(13))
                        .foregroundStyle(Palette.accent)
                }
                Slider(
                    value: Binding(get: { model.geofence.radius }, set: { model.geofence.radius = $0 }),
                    in: 1000...200_000,
                    step: 1000
                )
                .tint(Palette.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.hairline.opacity(0.5)).frame(height: 0.5).padding(.leading, 14)
            }

            ActionRow(symbol: "scope", title: "Centre it where I am") {
                model.saveGeofenceHere()
            }

            ActionRow(
                symbol: "eye",
                title: model.isPeeking ? "Peeking" : "Peek at my real location",
                showsDivider: false
            ) {
                Task { await model.peekRealLocation() }
            }
            .disabled(model.isPeeking)
        }
    }

    private var speedHelpSection: some View {
        Section(
            title: "Speed help",
            footer: "Sets how fast a simulated drive goes against the speed limit of each road it passes along, adjusting as the limits change. It shapes the drive Cloak plays back and does not read how the phone is really moving."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: Binding(
                    get: { model.speedHelp.isEnabled },
                    set: { model.setSpeedHelp(model.speedHelp.with(isEnabled: $0)) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Speed help").font(.label(14)).foregroundStyle(.white)
                        Text(model.speedHelp.summary)
                            .font(.label(12))
                            .foregroundStyle(model.speedHelp.isEnabled ? Palette.accent : Palette.dim)
                    }
                }
                .tint(Palette.accent)

                if model.speedHelp.isEnabled {
                    Picker("", selection: Binding(
                        get: { model.speedHelp.mode },
                        set: { model.setSpeedHelp(model.speedHelp.with(mode: $0)) }
                    )) {
                        Text("Auto").tag(SpeedHelp.Mode.auto)
                        Text("Manual").tag(SpeedHelp.Mode.manual)
                    }
                    .pickerStyle(.segmented)

                    switch model.speedHelp.mode {
                    case .auto:
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(SpeedHelp.Profile.allCases) { profile in
                                Button {
                                    model.setSpeedHelp(model.speedHelp.with(profile: profile))
                                } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: model.speedHelp.profile == profile
                                              ? "largecircle.fill.circle" : "circle")
                                            .font(.system(.callout))
                                            .foregroundStyle(model.speedHelp.profile == profile
                                                             ? Palette.accent : Palette.dim)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(profile.name)
                                                .font(.label(14, weight: .medium))
                                                .foregroundStyle(.white)
                                            Text(profile.detail)
                                                .font(.label(12))
                                                .foregroundStyle(Palette.dim)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }

                    case .manual:
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Never above").font(.label(14)).foregroundStyle(.white)
                                Spacer()
                                Text("\(Int(model.speedHelp.manualMaxMph.rounded())) mph")
                                    .font(.readout(13))
                                    .foregroundStyle(Palette.accent)
                            }
                            Slider(
                                value: Binding(
                                    get: { model.speedHelp.manualMaxMph },
                                    set: { model.setSpeedHelp(model.speedHelp.with(manualMaxMph: $0)) }
                                ),
                                in: 15...85,
                                step: 5
                            )
                            .tint(Palette.accent)
                            Text("The road still applies. A 30 limit stays a 30 limit.")
                                .font(.label(12))
                                .foregroundStyle(Palette.dim)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var drivingSection: some View {
        Section(title: "Driving", footer: "Auto stop ends a simulation on its own, so a drive left running does not carry on all day.") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Auto stop").font(.label(14)).foregroundStyle(.white)
                    Spacer()
                    Text(model.autoStopMinutes == 0 ? "Off" : "\(model.autoStopMinutes) min")
                        .font(.readout(13))
                        .foregroundStyle(model.autoStopMinutes == 0 ? Palette.dim : Palette.accent)
                }
                Slider(
                    value: Binding(
                        get: { Double(model.autoStopMinutes) },
                        set: { model.autoStopMinutes = Int($0) }
                    ),
                    in: 0...180,
                    step: 15
                )
                .tint(Palette.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var setupSection: some View {
        Section(title: "Setup") {
            ActionRow(
                symbol: "sparkles",
                title: "Run setup again",
                subtitle: "Walk through Developer Mode, pairing and the tunnel"
            ) {
                confirmsReset = true
            }

            ActionRow(
                symbol: "signature",
                title: "Signing",
                subtitle: signingSubtitle
            ) {
                showsSigning = true
            }

            ActionRow(
                symbol: "iphone.radiowaves.left.and.right",
                title: "Pairing",
                subtitle: model.hasAnyPairing ? "Paired with this phone" : "Not paired yet"
            ) {
                showsPairing = true
            }

            ActionRow(
                symbol: "stethoscope",
                title: "Diagnostics",
                subtitle: "See every step of the chain",
                showsDivider: false
            ) {
                showsDiagnostics = true
            }
        }
    }

    @ViewBuilder
    private var licenseSection: some View {
        if licensing.isEnforced {
            Section(
                title: "Licence",
                footer: "One licence covers one phone. Releasing it here frees it for another, and Cloak locks until a licence is entered again."
            ) {
                Row(symbol: "key.fill",
                    title: "Licence",
                    subtitle: licenseDetail,
                    tint: licensing.isUnlocked ? Palette.ok : Palette.warn) {
                    StatusDot(ok: licensing.isUnlocked)
                }

                ActionRow(symbol: "arrow.up.right.square",
                          title: "Release this phone",
                          tint: Palette.warn,
                          showsDivider: false) {
                    Task { await licensing.release() }
                }
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
        Section(title: "About", footer: "Nothing leaves this phone. No account, no analytics, no servers.") {
            Row(symbol: "number", title: "Version", subtitle: versionText, showsDivider: false) {
                EmptyView()
            }
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
