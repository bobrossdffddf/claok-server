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
///
/// Layout follows the system setup flows: a centred symbol, title and at most
/// two short paragraphs, the live check, the exact taps, and one prominent
/// button pinned to the bottom with at most one quiet text action under it.
/// Anything rarer than that lives in the "Other options" menu.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(LicenseController.self) private var licensing

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
    @State private var showsLicenceEntry = false

    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 56

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
        NavigationStack {
            ScrollView {
                content
                    .padding(.horizontal, Metrics.loose)
                    .padding(.top, Metrics.tight)
                    .padding(.bottom, Metrics.loose)
                    .frame(maxWidth: .infinity)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                    .id(step)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Palette.ground.ignoresSafeArea())
            .onboardingActionBar(visible: hasActions) {
                actions
                    .id(step)
                    .transition(.opacity)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { chrome }
        }
        .tint(Palette.accent)
        .preferredColorScheme(.dark)
        #if DEBUG
        .task { seedTourState() }
        #endif
        .sheet(isPresented: $showsRemotePairing, onDismiss: { model.refreshPairingState() }) {
            PairWithoutComputerView()
        }
        // The setup files are fetched with the licence's signed token, so a
        // missing licence is fixed here and not by retrying the download.
        .sheet(isPresented: $showsLicenceEntry, onDismiss: {
            guard LicenseStore.savedToken != nil || TrialController.shared.isChosen else { return }
            Task { await model.fetchDeveloperImage() }
        }) {
            LicenseView()
                .presentationDragIndicator(.visible)
        }
        .onChange(of: licensing.token) { _, token in
            if token != nil { showsLicenceEntry = false }
        }
        .onChange(of: licensing.state) { _, state in
            if state == .trial { showsLicenceEntry = false }
        }
        .sheet(isPresented: $showsScanner) {
            PairingScannerView { data in
                showsScanner = false
                Task { await model.importSetup(data: data) }
            }
            .ignoresSafeArea()
            .overlay(alignment: .topTrailing) {
                ScannerCloseButton { showsScanner = false }
                    .padding(Metrics.regular)
            }
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
    }

    #if DEBUG
    /// Screenshot tours only, so the states a finger would have to reach can
    /// be captured: CLOAK_TOUR_TRUST=busy|trouble seeds the trust step's own
    /// pairing progress, and CLOAK_TOUR_OUTWARD=1 draws the iOS 27 variant of
    /// that step on an older simulator. Nothing is sent anywhere.
    private func seedTourState() {
        let env = ProcessInfo.processInfo.environment
        guard env["CLOAK_TOUR"] == "onboarding" else { return }
        switch env["CLOAK_TOUR_TRUST"] {
        case "busy":
            pairingBusy = true
            pairingStage = "Look at your screen and tap Trust"
        case "trouble":
            pairingTrouble = "Pairing did not finish. Try again, or use one of the other ways below."
        default:
            break
        }
    }
    #endif

    /// Which way round this phone pairs. Always the system's answer outside
    /// debug builds.
    private var pairsOutward: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLOAK_TOUR"] == "onboarding",
           ProcessInfo.processInfo.environment["CLOAK_TOUR_OUTWARD"] == "1" {
            return true
        }
        #endif
        return RemotePairing.usesPairableHost
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

    /// A system toolbar: the back chevron where there is somewhere to go back
    /// to, and a plain progress bar in the middle. The step count is spoken
    /// rather than printed.
    @ToolbarContentBuilder
    private var chrome: some ToolbarContent {
        if index > 0 {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: back) {
                    Label("Back", systemImage: "chevron.backward")
                }
                .tint(.primary)
            }
        }

        ToolbarItem(placement: .principal) {
            ProgressView(value: progressValue, total: progressTotal)
                .frame(width: 140)
                .accessibilityLabel("Setup progress")
                .accessibilityValue("Step \(index + 1) of \(max(plan.count, 1))")
        }

        if hasMoreMenu {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    moreMenuItems
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .tint(.primary)
            }
        }
    }

    /// The rarer ways forward. The one somebody needs when the automatic path
    /// fails always stays on screen under the main button; only the
    /// alternatives to it live up here.
    private var hasMoreMenu: Bool {
        switch step {
        case .getTunnelApp: !model.reflector.localDevVPNInstalled
        case .trust: !model.hasAnyPairing
        default: false
        }
    }

    @ViewBuilder
    private var moreMenuItems: some View {
        switch step {
        case .getTunnelApp:
            Button("Use the App Store instead", systemImage: "bag") {
                model.reflector.openAppStoreForLocalDevVPN()
            }
        case .trust:
            fileOptions
        default:
            EmptyView()
        }
    }

    private var progressTotal: Double { Double(max(plan.count, 1)) }
    private var progressValue: Double { min(Double(index + 1), progressTotal) }

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
            }
        } details: {
            if !model.hasAnyPairing {
                footnote("Every screen asks for one thing and tells you exactly what to tap. When it is done, it moves on by itself.")
            }
        }
    }

    private var handoff: some View {
        page(symbol: "checkmark.seal.fill", title: "Already paired") {
            Text("The installer on your computer handed Cloak the key it needs, so there is no code to type and no restart to sit through.")
        } details: {
            liveCheck(title: "Paired with this phone", done: model.hasAnyPairing)
        }
    }

    private var getTunnelApp: some View {
        let installed = model.reflector.localDevVPNInstalled

        return page(symbol: "arrow.down.app.fill", title: "Get the free helper app") {
            Text("iOS will not let an app reach this phone's own developer tools directly. A small free app called LocalDevVPN makes it possible.")
            Text("It does that one job. Nothing is proxied and no traffic leaves this phone.")
        } details: {
            liveCheck(
                title: installed ? "LocalDevVPN is installed" : "Not installed yet",
                done: installed
            )

            if !installed {
                tapList([
                    "Tap Install it here. A panel slides up from the bottom.",
                    "Tap GET, then confirm the way you normally install apps.",
                    "Wait for it to finish. Do not open it, just come back here.",
                ])
            }
        }
    }

    private var turnTunnelOn: some View {
        let running = model.reflector.isUp

        return page(symbol: "shield.lefthalf.filled", title: "Switch the tunnel on") {
            Text("One tap. Cloak opens LocalDevVPN, turns it on, and comes straight back here.")
        } details: {
            liveCheck(title: running ? "Tunnel is running" : "Tunnel is off", done: running)

            if !running, let problem = model.reflectorProblem {
                troubleLabel(problem)
            }

            if !running {
                tapList([
                    "The first time only, iOS asks to add a VPN configuration.",
                    "Tap Allow, then enter this phone's passcode.",
                    "You will land back in Cloak on your own.",
                ])
            }
        }
    }

    private var allowTunnel: some View {
        let running = model.reflector.isUp

        return page(symbol: "shield.lefthalf.filled", title: "Allow the tunnel") {
            Text("iOS will not answer a connection this phone makes to itself, so Cloak loops it back through a tunnel of its own.")
            Text("Nothing is proxied, nothing is recorded, and no traffic leaves this phone.")
        } details: {
            liveCheck(title: running ? "Tunnel is running" : "Tunnel is off", done: running)

            if !running, let problem = model.reflectorProblem {
                troubleLabel(problem)
            }

            if !running {
                tapList([
                    "iOS asks to add a VPN configuration.",
                    "Tap Allow, then enter this phone's passcode.",
                ])
            }
        }
    }

    private var trust: some View {
        let paired = model.hasAnyPairing
        let outward = pairsOutward

        return page(
            symbol: "hand.tap.fill",
            title: outward ? "Pair this phone with Cloak" : "Tap Trust on this phone"
        ) {
            if outward {
                Text("Cloak shows a six digit code. You type it into the iOS prompt, and the pairing is kept for good, even across reinstalls.")
                Text("This works on cellular. Usually with nothing extra. If a link ever will not come up, switch the Wi-Fi radio on without joining any network.")
            } else {
                Text("Cloak asks this phone to pair with itself. iOS puts its own alert on screen, the same one it shows when you plug into a computer.")
            }
        } details: {
            VStack(spacing: Metrics.tight) {
                liveCheck(title: paired ? "Paired with this phone" : "Not paired yet", done: paired)

                // The tunnel has to be running before pairing can begin:
                // without it iOS resets the connection before a byte comes
                // back, and the failure reads as though pairing is broken.
                if !paired && outward {
                    let tunnelUp = model.reflector.isUp
                    liveCheck(title: tunnelUp ? "Tunnel is running" : "Tunnel is off", done: tunnelUp)
                }
            }

            if !paired && outward {
                if !model.reflector.isUp, let problem = model.reflectorProblem {
                    troubleLabel(problem)
                }

                tapList([
                    "Tap Start below and leave Cloak open.",
                    "Open Settings, Privacy & Security, Developer Mode. Under Other Devices tap \"\(RemotePairing.hostNameForDisplay)\".",
                    "Type the six digit code Cloak shows you.",
                ])

                footnote("From iOS 27 the phone pairs outward, to a computer that says it is pairable. Cloak says it is one.")
            } else if !paired {
                tapList([
                    "Tap Start below.",
                    "An alert appears asking whether to trust this computer. Tap Trust.",
                    "Type this phone's passcode.",
                ])

                if let stage = pairingStage {
                    Label {
                        Text(stage)
                    } icon: {
                        ProgressView().controlSize(.small)
                    }
                    .font(.callout)
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let trouble = pairingTrouble {
                    troubleLabel(trouble)
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

    private var imageBusy: Bool {
        if case .working = model.imageDelivery.state { return true }
        return false
    }

    private var imageFailure: String? {
        if case .failed(let reason) = model.imageDelivery.state { return reason }
        return nil
    }

    /// The download failed because there was no signed token to ask with:
    /// no saved licence, and no trial token either. `ImageDelivery` refuses
    /// before touching the network in exactly that case.
    private var imageNeedsLicence: Bool {
        imageFailure != nil
            && LicenseStore.savedToken == nil
            && TrialController.shared.token == nil
    }

    private var setupFiles: some View {
        let failure = imageFailure

        return page(symbol: "arrow.down.circle", title: "Get the setup files") {
            Text("iOS keeps its location simulator behind a signed file from Apple and will not offer it until that file is loaded.")
            Text("Cloak is downloading it now. About sixteen megabytes, once, and then never again.")
        } details: {
            liveCheck(title: model.imageDelivery.detail, done: model.hasDeveloperImage, trouble: failure != nil)

            if case .working(_, let fraction) = model.imageDelivery.state {
                ProgressView(value: fraction)
                    .frame(maxWidth: 240)
            }

            // The check above already reads the failure when there is one, so
            // it is only repeated here if it says something different.
            if let failure, failure != model.imageDelivery.detail {
                troubleLabel(failure)
            }

            // On the trial the token comes from the trial server, so when it
            // is missing the reason is whatever that server said.
            if imageNeedsLicence, TrialController.shared.isChosen, let trialProblem = TrialController.shared.problem {
                footnote("The free trial could not be confirmed: \(trialProblem)")
            }
        }
        .task {
            guard !model.hasDeveloperImage, model.imageDelivery.state == .idle else { return }
            await model.fetchDeveloperImage()
        }
    }

    private var location: some View {
        let allowed = model.locationAuthorization == .authorizedAlways

        return page(symbol: "location.fill", title: "Let Cloak use your location") {
            Text("On Always, a drive keeps going with the phone locked or another app open.")
            Text("On While Using, the simulation freezes the moment you leave Cloak.")
        } details: {
            liveCheck(
                title: allowed ? "Set to Always" : "Not set to Always yet",
                done: allowed
            )

            if !allowed {
                if locationRefused {
                    tapList([
                        "Tap Open Settings below.",
                        "Tap Location.",
                        "Tap Always.",
                    ])
                } else {
                    tapList([
                        "Tap Allow below.",
                        "Choose Allow While Using App first. iOS insists on that one.",
                        "Cloak will ask again shortly. Choose Change to Always.",
                    ])
                }
            }
        }
    }

    private var locationRefused: Bool {
        model.locationAuthorization == .denied
            || model.locationAuthorization == .restricted
    }

    private var ready: some View {
        page(symbol: "checkmark.seal.fill", title: "You are set up") {
            Text("Search a place and go straight there, or add two stops and drive between them at a believable speed.")
            Text("You can run this walkthrough again any time from Settings.")
        } details: {
            EmptyView()
        }
    }

    // MARK: - Actions

    /// Whether the bottom bar has anything in it for this step. Kept next to
    /// `actions` so the two are read together.
    private var hasActions: Bool {
        switch step {
        case .welcome, .handoff, .getTunnelApp, .ready: true
        case .turnTunnelOn, .allowTunnel: !model.reflector.isUp
        case .trust: !model.hasAnyPairing
        case .setupFiles: imageFailure != nil || (!model.hasDeveloperImage && !imageBusy)
        case .location: model.locationAuthorization != .authorizedAlways
        }
    }

    /// One prominent button per step, and at most one quiet one under it.
    @ViewBuilder
    private var actions: some View {
        switch step {
        case .welcome:
            primary("Start") { advance() }

        case .handoff:
            primary("Continue") { advance() }

        case .getTunnelApp:
            if !model.reflector.localDevVPNInstalled {
                primary("Install it here", systemImage: "arrow.down.app") {
                    model.reflector.presentLocalDevVPNSheet()
                }

                // The check above can lag behind an install iOS has not told
                // us about yet. The next step opens LocalDevVPN for real,
                // which is the authoritative test, so never hold anyone here
                // on the strength of a stale answer. The App Store link is in
                // the More menu at the top.
                secondary("I have installed it, continue") { advance() }
            } else {
                primary("Continue") { advance() }
            }

        case .turnTunnelOn:
            if !model.reflector.isUp {
                primary("Turn it on") {
                    Task { _ = await model.ensureTunnelUp() }
                }

                secondary(model.reflector.trouble == .needsLocalDevVPN ? "Get LocalDevVPN from the App Store" : "It did not come back") {
                    model.reflector.openAppStoreForLocalDevVPN()
                }
            }

        case .allowTunnel:
            if !model.reflector.isUp {
                primary("Allow the tunnel") {
                    Task { _ = await model.ensureTunnelUp() }
                }
            }

        case .trust:
            if !model.hasAnyPairing && pairsOutward {
                if model.reflector.isUp {
                    primary("Start") { showsRemotePairing = true }
                } else {
                    primary("Turn the tunnel on first") {
                        Task { _ = await model.ensureTunnelUp() }
                    }
                    // If the tunnel will not come up, the pairing screen says
                    // why and offers a way on without it. That must not sit
                    // behind a menu.
                    secondary("Show me the other ways") { showsRemotePairing = true }
                }
            } else if !model.hasAnyPairing {
                Button {
                    Task { await runPairing() }
                } label: {
                    HStack(spacing: Metrics.tight) {
                        if pairingBusy {
                            ProgressView().controlSize(.small)
                        }
                        Text(pairingBusy ? "Waiting for you" : "Start")
                    }
                    .font(.headline)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(pairingBusy)

                // The way forward when the Trust alert does not work out,
                // kept on screen rather than in a menu.
                secondary("Show me the other ways") { showsRemotePairing = true }
            }

        case .setupFiles:
            if imageNeedsLicence && !TrialController.shared.isChosen {
                // Retrying cannot produce a licence, so the button goes to
                // the thing that does.
                primary("Enter a licence", systemImage: "key") { showsLicenceEntry = true }
                secondary("Try it free, 10 minutes a day") {
                    Task {
                        await licensing.startTrial()
                        await model.fetchDeveloperImage()
                    }
                }
            } else if imageFailure != nil {
                // A real download failure, or a trial token the trial server
                // did not hand over: asking again is the fix for both.
                primary("Try again") {
                    Task { await model.fetchDeveloperImage() }
                }
                .disabled(imageBusy)

                // Without a saved licence the server may also be turning the
                // trial's token away, which no retry fixes. Entering a
                // licence does, so it stays in reach.
                if LicenseStore.savedToken == nil {
                    secondary("Enter a licence") { showsLicenceEntry = true }
                }
            } else if !model.hasDeveloperImage && !imageBusy {
                primary("Download") {
                    Task { await model.fetchDeveloperImage() }
                }
            }

        case .location:
            if model.locationAuthorization != .authorizedAlways {
                if locationRefused {
                    primary("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } else {
                    primary("Allow") { model.requestAlwaysLocation() }
                }

                secondary("Skip for now") { advance() }
            }

        case .ready:
            primary("Open Cloak") { model.completeOnboarding() }
        }
    }

    @ViewBuilder
    private var fileOptions: some View {
        Section("I have a file from a computer") {
            Button("Scan a QR code from a Mac", systemImage: "qrcode.viewfinder") { showsScanner = true }
            Button("Import a file", systemImage: "doc") { showsImporter = true }
        }
    }

    // MARK: - Pieces

    private func primary(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) -> some View {
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

    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
    }

    /// A failure, in words, next to the thing it failed at.
    private func troubleLabel(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(Palette.warn)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The exact taps, in order, in the words that appear on the phone.
    private func tapList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: Metrics.snug) {
            ForEach(Array(items.enumerated()), id: \.offset) { pair in
                Label {
                    Text(pair.element)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "\(pair.offset + 1).circle.fill")
                        .foregroundStyle(.tint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.callout)
        .multilineTextAlignment(.leading)
        .padding(Metrics.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    /// The live check. Shape as well as colour: a tick when it has happened,
    /// a dashed ring while it has not.
    private func liveCheck(title: String, done: Bool, trouble: Bool = false) -> some View {
        Label {
            Text(title)
                .foregroundStyle(done || trouble ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: done ? "checkmark.circle.fill" : trouble ? "exclamationmark.triangle.fill" : "circle.dashed")
                .foregroundStyle(done ? AnyShapeStyle(Palette.ok) : trouble ? AnyShapeStyle(Palette.warn) : AnyShapeStyle(.secondary))
        }
        .font(.subheadline.weight(.semibold))
        .multilineTextAlignment(.center)
        .animation(.smooth(duration: 0.35), value: done)
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "Done" : "Not done yet")
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }

    private func page<Body: View, Details: View>(
        symbol: String,
        title: String,
        @ViewBuilder body: () -> Body,
        @ViewBuilder details: () -> Details
    ) -> some View {
        VStack(spacing: Metrics.loose) {
            VStack(spacing: Metrics.regular) {
                Image(systemName: symbol)
                    .font(.system(size: heroSize))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(minHeight: heroSize + 8)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.title.bold())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                VStack(spacing: Metrics.tight) {
                    body()
                }
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: Metrics.regular) {
                details()
            }
        }
        .frame(maxWidth: .infinity)
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

// MARK: - Scanner chrome

/// The camera fills the sheet, so the one control on it floats: system glass
/// on iOS 26, a material circle before it. Swiping the sheet down still works.
private struct ScannerCloseButton: View {
    var action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(role: .close, action: action) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .tint(.primary)
            .accessibilityLabel("Close")
        } else {
            Button(action: action) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }
}

// MARK: - Bottom bar

private extension View {
    /// Pins the step's buttons to the bottom, as a system bar on iOS 26 and a
    /// safe area inset before it, over a solid backdrop.
    @ViewBuilder
    func onboardingActionBar<Bar: View>(visible: Bool, @ViewBuilder _ bar: () -> Bar) -> some View {
        let content = VStack(spacing: Metrics.hair) { bar() }
            .padding(.horizontal, Metrics.loose)
            .padding(.top, Metrics.snug)
            .padding(.bottom, Metrics.tight)
            .background { ActionBarBackdrop() }

        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom) {
                if visible { content }
            }
        } else {
            safeAreaInset(edge: .bottom) {
                if visible {
                    content
                }
            }
        }
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
