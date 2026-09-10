import SwiftUI
import CloakKit

struct PairWithoutComputerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = RemotePairing()
    @FocusState private var pinFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    if !model.hasLocalNetwork {
                        WifiNotice()
                    }

                    if case .showPin(let pin) = pairing.phase {
                        pinCard(pin)
                    }

                    if case .enterPin = pairing.phase {
                        pinEntryCard
                    }

                    if case .advertising = pairing.phase {
                        waitingCard
                    }

                    if case .trusting = pairing.phase {
                        trustCard
                    }

                    if case .needsTunnel = pairing.phase {
                        tunnelCard
                    }

                    stepList

                    if let note = pairing.note, !note.isEmpty {
                        Text(note)
                            .font(.label(12))
                            .foregroundStyle(Palette.warn)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.warn.opacity(0.08), in: .rect(cornerRadius: 12, style: .continuous))
                    }

                    if case .ready(let count, let dvt) = pairing.phase {
                        readyCard(count: count, hasDvt: dvt)
                    }

                    if case .failed(let reason) = pairing.phase {
                        failureCard(reason)

                        if pairing.needsLocalNetwork {
                            Button {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            } label: {
                                Label("Open Cloak's settings", systemImage: "gear")
                            }
                            .buttonStyle(PrimaryButtonStyle())
                        }
                    }

                    actionButtons

                    Text("From iOS 27 a phone pairs outward, to a computer that says it is pairable, and it lists those under Settings, Privacy & Security, Devices. Cloak simply says it is one of those computers. Everything happens on this one device: Cloak shows a code, you type it into the iOS prompt, and Cloak keeps the pairing for good.")
                        .font(.label(12))
                        .foregroundStyle(Palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
            }
            .background(Palette.ground)
            .navigationTitle("Pair without a computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { pairing.stop(); dismiss() }.tint(Palette.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onDisappear { pairing.stop() }
    }

    // MARK: - Cards

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(headerTint.opacity(0.18)).frame(width: 52, height: 52)
                Image(systemName: headerSymbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(headerTint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(headerTitle).font(.label(17, weight: .semibold)).foregroundStyle(.white)
                Text(headerSubtitle)
                    .font(.label(13))
                    .foregroundStyle(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Palette.surface, in: .rect(cornerRadius: 18, style: .continuous))
    }

    /// The one thing that stops a computer-free pairing dead.
    ///
    /// iOS will not answer a connection this phone makes to itself, so without
    /// the loopback reflector there is nothing to do but get it running first.
    /// A warning note was not enough here: it left the screen looking like it
    /// had failed for some other reason, with no way forward.
    private var tunnelCard: some View {
        let helperApp = model.reflector.provider == .localDevVPN
        let installed = model.reflector.localDevVPNInstalled
        let running = model.reflector.isUp

        return VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "One thing first")

            Text(helperApp
                 ? "iOS refuses a connection this phone makes to itself, so it has to be looped back through a tunnel. Your copy of Cloak cannot carry that tunnel, because Apple reserves it for paid developer accounts, so it uses LocalDevVPN. That app is free, it does this one job, and nothing goes over the internet through it."
                 : "iOS refuses a connection this phone makes to itself, so Cloak loops it back through its own tunnel. Nothing is proxied, nothing is recorded, and no traffic leaves this phone.")
                .font(.label(13))
                .foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)

            if helperApp {
                tunnelCheck(installed ? "LocalDevVPN installed" : "LocalDevVPN not installed yet", done: installed)
            }
            tunnelCheck(running ? "Tunnel running" : "Tunnel not running", done: running)

            // Both buttons are always offered when a helper app is involved.
            // iOS answers canOpenURL from a cache that can still say "not
            // installed" right after someone installs it, so gating on that
            // alone can strand them on a screen with no way forward.
            if helperApp && !installed {
                Button {
                    model.reflector.openAppStoreForLocalDevVPN()
                } label: {
                    Label("Get LocalDevVPN, free", systemImage: "arrow.down.app")
                }
                .buttonStyle(PrimaryButtonStyle())

                Button("I have it, turn the tunnel on") {
                    Task { await startTunnelThenPair() }
                }
                .buttonStyle(QuietButtonStyle())
            } else {
                Button("Turn the tunnel on") {
                    Task { await startTunnelThenPair() }
                }
                .buttonStyle(PrimaryButtonStyle())

                if helperApp {
                    Button {
                        model.reflector.openAppStoreForLocalDevVPN()
                    } label: {
                        Label("Get LocalDevVPN, free", systemImage: "arrow.down.app")
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            }

            if helperApp {
                Text("Open LocalDevVPN once after installing and allow the VPN profile it asks for. Cloak switches it on by itself from then on.")
                    .font(.label(12))
                    .foregroundStyle(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Try pairing without it") {
                Task { await pairing.begin(ignoringTunnel: true) }
            }
            .buttonStyle(QuietButtonStyle(tint: Palette.dim))
        }
        .padding(16)
        .background(Palette.warn.opacity(0.07), in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Palette.warn.opacity(0.3), lineWidth: 1)
        )
    }

    /// Brings the reflector up and, if that worked, carries straight on rather
    /// than making the user find the start button again.
    private func startTunnelThenPair() async {
        guard await model.ensureTunnelUp() else { return }
        await pairing.begin()
    }

    private func tunnelCheck(_ title: String, done: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dotted")
                .font(.system(size: 15))
                .foregroundStyle(done ? Palette.ok : Palette.dim)
            Text(title)
                .font(.label(13))
                .foregroundStyle(done ? .white : Palette.dim)
            Spacer(minLength: 0)
        }
    }

    /// iOS puts its own alert on screen here. Saying so plainly beats any
    /// amount of progress spinner, because the phone is waiting on a person.
    private var trustCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Look at your screen")
            Text("iOS is asking whether to trust this computer. It means Cloak, running right here.")
                .font(.label(14))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            instruction(1, "Tap Trust on the alert.")
            instruction(2, "Type this phone's passcode.")

            Text("If no alert appeared, unlock the phone and it will show up. iOS will not pair while the screen is locked.")
                .font(.label(12))
                .foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Palette.accent.opacity(0.08), in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Palette.accent.opacity(0.35), lineWidth: 1)
        )
    }

    private var waitingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Now do this on the phone")
            instruction(1, "Open Settings, then Privacy & Security.")
            instruction(2, "Tap Devices.")
            instruction(3, "Under Other Devices, tap \"\(pairing.hostName)\".")
            instruction(4, "Tap Pair, then come back here for the code.")

            Text("Leave Cloak running while you do it. Cloak is only listed for as long as this screen is open, so switch apps rather than closing it.")
                .font(.label(12))
                .foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                openDeveloperSettings()
            } label: {
                Label("Open Settings", systemImage: "gear")
            }
            .buttonStyle(QuietButtonStyle())
        }
        .padding(16)
        .background(Palette.accent.opacity(0.06), in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Palette.accent.opacity(0.25), lineWidth: 1)
        )
    }

    private func openDeveloperSettings() {
        let candidates = [
            "App-prefs:root=Privacy&path=SECURITY",
            "App-prefs:root=Privacy",
            "App-prefs:"
        ]
        for text in candidates {
            guard let url = URL(string: text), UIApplication.shared.canOpenURL(url) else { continue }
            UIApplication.shared.open(url)
            return
        }
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func pinCard(_ pin: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Type this into the iOS prompt")

            Text(spaced(pin))
                .font(.readout(40, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Palette.raised, in: .rect(cornerRadius: 16, style: .continuous))
                .textSelection(.enabled)

            Text("iOS is asking for a pairing code. This is it.")
                .font(.label(13))
                .foregroundStyle(Palette.dim)
        }
        .padding(16)
        .background(Palette.accent.opacity(0.08), in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Palette.accent.opacity(0.35), lineWidth: 1)
        )
    }

    /// iOS 26 and earlier put the code on their own screen and expect it typed
    /// back into the computer, which here is Cloak.
    private var pinEntryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Your phone is showing a code")
            Text("iOS put a six digit pairing code on screen. Type it here.")
                .font(.label(13))
                .foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)

            TextField("000000", text: Binding(get: { pairing.pin }, set: { pairing.pin = $0 }))
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.readout(32, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .focused($pinFocused)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(Palette.raised, in: .rect(cornerRadius: 14, style: .continuous))

            Button("Confirm the code") { pairing.submitPin() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(pairing.pin.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(16)
        .background(Palette.accent.opacity(0.08), in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Palette.accent.opacity(0.35), lineWidth: 1)
        )
        .onAppear { pinFocused = true }
    }

    private func readyCard(count: Int, hasDvt: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: hasDvt ? "Paired and ready" : "Paired, but the location service is missing")
            Text(hasDvt
                 ? "\(count) developer services reachable, including the location service. Cloak simulates on its own from now on."
                 : "\(count) services reachable, but the location service was not among them. The developer image is probably not mounted.")
                .font(.label(13))
                .foregroundStyle(hasDvt ? Palette.ok : Palette.warn)
                .fixedSize(horizontal: false, vertical: true)

            if !pairing.services.isEmpty {
                Text(pairing.services.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.dim)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(Palette.surface, in: .rect(cornerRadius: 18, style: .continuous))
    }

    private func failureCard(_ reason: String) -> some View {
        ErrorCard(raw: reason) {
            model.banner = "Copied."
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button(startTitle) {
                Task { await pairing.begin() }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isBusy)

            if pairing.storedRecord != nil {
                Button("Pair from scratch") {
                    Task { await pairing.repair() }
                }
                .buttonStyle(QuietButtonStyle())

                Button("Forget the stored pairing") {
                    pairing.forget()
                    model.banner = "Remote pairing cleared."
                }
                .buttonStyle(QuietButtonStyle(tint: Palette.danger))
            }
        }
    }

    // MARK: - Steps

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Progress")
            switch pairing.route {
            case .lockdown:
                step("Ask this phone to pair", state: stageState(1))
                step("Tap Trust on the phone", state: stageState(3))
            case .pairableHost:
                step("Advertise Cloak as pairable", state: stageState(1))
                step("The phone connects", state: stageState(2))
                step("Type the code into iOS", state: stageState(3))
            case .discovered:
                step("Reach the pairing service", state: stageState(2))
                step("Type the code from your phone", state: stageState(3))
            }
            step("Bring up the encrypted tunnel", state: stageState(4))
            step("Mount the developer image", state: stageState(5))
            step("Reach the location service", state: stageState(6))
        }
    }

    private enum StepState { case done, active, waiting }

    private func stageState(_ index: Int) -> StepState {
        let current: Int
        switch pairing.phase {
        case .idle, .failed, .needsTunnel: current = 0
        case .advertising: current = 1
        case .deviceConnected: current = 2
        case .showPin, .enterPin, .trusting: current = 3
        case .paired, .searching, .connecting, .tunnelling: current = 4
        case .mounting: current = 5
        case .ready(_, let dvt): current = dvt ? 7 : 6
        }
        if current > index { return .done }
        if current == index { return .active }
        return .waiting
    }

    private func step(_ title: String, state: StepState) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Palette.ok)
                case .active:
                    ProgressView().controlSize(.small).tint(Palette.accent)
                case .waiting:
                    Image(systemName: "circle.dotted")
                        .font(.system(size: 16))
                        .foregroundStyle(Palette.dim)
                }
            }
            .frame(width: 20)

            Text(title)
                .font(.label(15))
                .foregroundStyle(state == .waiting ? Palette.dim : .white)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Palette.surface.opacity(0.6), in: .rect(cornerRadius: 12, style: .continuous))
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.readout(13, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: 22, height: 22)
                .background(Palette.accent.opacity(0.15), in: .circle)
            Text(text)
                .font(.label(14))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func spaced(_ pin: String) -> String {
        guard pin.count == 6 else { return pin }
        let middle = pin.index(pin.startIndex, offsetBy: 3)
        return "\(pin[pin.startIndex..<middle])  \(pin[middle...])"
    }

    // MARK: - Header text

    private var startTitle: String {
        switch pairing.phase {
        case .idle: return pairing.storedRecord == nil ? "Start pairing" : "Reconnect"
        case .failed, .needsTunnel: return "Try again"
        case .ready: return "Run it again"
        default: return "Working"
        }
    }

    private var isBusy: Bool {
        switch pairing.phase {
        case .idle, .failed, .ready, .needsTunnel: return false
        default: return true
        }
    }

    private var headerTint: Color {
        switch pairing.phase {
        case .failed: return Palette.danger
        case .needsTunnel: return Palette.warn
        case .ready(_, let dvt): return dvt ? Palette.ok : Palette.warn
        case .idle: return Palette.dim
        default: return Palette.accent
        }
    }

    private var headerSymbol: String {
        switch pairing.phase {
        case .failed: return "exclamationmark.triangle.fill"
        case .trusting: return "hand.tap.fill"
        case .needsTunnel: return "shield.lefthalf.filled"
        case .ready(_, let dvt): return dvt ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
        case .showPin, .enterPin: return "number.circle.fill"
        case .advertising: return "dot.radiowaves.left.and.right"
        case .idle: return "iphone.radiowaves.left.and.right"
        default: return "antenna.radiowaves.left.and.right"
        }
    }

    private var headerTitle: String {
        switch pairing.phase {
        case .idle: return "Ready when you are"
        case .advertising: return "Waiting for the phone"
        case .deviceConnected: return "The phone is talking"
        case .showPin: return "Type this code"
        case .enterPin: return "Enter the code"
        case .trusting: return "Tap Trust on this phone"
        case .paired: return "Paired"
        case .searching: return "Finding the phone"
        case .connecting: return "Connecting"
        case .tunnelling: return "Building the tunnel"
        case .mounting: return "Mounting the developer image"
        case .ready(_, let dvt): return dvt ? "Done" : "Almost there"
        case .needsTunnel: return "The tunnel is not running"
        case .failed: return "Stopped"
        }
    }

    private var headerSubtitle: String {
        switch pairing.phase {
        case .idle:
            return pairing.storedRecord == nil
                ? "One code, typed once, and this phone never needs a computer again."
                : "Cloak is already paired. Reconnecting takes a few seconds."
        case .advertising: return "Cloak is advertising itself as a pairable computer. It turns up under Other Devices."
        case .deviceConnected: return pairing.detail ?? "Exchanging keys."
        case .showPin: return "iOS asked for the six digit code shown on this computer. It is below."
        case .enterPin: return "Your phone is showing a code. Type it in below."
        case .trusting: return "iOS is asking whether to trust this computer. That is Cloak, on this phone."
        case .paired: return "Now raising the tunnel."
        case .searching: return "Looking for the phone's own pairing service."
        case .connecting: return pairing.detail ?? "Opening the socket."
        case .tunnelling: return "Negotiating the encrypted channel."
        case .mounting: return "This takes a minute or two. Keep Cloak open."
        case .ready: return "Cloak holds its own pairing now."
        case .needsTunnel:
            return model.reflectorProblem
                ?? "Cloak needs the loopback tunnel before it can reach this phone."
        case .failed: return "See the detail below."
        }
    }
}
