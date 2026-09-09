import SwiftUI
import CoreLocation
import UniformTypeIdentifiers
import CloakKit

/// Setup, one small thing at a time.
///
/// Deliberately more steps than strictly necessary. Each screen asks for a
/// single action, says what will happen before it happens, and will not move on
/// until the thing has actually happened. Length is cheaper than confusion.
///
/// The route through it is not fixed. A copy installed from a computer arrives
/// already paired, so the whole pairing chapter is dropped rather than shown
/// and ticked off. A copy signed with a free Apple ID has no tunnel of its own
/// and gets the LocalDevVPN step instead of the VPN prompt.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    @State private var plan: [Step] = [.welcome]
    @State private var index = 0
    @State private var showsRemotePairing = false
    @State private var showsScanner = false
    @State private var showsImporter = false
    @State private var glow = false

    enum Step: Hashable {
        case welcome
        case how
        case handoff
        case developerImage
        case wifi
        case pairIntro
        case pairing
        case tunnel
        case localDevVPN
        case background
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
        .task {
            plan = buildPlan()
            withAnimation(.smooth(duration: 0.9)) { glow = true }
        }
    }

    // MARK: - The route

    private func buildPlan() -> [Step] {
        var steps: [Step] = [.welcome]

        if model.hasAnyPairing {
            // The computer that installed Cloak handed over its pairing
            // record and turned Developer Mode on along the way, so there is
            // nothing to pair, no code to type, and nothing to say about a
            // switch that is already on.
            steps.append(.handoff)
        } else {
            // Nobody has done any of it, so the no-computer route explains
            // Developer Mode where it actually has to be explained.
            steps += [.how, .wifi, .pairIntro, .pairing]
        }

        // The tunnel comes next, because it is the one thing left that needs
        // the user to go and get something.
        steps.append(model.reflector.provider == .localDevVPN ? .localDevVPN : .tunnel)

        if !model.hasDeveloperImage {
            steps.append(.developerImage)
        }
        steps += [.background, .ready]
        return steps
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
                        .font(.system(size: 14, weight: .bold))
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

            Text("\(index + 1) of \(max(plan.count, 1))")
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
        case .how: how
        case .handoff: handoff
        case .developerImage: developerImage
        case .wifi: wifi
        case .pairIntro: pairIntro
        case .pairing: pairing
        case .tunnel: tunnel
        case .localDevVPN: localDevVPN
        case .background: backgroundStep
        case .ready: ready
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        page(symbol: "location.viewfinder", title: "Put your phone anywhere") {
            Text("Cloak changes the location this device reports to every app on it.")
            if model.hasAnyPairing {
                Text("The computer you installed from already did the hard part. Two short steps and you are running.")
            } else {
                Text("Setup takes about five minutes and happens once. No cable, no computer, nothing jailbroken.")
            }
        } actions: {
            Button("Get started") { advance() }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    private var how: some View {
        page(symbol: "gearshape.2.fill", title: "How it works") {
            Text("Apple ships a location simulator inside iOS for developers. It is normally driven from a Mac over a cable.")
            Text("Cloak reaches it from the phone itself. That takes three things, and the next few screens set each one up.")
        } actions: {
            VStack(spacing: Metrics.tight) {
                preview(1, "Pair your phone with Cloak", "A six digit code, once")
                preview(2, "Add one free app", "LocalDevVPN, so iOS will answer the phone itself")
                preview(3, "Fetch the setup files", "About sixteen megabytes, once")

                Button("Makes sense") { advance() }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, Metrics.tight)
            }
        }
    }

    private var handoff: some View {
        page(symbol: "checkmark.seal.fill", title: "Already paired") {
            Text("The installer on your computer handed Cloak the key it needs, so there is no code to type and no restart to sit through.")
            Text("One thing left to switch on, then you are done.")
        } actions: {
            VStack(spacing: Metrics.snug) {
                liveCheck(title: "Paired with this phone", done: model.hasAnyPairing)
                liveCheck(title: "Developer image ready", done: model.hasDeveloperImage)

                Button("Continue") { advance() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var developerImage: some View {
        page(symbol: "arrow.down.circle", title: "Fetch the setup files") {
            Text("iOS keeps its location simulator behind a signed image from Apple, and will not offer the service until that image is mounted.")
            Text("Cloak downloads it now, once, and keeps it. About sixteen megabytes.")
        } actions: {
            VStack(spacing: Metrics.snug) {
                liveCheck(title: model.imageDelivery.detail, done: model.hasDeveloperImage)

                if case .working(_, let fraction) = model.imageDelivery.state {
                    ProgressView(value: fraction).tint(Palette.accent)
                }

                if model.hasDeveloperImage {
                    Button("Continue") { advance() }
                        .buttonStyle(PrimaryButtonStyle())
                } else {
                    Button("Download") {
                        Task { await model.fetchDeveloperImage() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
    }

    private var wifi: some View {
        page(symbol: "wifi", title: "Turn on Wi-Fi") {
            Text("iOS only offers the service Cloak needs while the phone has a Wi-Fi connection.")
            Text("It does not have to join a network, and Personal Hotspot counts. You only need it while connecting, not while a simulation runs.")
        } actions: {
            VStack(spacing: Metrics.snug) {
                liveCheck(
                    title: model.hasLocalNetwork ? "Wi-Fi is on" : "Wi-Fi is off",
                    done: model.hasLocalNetwork
                )

                Button("Open Settings") {
                    if let url = URL(string: "App-prefs:root=WIFI") {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(QuietButtonStyle())

                Button("Continue") { advance() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.hasLocalNetwork)
                    .opacity(model.hasLocalNetwork ? 1 : 0.4)
            }
        }
    }

    private var pairIntro: some View {
        page(symbol: "iphone.radiowaves.left.and.right", title: "Now pair your phone") {
            Text("Cloak briefly presents itself as a computer, and your phone pairs with it. Here is exactly what will happen.")
        } actions: {
            VStack(spacing: Metrics.tight) {
                preview(1, "Cloak starts advertising", "Leave it open, do not close it")
                preview(2, "You open Settings", "Privacy & Security, then Developer Mode")
                preview(3, "Tap Cloak under Other Devices", "Then tap Pair")
                preview(4, "Type the six digit code", "Cloak is showing it")

                Button("Start pairing") {
                    advance()
                    showsRemotePairing = true
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, Metrics.tight)
            }
        }
    }

    private var pairing: some View {
        page(symbol: "checkmark.shield.fill", title: "Pairing") {
            Text("The pairing screen walks you through it. Come back when it says it is done.")
        } actions: {
            VStack(spacing: Metrics.snug) {
                liveCheck(title: "Paired with this phone", done: model.hasAnyPairing)
                liveCheck(title: "Developer image ready", done: model.hasDeveloperImage)

                Button("Open pairing again") { showsRemotePairing = true }
                    .buttonStyle(QuietButtonStyle())

                Menu {
                    Button("Scan a QR code from a Mac") { showsScanner = true }
                    Button("Import a file") { showsImporter = true }
                } label: {
                    Text("Other ways to set up")
                        .font(.label(13, weight: .medium))
                        .foregroundStyle(Palette.dim)
                }

                Button("Continue") { advance() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.isSetupComplete)
                    .opacity(model.isSetupComplete ? 1 : 0.4)
            }
        }
    }

    private var tunnel: some View {
        page(symbol: "shield.lefthalf.filled", title: "Allow the local tunnel") {
            Text("iOS will not answer a connection the phone makes to itself, so Cloak routes it through a loopback tunnel.")
            Text("You will see a VPN prompt. Nothing is proxied, nothing is recorded, and no traffic leaves this phone.")
        } actions: {
            VStack(spacing: Metrics.snug) {
                liveCheck(title: "Tunnel running", done: model.reflector.isUp)

                Button("Allow the tunnel") {
                    Task {
                        _ = await model.ensureTunnelUp()
                        if model.reflector.isUp { advance() }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())

                Button("Skip for now") { advance() }
                    .buttonStyle(QuietButtonStyle())
            }
        }
    }

    private var localDevVPN: some View {
        let installed = model.reflector.localDevVPNInstalled
        let running = model.reflector.isUp

        return page(symbol: "shield.lefthalf.filled", title: "One free app to finish") {
            Text("iOS refuses a connection this phone makes to itself, so it has to be looped back through a tunnel first.")
            Text("Your copy of Cloak cannot carry that tunnel — Apple reserves it for paid developer accounts — so it uses LocalDevVPN, which is free and does exactly that one job.")
            Text("Nothing goes over the internet through it. Install it, switch it on once, and Cloak handles the rest from then on.")
        } actions: {
            VStack(spacing: Metrics.snug) {
                liveCheck(title: installed ? "LocalDevVPN installed" : "LocalDevVPN not installed yet", done: installed)
                liveCheck(title: running ? "Tunnel running" : "Tunnel not running", done: running)

                if !installed {
                    Button {
                        model.reflector.openAppStoreForLocalDevVPN()
                    } label: {
                        Label("Get LocalDevVPN, free", systemImage: "arrow.down.app")
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    Text("Open it once after installing and allow the VPN profile it asks for. Then come back here.")
                        .font(.label(12))
                        .foregroundStyle(Palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Button("Turn the tunnel on") {
                        Task { _ = await model.ensureTunnelUp() }
                    }
                    .buttonStyle(running ? AnyButtonStyleBox(QuietButtonStyle()) : AnyButtonStyleBox(PrimaryButtonStyle()))
                }

                Button(running ? "Continue" : "Continue anyway") { advance() }
                    .buttonStyle(running ? AnyButtonStyleBox(PrimaryButtonStyle()) : AnyButtonStyleBox(QuietButtonStyle()))
            }
        }
    }

    private var backgroundStep: some View {
        page(symbol: "moon.fill", title: "Keep it running") {
            Text("Set location access to Always and a drive carries on with your phone locked or another app open.")
            Text("On While Using, the simulation freezes the moment you leave Cloak.")
        } actions: {
            VStack(spacing: Metrics.snug) {
                liveCheck(
                    title: model.canRunInBackground ? "Set to Always" : "Not set to Always yet",
                    done: model.canRunInBackground
                )

                Button("Open Location settings") { model.openLocationSettings() }
                    .buttonStyle(model.canRunInBackground ? AnyButtonStyleBox(QuietButtonStyle()) : AnyButtonStyleBox(PrimaryButtonStyle()))

                Button(model.canRunInBackground ? "Continue" : "Continue anyway") { advance() }
                    .buttonStyle(model.canRunInBackground ? AnyButtonStyleBox(PrimaryButtonStyle()) : AnyButtonStyleBox(QuietButtonStyle()))
            }
        }
    }

    private var ready: some View {
        page(symbol: "checkmark.seal.fill", title: "You are set up") {
            Text("Search a place and teleport straight there, or add two stops and drive between them at a believable speed.")
            Text("You can run this walkthrough again any time from Settings.")
        } actions: {
            Button("Open Cloak") { model.completeOnboarding() }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: - Pieces

    private func preview(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Metrics.snug) {
            Text("\(number)")
                .font(.readout(12, weight: .bold))
                .foregroundStyle(Palette.accent)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Palette.accent.opacity(0.16)))

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.label(14, weight: .medium)).foregroundStyle(.white)
                Text(detail).font(.label(12)).foregroundStyle(Palette.dim)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
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
                    .font(.system(size: 29, weight: .semibold))
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
