import SwiftUI
import CoreLocation
import UniformTypeIdentifiers
import CloakKit

/// Setup, one small thing at a time.
///
/// Every screen asks for exactly one action, names the thing to tap in the
/// words that appear on the phone, and shows a check that goes green by itself
/// when it has happened. Then it moves on without being asked. Nobody should
/// have to work out whether they did it right, and nobody should have to be
/// walked through this by a person.
///
/// There are no screens here that only explain. Those are the ones people skip,
/// and skipping them is how somebody ends up three steps later with no idea
/// what went wrong. Explanation rides along with the thing it explains.
///
/// The route is not fixed. A copy installed from a computer arrives paired, so
/// that chapter is dropped rather than shown and ticked off. A copy signed with
/// a paid account carries its own tunnel and never hears about the helper app.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    @State private var index = 0

    init(startingAt index: Int = 0) {
        _index = State(initialValue: index)
    }

    /// Computed every render from the live state, so it is never empty or
    /// stale on the first frame. It used to be built in a `.task` that ran
    /// after the view appeared, which left every button clamping to step
    /// zero, and doing nothing, until that task happened to run.
    private var plan: [Step] { buildPlan() }
    @State private var showsRemotePairing = false
    @State private var showsScanner = false
    @State private var showsImporter = false
    @State private var glow = false

    @State private var pairingBusy = false
    @State private var pairingStage: String?
    @State private var pairingTrouble: String?

    enum Step: Hashable {
        case welcome
        /// Installed from a computer, so pairing is already done.
        case handoff
        /// Free signature: the tunnel lives in a small companion app.
        case getTunnelApp
        case turnTunnelOn
        /// Paid signature: Cloak carries its own tunnel.
        case allowTunnel
        case trust
        case setupFiles
        case location
        case ready
    }

    private var step: Step {
        plan.indices.contains(index) ? plan[index] : .welcome
    }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 22)
                    .padding(.top, 14)

                ScrollView {
                    content
                        .padding(.horizontal, 22)
                        .padding(.top, 26)
                        .padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                        .id(step)
                }
                .scrollIndicators(.hidden)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsRemotePairing, onDismiss: { model.refreshPairingState() }) {
            PairWithoutComputerView()
        }
        .sheet(isPresented: $showsScanner) {
            PairingScannerView { data in
                showsScanner = false
                Task { await model.importSetup(data: data) }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.propertyList, .data, .xml]) { result in
            guard case .success(let url) = result else { return }
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url) else { return }
            Task { await model.importSetup(data: data) }
        }
        // The whole point of the live checks: when the thing has happened, go
        // on. Waiting for somebody to notice a tick and press Continue is one
        // more decision than this needs.
        .onChange(of: satisfied) { _, done in
            guard done, advancesOnItsOwn else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(850))
                await MainActor.run {
                    if satisfied, advancesOnItsOwn { advance() }
                }
            }
        }
        .task {
            withAnimation(.smooth(duration: 0.9)) { glow = true }
        }
    }

    // MARK: - The route

    private func buildPlan() -> [Step] {
        var steps: [Step] = [.welcome]

        // The tunnel first, always. Nothing else on this list can happen
        // without it: iOS refuses a connection this phone makes to itself, and
        // the tunnel is the only thing that gets around that.
        if model.reflector.provider == .localDevVPN {
            if !model.reflector.localDevVPNInstalled { steps.append(.getTunnelApp) }
            steps.append(.turnTunnelOn)
        } else {
            steps.append(.allowTunnel)
        }

        steps.append(model.hasAnyPairing ? .handoff : .trust)

        if !model.hasDeveloperImage { steps.append(.setupFiles) }
        if model.locationAuthorization != .authorizedAlways { steps.append(.location) }

        steps.append(.ready)
        return steps
    }

    /// Whether this screen's one job is done.
    private var satisfied: Bool {
        switch step {
        case .getTunnelApp: model.reflector.localDevVPNInstalled
        case .turnTunnelOn, .allowTunnel: model.reflector.isUp
        case .trust: model.hasAnyPairing
        case .setupFiles: model.hasDeveloperImage
        case .location: model.locationAuthorization == .authorizedAlways
        case .welcome, .handoff, .ready: false
        }
    }

    private var advancesOnItsOwn: Bool {
        switch step {
        case .welcome, .handoff, .ready: false
        default: true
        }
    }

    // MARK: - Chrome

    private var background: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            RadialGradient(
                colors: [Palette.accent.opacity(0.15), .clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 560
            )
            .ignoresSafeArea()
            .opacity(glow ? 1 : 0)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if index > 0 {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(.footnote, weight: .bold))
                        .foregroundStyle(Palette.dim)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Palette.surface))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.raised)
                    Capsule()
                        .fill(Palette.accent)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 4)

            Text("Step \(index + 1) of \(max(plan.count, 1))")
                .font(.readout(11, weight: .medium))
                .foregroundStyle(Palette.dim)
                .monospacedDigit()
        }
        .animation(.smooth(duration: 0.4), value: index)
    }

    private var fraction: Double {
        guard !plan.isEmpty else { return 0 }
        return Double(index + 1) / Double(plan.count)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .handoff: handoff
        case .getTunnelApp: getTunnelApp
        case .turnTunnelOn: turnTunnelOn
        case .allowTunnel: allowTunnel
        case .trust: trust
        case .setupFiles: setupFiles
        case .location: location
        case .ready: ready
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        page(symbol: "location.viewfinder", title: "Put your phone anywhere") {
            Text("Cloak changes the location this phone reports to every app on it.")
            if model.hasAnyPairing {
                Text("The computer you installed from already did the hard part. Two short steps and you are running.")
            } else {
                Text("Setup takes a few minutes and happens once. Nothing is jailbroken and no cable is needed.")
                Text("Every screen asks for one thing and tells you exactly what to tap. When it is done, it moves on by itself.")
            }
        } actions: {
            Button("Start") { advance() }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    private var handoff: some View {
        page(symbol: "checkmark.seal.fill", title: "Already paired") {
            Text("The installer on your computer handed Cloak the key it needs, so there is no code to type and no restart to sit through.")
        } actions: {
            VStack(spacing: Metrics.snug) {
                liveCheck(title: "Paired with this phone", done: model.hasAnyPairing)
                Button("Continue") { advance() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var getTunnelApp: some View {
        let installed = model.reflector.localDevVPNInstalled

        return page(symbol: "arrow.down.app.fill", title: "Get the free helper app") {
            Text("iOS will not let an app reach this phone's own developer tools directly. A small free app called LocalDevVPN is what makes it possible.")
            Text("It does that one job. Nothing is proxied and no traffic leaves this phone.")
        } actions: {
            VStack(spacing: Metrics.snug) {
                liveCheck(
                    title: installed ? "LocalDevVPN is installed" : "Not installed yet",
                    done: installed
                )

                if !installed {
                    Button {
                        model.reflector.presentLocalDevVPNSheet()
                    } label: {
                        Label("Install it here", systemImage: "arrow.down.app")
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    tapList([
                        "Tap Install it here. A panel slides up from the bottom.",
                        "Tap GET, then confirm the way you normally install apps.",
                        "Wait for it to finish. Do not open it, just come back here.",
                    ])

                    Button("Use the App Store instead") {
                        model.reflector.openAppStoreForLocalDevVPN()
                    }
                    .buttonStyle(QuietButtonStyle())

                    // The check above can lag behind an install iOS has not
                    // told us about yet. The next step opens LocalDevVPN for
                    // real, which is the authoritative test, so never hold
                    // anyone here on the strength of a stale answer.
                    Button("I have installed it, continue") { advance() }
                        .buttonStyle(QuietButtonStyle())
                } else {
                    Button("Continue") { advance() }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
    }

    private var turnTunnelOn: some View {
        let running = model.reflector.isUp

        return page(symbol: "shield.lefthalf.filled", title: "Switch the tunnel on") {
            Text("One tap. Cloak opens LocalDevVPN, turns it on, and comes straight back here.")
        } actions: {
            VStack(spacing: Metrics.snug) {
                liveCheck(title: running ? "Tunnel is running" : "Tunnel is off", done: running)

                if !running {
                    Button("Turn it on") {
                        Task { _ = await model.ensureTunnelUp() }
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    tapList([
                        "The first time only, iOS asks to add a VPN configuration.",
                        "Tap Allow, then enter this phone's passcode.",
                        "You will land back in Cloak on your own.",
                    ])

                    Button("It did not come back") {
                        model.reflector.openAppStoreForLocalDevVPN()
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            }
        }
    }

    private var allowTunnel: some View {
        let running = model.reflector.isUp

        return page(symbol: "shield.lefthalf.filled", title: "Allow the tunnel") {
            Text("iOS will not answer a connection this phone makes to itself, so Cloak loops it back through a tunnel of its own.")
            Text("Nothing is proxied, nothing is recorded, and no traffic leaves this phone.")
        } actions: {
            VStack(spacing: Metrics.snug) {
                liveCheck(title: running ? "Tunnel is running" : "Tunnel is off", done: running)

                if !running {
                    Button("Allow the tunnel") {
                        Task { _ = await model.ensureTunnelUp() }
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    tapList([
                        "iOS asks to add a VPN configuration.",
                        "Tap Allow, then enter this phone's passcode.",
                    ])
                }
            }
        }
    }

    private var trust: some View {
        let paired = model.hasAnyPairing
        let outward = RemotePairing.usesPairableHost

        return page(
            symbol: "hand.tap.fill",
            title: outward ? "Pair this phone with Cloak" : "Tap Trust on this phone"
        ) {
            if outward {
                Text("From iOS 27 the phone pairs outward, to a computer that says it is pairable. Cloak says it is one. It shows a six digit code, you type it into the iOS prompt, and the pairing is kept for good, even across reinstalls.")
                Text("Wi-Fi only has to be switched on. It does not need to join a network, so this works on cellular.")
            } else {
                Text("Cloak asks this phone to pair with itself. iOS puts its own alert on screen, the same one it shows when you plug into a computer.")
            }
        } actions: {
            VStack(spacing: Metrics.snug) {
                liveCheck(title: paired ? "Paired with this phone" : "Not paired yet", done: paired)

                if !paired && outward {
                    // The tunnel has to be running before pairing can begin:
                    // without it iOS resets the connection before a byte comes
                    // back, and the failure reads as though pairing is broken.
                    let tunnelUp = model.reflector.isUp
                    liveCheck(title: tunnelUp ? "Tunnel is running" : "Tunnel is off", done: tunnelUp)

                    tapList([
                        "Tap Start below and leave Cloak open.",
                        "Open Settings, Privacy & Security, Developer Mode. Under Other Devices tap \"\(RemotePairing.hostNameForDisplay)\".",
                        "Type the six digit code Cloak shows you.",
                    ])

                    if tunnelUp {
                        Button("Start") { showsRemotePairing = true }
                            .buttonStyle(PrimaryButtonStyle())
                    } else {
                        Button("Turn the tunnel on first") {
                            Task { _ = await model.ensureTunnelUp() }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }

                    Menu {
                        Button("Scan a QR code from a Mac") { showsScanner = true }
                        Button("Import a file") { showsImporter = true }
                    } label: {
                        Text("I have a file from a computer")
                            .font(.label(13, weight: .medium))
                            .foregroundStyle(Palette.dim)
                    }
                } else if !paired {
                    tapList([
                        "Tap Start below.",
                        "An alert appears asking whether to trust this computer. Tap Trust.",
                        "Type this phone's passcode.",
                    ])

                    if let stage = pairingStage {
                        Text(stage)
                            .font(.label(13))
                            .foregroundStyle(Palette.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let trouble = pairingTrouble {
                        Text(trouble)
                            .font(.label(12))
                            .foregroundStyle(Palette.warn)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button(pairingBusy ? "Waiting for you" : "Start") {
                        Task { await runPairing() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(pairingBusy)
                    .opacity(pairingBusy ? 0.5 : 1)

                    Button("Show me the other ways") { showsRemotePairing = true }
                        .buttonStyle(QuietButtonStyle())

                    Menu {
                        Button("Scan a QR code from a Mac") { showsScanner = true }
                        Button("Import a file") { showsImporter = true }
                    } label: {
                        Text("I have a file from a computer")
                            .font(.label(13, weight: .medium))
                            .foregroundStyle(Palette.dim)
                    }
                }
            }
        }
    }

    /// Pairs without leaving the screen. The sheet is still there behind "the
    /// other ways", but nobody should have to open it for the normal case.
    private func runPairing() async {
        pairingBusy = true
        pairingTrouble = nil
        pairingStage = "Getting the tunnel ready"

        guard await model.ensureTunnelUp() else {
            pairingStage = nil
            pairingTrouble = model.reflectorProblem
                ?? "The tunnel is not running, and pairing cannot happen without it."
            pairingBusy = false
            return
        }

        let paired = await LockdownPairing.pair { progress in
            switch progress {
            case .idle:
                break
            case .connecting:
                pairingStage = "Asking this phone to pair"
            case .waitingForTrust:
                pairingStage = "Look at your screen and tap Trust"
            case .paired:
                pairingStage = nil
            case .failed(let reason):
                pairingTrouble = reason
            }
        }

        if paired {
            pairingStage = nil
            pairingTrouble = nil
            model.refreshPairingState()
        } else if pairingTrouble == nil {
            pairingTrouble = "Pairing did not finish. Try again, or use one of the other ways below."
        }
        pairingBusy = false
    }

    private var setupFiles: some View {
        let busy: Bool = {
            if case .working = model.imageDelivery.state { return true }
            return false
        }()
        let failure: String? = {
            if case .failed(let reason) = model.imageDelivery.state { return reason }
            return nil
        }()

        return page(symbol: "arrow.down.circle", title: "Get the setup files") {
            Text("iOS keeps its location simulator behind a signed file from Apple and will not offer it until that file is loaded.")
            Text("Cloak is downloading it now. About sixteen megabytes, once, and then never again.")
        } actions: {
            VStack(spacing: Metrics.snug) {
                liveCheck(title: model.imageDelivery.detail, done: model.hasDeveloperImage)

                if case .working(_, let fraction) = model.imageDelivery.state {
                    ProgressView(value: fraction).tint(Palette.accent)
                }

                if let failure {
                    Text(failure)
                        .font(.label(12))
                        .foregroundStyle(Palette.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Try again") {
                        Task { await model.fetchDeveloperImage() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(busy)
                } else if !model.hasDeveloperImage && !busy {
                    Button("Download") {
                        Task { await model.fetchDeveloperImage() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
        .task {
            guard !model.hasDeveloperImage, model.imageDelivery.state == .idle else { return }
            await model.fetchDeveloperImage()
        }
    }

    private var location: some View {
        let allowed = model.locationAuthorization == .authorizedAlways
        let refused = model.locationAuthorization == .denied
            || model.locationAuthorization == .restricted

        return page(symbol: "location.fill", title: "Let Cloak use your location") {
            Text("On Always, a drive keeps going with the phone locked or another app open.")
            Text("On While Using, the simulation freezes the moment you leave Cloak.")
        } actions: {
            VStack(spacing: Metrics.snug) {
                liveCheck(
                    title: allowed ? "Set to Always" : "Not set to Always yet",
                    done: allowed
                )

                if !allowed {
                    if refused {
                        tapList([
                            "Tap Open Settings below.",
                            "Tap Location.",
                            "Tap Always.",
                        ])

                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    } else {
                        tapList([
                            "Tap Allow below.",
                            "Choose Allow While Using App first. iOS insists on that one.",
                            "Cloak will ask again shortly. Choose Change to Always.",
                        ])

                        Button("Allow") { model.requestAlwaysLocation() }
                            .buttonStyle(PrimaryButtonStyle())
                    }

                    Button("Skip for now") { advance() }
                        .buttonStyle(QuietButtonStyle())
                }
            }
        }
    }

    private var ready: some View {
        page(symbol: "checkmark.seal.fill", title: "You are set up") {
            Text("Search a place and go straight there, or add two stops and drive between them at a believable speed.")
            Text("You can run this walkthrough again any time from Settings.")
        } actions: {
            Button("Open Cloak") { model.completeOnboarding() }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: - Pieces

    /// The exact taps, in order, in the words that appear on the phone.
    private func tapList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: Metrics.tight) {
            ForEach(Array(items.enumerated()), id: \.offset) { pair in
                HStack(alignment: .top, spacing: Metrics.snug) {
                    Text("\(pair.offset + 1)")
                        .font(.readout(12, weight: .bold))
                        .foregroundStyle(Palette.accent)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Palette.accent.opacity(0.16)))

                    Text(pair.element)
                        .font(.label(14))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface.opacity(0.55), in: .rect(cornerRadius: Metrics.radius, style: .continuous))
    }

    private func liveCheck(title: String, done: Bool) -> some View {
        HStack(spacing: Metrics.snug) {
            StatusDot(ok: done)
            Text(title)
                .font(.label(14, weight: .medium))
                .foregroundStyle(done ? .white : Palette.dim)
            Spacer()
        }
        .padding(14)
        .background(
            (done ? Palette.ok.opacity(0.10) : Palette.surface.opacity(0.6)),
            in: .rect(cornerRadius: Metrics.radius, style: .continuous)
        )
        .animation(.smooth(duration: 0.35), value: done)
    }

    private func page<Body: View, Actions: View>(
        symbol: String,
        title: String,
        @ViewBuilder body: () -> Body,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.loose) {
            ZStack {
                Circle().fill(Palette.accent.opacity(0.13)).frame(width: 72, height: 72)
                Image(systemName: symbol)
                    .font(.system(.title, weight: .semibold))
                    .foregroundStyle(Palette.accent)
            }

            VStack(alignment: .leading, spacing: Metrics.snug) {
                Text(title)
                    .font(.label(30, weight: .bold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    body()
                }
                .font(.label(15))
                .foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)
            }

            actions()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func advance() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        withAnimation(.smooth(duration: 0.4)) {
            index = min(index + 1, max(plan.count - 1, 0))
        }
    }

    private func back() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        withAnimation(.smooth(duration: 0.4)) { index = max(index - 1, 0) }
    }
}

/// Lets a conditional pick between two button styles without the compiler
/// complaining that the branches differ.
struct AnyButtonStyleBox: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { configuration in AnyView(style.makeBody(configuration: configuration)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
