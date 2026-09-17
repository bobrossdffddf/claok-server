import SwiftUI
import CloakKit

struct PairWithoutComputerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = RemotePairing()
    @FocusState private var pinFocused: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 48

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Metrics.loose) {
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

                    if case .failed(let reason) = pairing.phase {
                        failureCard(reason)
                    }

                    if case .ready(let count, let dvt) = pairing.phase {
                        readyCard(count: count, hasDvt: dvt)
                    }

                    if let note = pairing.note, !note.isEmpty {
                        Label(note, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Palette.warn)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .card()
                    }

                    stepList

                    howItWorks
                }
                .padding(.horizontal, Metrics.regular)
                .padding(.top, Metrics.tight)
                .padding(.bottom, Metrics.loose)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Palette.ground.ignoresSafeArea())
            .pairingActionBar { actions }
            .navigationTitle("Pair without a computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: Self.closePlacement) {
                    closeButton
                }

                if hasMoreActions {
                    ToolbarItem(placement: .topBarTrailing) {
                        moreMenu
                    }
                }
            }
        }
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
        .onDisappear { pairing.stop() }
        #if DEBUG
        .task { seedTourPhase() }
        #endif
    }

    #if DEBUG
    /// Screenshot tours only. With CLOAK_TOUR=pair, CLOAK_TOUR_PAIR_PHASE puts
    /// the screen straight into one phase so every state can be captured
    /// without a phone on the other end: waiting, pin, code, trust, tunnel,
    /// mounting, failed, failed-network, ready or partial. It only sets what
    /// the screen reads; nothing is started and nothing is sent.
    private func seedTourPhase() {
        let env = ProcessInfo.processInfo.environment
        guard env["CLOAK_TOUR"] == "pair", let name = env["CLOAK_TOUR_PAIR_PHASE"] else { return }
        let services = [
            "com.apple.mobile.lockdown.remote.trusted",
            "com.apple.mobile.mobile_image_mounter.shim.remote",
            "com.apple.instruments.dtservicehub",
            "com.apple.dt.simulatelocation",
        ]
        switch name {
        case "waiting":
            pairing.route = .pairableHost
            pairing.phase = .advertising
        case "pin":
            pairing.route = .pairableHost
            pairing.phase = .showPin("482913")
        case "code":
            pairing.route = .discovered
            pairing.phase = .enterPin
        case "trust":
            pairing.route = .lockdown
            pairing.phase = .trusting
        case "tunnel":
            pairing.phase = .needsTunnel
        case "mounting":
            pairing.route = .pairableHost
            pairing.phase = .mounting
        case "failed":
            pairing.route = .lockdown
            pairing.note = "The direct route did not answer either, so both ways have been tried."
            pairing.phase = .failed("pair-setup: connection reset by peer (os error 54) while waiting for the device to answer")
        case "failed-network":
            pairing.route = .discovered
            pairing.needsLocalNetwork = true
            pairing.phase = .failed("NWBrowser: PolicyDenied (-65570). Local Network permission is off for Cloak.")
        case "ready":
            pairing.route = .pairableHost
            pairing.services = services
            pairing.phase = .ready(services: 14, hasDvt: true)
        case "partial":
            pairing.route = .pairableHost
            pairing.services = Array(services.prefix(3))
            pairing.phase = .ready(services: 9, hasDvt: false)
        default:
            break
        }
    }
    #endif

    // MARK: - Toolbar

    /// The system close button on iOS 26, and the familiar Done before it.
    private static var closePlacement: ToolbarItemPlacement {
        if #available(iOS 26.0, *) { return .cancellationAction }
        return .confirmationAction
    }

    @ViewBuilder
    private var closeButton: some View {
        if #available(iOS 26.0, *) {
            Button(role: .close) { pairing.stop(); dismiss() }
                .tint(.primary)
        } else {
            Button("Done") { pairing.stop(); dismiss() }
        }
    }

    /// "Pair from scratch" is under the main button after a failure that did
    /// not come from Local Network permission, so the menu does not repeat it.
    private var showsRepairOnScreen: Bool {
        if case .failed = pairing.phase { return !pairing.needsLocalNetwork }
        return false
    }

    private var hasMoreActions: Bool {
        pairing.storedRecord != nil || pairing.phase == .needsTunnel
    }

    /// Everything nobody needs on the normal path, one tap away.
    private var moreMenu: some View {
        Menu {
            if case .needsTunnel = pairing.phase {
                Button("Try again", systemImage: "arrow.clockwise") {
                    Task { await pairing.begin() }
                }
                Button("Try pairing without it", systemImage: "forward") {
                    Task { await pairing.begin(ignoringTunnel: true) }
                }
            }

            if pairing.storedRecord != nil {
                Section {
                    if !showsRepairOnScreen {
                        Button("Pair from scratch", systemImage: "arrow.triangle.2.circlepath") {
                            Task { await pairing.repair() }
                        }
                    }

                    Button("Forget the stored pairing", systemImage: "trash", role: .destructive) {
                        pairing.forget()
                        model.banner = "Remote pairing cleared."
                    }
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .tint(.primary)
    }

    // MARK: - Bottom actions

    /// One prominent button for whatever the phase needs next, and at most
    /// one quiet one under it.
    @ViewBuilder
    private var actions: some View {
        switch pairing.phase {
        case .needsTunnel:
            let helperApp = model.reflector.provider == .localDevVPN
            let installed = model.reflector.localDevVPNInstalled

            // Both buttons are always offered when a helper app is involved.
            // iOS answers canOpenURL from a cache that can still say "not
            // installed" right after someone installs it, so gating on that
            // alone can strand them on a screen with no way forward.
            if helperApp && !installed {
                prominent("Get LocalDevVPN, free", systemImage: "arrow.down.app") {
                    model.reflector.openAppStoreForLocalDevVPN()
                }
                quiet("I have it, turn the tunnel on") {
                    Task { await startTunnelThenPair() }
                }
            } else {
                prominent("Turn the tunnel on") {
                    Task { await startTunnelThenPair() }
                }
                if helperApp {
                    quiet("Get LocalDevVPN, free") {
                        model.reflector.openAppStoreForLocalDevVPN()
                    }
                }
            }

        case .failed:
            if pairing.needsLocalNetwork {
                prominent("Open Cloak's settings", systemImage: "gear") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                quiet(startTitle) {
                    Task { await pairing.begin() }
                }
            } else {
                prominent(startTitle) {
                    Task { await pairing.begin() }
                }
                // With a stored pairing, trying again reuses it. When that
                // is what broke, the way on is a fresh pairing, which the
                // error card often recommends, so it is not left in a menu.
                if pairing.storedRecord != nil {
                    quiet("Pair from scratch") {
                        Task { await pairing.repair() }
                    }
                }
            }

        case .advertising:
            prominent("Open Settings", systemImage: "gear") {
                openDeveloperSettings()
            }

        case .enterPin:
            prominent("Confirm the code") { pairing.submitPin() }
                .disabled(pairing.pin.trimmingCharacters(in: .whitespaces).isEmpty)

        case .ready(_, let dvt):
            if dvt {
                prominent("Done") { pairing.stop(); dismiss() }
                quiet(startTitle) {
                    Task { await pairing.begin() }
                }
            } else {
                prominent(startTitle) {
                    Task { await pairing.begin() }
                }
            }

        case .idle:
            prominent(startTitle) {
                Task { await pairing.begin() }
            }
            .disabled(isBusy)

        default:
            // Every other phase is Cloak doing the work. The button stays put,
            // disabled, so the bottom of the screen does not jump around.
            Button {} label: {
                HStack(spacing: Metrics.tight) {
                    ProgressView().controlSize(.small)
                    Text(startTitle)
                }
                .font(.headline)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(true)
        }
    }

    private func prominent(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .font(.headline)
        }
        .buttonStyle(PrimaryButtonStyle())
    }

    private func quiet(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Cards

    private var header: some View {
        VStack(spacing: Metrics.tight) {
            Image(systemName: headerSymbol)
                .font(.system(size: heroSize))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(headerTint)
                .frame(minHeight: heroSize + 8)
                .accessibilityHidden(true)

            Text(headerTitle)
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(headerSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Metrics.tight)
    }

    private func cardTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(.primary)
            .accessibilityAddTraits(.isHeader)
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

        return VStack(alignment: .leading, spacing: Metrics.snug) {
            cardTitle("One thing first")

            Text(helperApp
                 ? "iOS refuses a connection this phone makes to itself, so it has to be looped back through a tunnel. The free LocalDevVPN app does that for this copy of Cloak."
                 : "iOS refuses a connection this phone makes to itself, so Cloak loops it back through its own tunnel.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Metrics.tight) {
                if helperApp {
                    tunnelCheck(installed ? "LocalDevVPN installed" : "LocalDevVPN not installed yet", done: installed)
                }
                tunnelCheck(running ? "Tunnel running" : "Tunnel not running", done: running)
            }

            Text(helperApp
                 ? "Your copy cannot carry the tunnel itself, because Apple reserves that for paid developer accounts. LocalDevVPN does this one job, and nothing goes over the internet through it. Open it once after installing and allow the VPN profile it asks for. Cloak switches it on by itself from then on."
                 : "Nothing is proxied, nothing is recorded, and no traffic leaves this phone.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// Brings the reflector up and, if that worked, carries straight on rather
    /// than making the user find the start button again.
    private func startTunnelThenPair() async {
        guard await model.ensureTunnelUp() else { return }
        await pairing.begin()
    }

    private func tunnelCheck(_ title: String, done: Bool) -> some View {
        Label {
            Text(title)
                .foregroundStyle(done ? .primary : .secondary)
        } icon: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(done ? AnyShapeStyle(Palette.ok) : AnyShapeStyle(.secondary))
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    /// iOS puts its own alert on screen here. Saying so plainly beats any
    /// amount of progress spinner, because the phone is waiting on a person.
    private var trustCard: some View {
        VStack(alignment: .leading, spacing: Metrics.snug) {
            cardTitle("Look at your screen")

            VStack(alignment: .leading, spacing: Metrics.tight) {
                instruction(1, "Tap Trust on the alert.")
                instruction(2, "Type this phone's passcode.")
            }

            Text("If no alert appeared, unlock the phone and it will show up. iOS will not pair while the screen is locked.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var waitingCard: some View {
        VStack(alignment: .leading, spacing: Metrics.snug) {
            cardTitle("Now do this on the phone")

            VStack(alignment: .leading, spacing: Metrics.tight) {
                instruction(1, "Open Settings, then Privacy & Security.")
                instruction(2, "Tap Devices.")
                instruction(3, "Under Other Devices, tap \"\(pairing.hostName)\".")
                instruction(4, "Tap Pair, then come back here for the code.")
            }

            Text("Leave Cloak running while you do it. Cloak is only listed for as long as this screen is open, so switch apps rather than closing it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
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
        VStack(spacing: Metrics.snug) {
            cardTitle("Type this into the iOS prompt")

            Text(spaced(pin))
                .font(.system(.largeTitle, design: .rounded, weight: .semibold).monospacedDigit())
                .foregroundStyle(.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Metrics.regular)
                .background(Palette.raised, in: .rect(cornerRadius: Metrics.radius, style: .continuous))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    /// iOS 26 and earlier put the code on their own screen and expect it typed
    /// back into the computer, which here is Cloak.
    private var pinEntryCard: some View {
        VStack(spacing: Metrics.snug) {
            // The header already says the phone is showing a code, so the
            // card only adds what kind and where it goes.
            Text("iOS put a six digit pairing code on screen. Type it here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            TextField("000000", text: Binding(get: { pairing.pin }, set: { pairing.pin = $0 }))
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(.largeTitle, design: .rounded, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .focused($pinFocused)
                .padding(.vertical, Metrics.snug)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Palette.raised, in: .rect(cornerRadius: Metrics.radius, style: .continuous))
        }
        .frame(maxWidth: .infinity)
        .card()
        .onAppear { pinFocused = true }
    }

    private func readyCard(count: Int, hasDvt: Bool) -> some View {
        VStack(alignment: .leading, spacing: Metrics.tight) {
            Label(
                hasDvt ? "Paired and ready" : "Paired, but the location service is missing",
                systemImage: hasDvt ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.headline)
            .foregroundStyle(hasDvt ? Palette.ok : Palette.warn)

            Text(hasDvt
                 ? "\(count) developer services reachable, including the location service. Cloak simulates on its own from now on."
                 : "\(count) services reachable, but the location service was not among them. The developer image is probably not mounted.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !pairing.services.isEmpty {
                DisclosureGroup("Services") {
                    Text(pairing.services.joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Metrics.tight)
                }
                .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func failureCard(_ reason: String) -> some View {
        ErrorCard(raw: reason) {
            model.banner = "Copied."
        }
    }

    /// The background, for anyone who wants it, kept out of the main flow.
    private var howItWorks: some View {
        DisclosureGroup("How this works") {
            Text("From iOS 27 a phone pairs outward, to a computer that says it is pairable, and it lists those under Settings, Privacy & Security, Devices. Cloak simply says it is one of those computers. Everything happens on this one device: Cloak shows a code, you type it into the iOS prompt, and Cloak keeps the pairing for good.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Metrics.tight)
        }
        .font(.subheadline)
        .padding(.horizontal, Metrics.regular)
        .padding(.vertical, Metrics.snug)
        .frame(minHeight: 44)
        .background(Palette.surface, in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    // MARK: - Steps

    private var stepRows: [(title: String, stage: Int)] {
        var rows: [(title: String, stage: Int)]
        switch pairing.route {
        case .lockdown:
            rows = [("Ask this phone to pair", 1), ("Tap Trust on the phone", 3)]
        case .pairableHost:
            rows = [("Advertise Cloak as pairable", 1), ("The phone connects", 2), ("Type the code into iOS", 3)]
        case .discovered:
            rows = [("Reach the pairing service", 2), ("Type the code from your phone", 3)]
        }
        rows += [
            ("Bring up the encrypted tunnel", 4),
            ("Mount the developer image", 5),
            ("Reach the location service", 6),
        ]
        return rows
    }

    private var stepList: some View {
        let rows = stepRows
        return VStack(alignment: .leading, spacing: Metrics.tight) {
            Text("Progress")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, Metrics.regular)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { item in
                    step(item.element.title, state: stageState(item.element.stage))
                    if item.offset < rows.count - 1 {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .background(Palette.surface, in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
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
        HStack(spacing: Metrics.snug) {
            Group {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Palette.ok)
                case .active:
                    ProgressView().controlSize(.small)
                case .waiting:
                    Image(systemName: "circle.dashed")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.body)
            .frame(width: 24)

            Text(title)
                .font(.subheadline)
                .foregroundStyle(state == .waiting ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.regular)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityValue(state == .done ? "Done" : state == .active ? "In progress" : "Waiting")
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        Label {
            Text(text)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(.tint)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var headerTint: AnyShapeStyle {
        switch pairing.phase {
        case .failed: return AnyShapeStyle(Palette.danger)
        case .needsTunnel: return AnyShapeStyle(Palette.warn)
        case .ready(_, let dvt): return AnyShapeStyle(dvt ? Palette.ok : Palette.warn)
        case .idle: return AnyShapeStyle(.secondary)
        default: return AnyShapeStyle(.tint)
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

// MARK: - Bottom bar

private extension View {
    /// Pins the phase's buttons to the bottom, as a system bar on iOS 26 and a
    /// safe area inset before it, over a solid backdrop.
    @ViewBuilder
    func pairingActionBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        let content = VStack(spacing: Metrics.hair) { bar() }
            .padding(.horizontal, Metrics.regular)
            .padding(.top, Metrics.snug)
            .padding(.bottom, Metrics.tight)
            .background { ActionBarBackdrop() }

        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom) { content }
        } else {
            safeAreaInset(edge: .bottom) {
                content
            }
        }
    }
}

/// Solid behind the bottom buttons, with a short fade above them, so text
/// scrolled underneath never shows between a button and the keyboard or the
/// home indicator. The edge effect alone left it readable.
private struct ActionBarBackdrop: View {
    var body: some View {
        Palette.ground
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .top) {
                LinearGradient(colors: [Palette.ground.opacity(0), Palette.ground], startPoint: .top, endPoint: .bottom)
                    .frame(height: Metrics.loose)
                    .offset(y: -Metrics.loose)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
