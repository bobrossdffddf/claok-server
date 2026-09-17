import SwiftUI
import CloakKit

// This file used to hold the tabbed sheet that sat under the map. The sheet is
// gone: the map opens one floating card at a time (see MapScreen, MapToolRail
// and FloatingCard). What is left here is what outlived it: the card shown
// while something runs, the check on what needs attention, and the feed that
// keeps the exposure check pointed at the place being reported.

// MARK: - Running

/// The one card while something is being simulated.
///
/// Collapsed it is a single header: what is running and how fast, a thin
/// progress line on a route, pause, and Stop. Tap it or drag it up and the
/// driving controls open beneath the same header, with no second title, and
/// the stop that also disconnects the tunnel at the very bottom.
struct RunningCard: View {
    @Environment(AppModel.self) private var model
    var expanded: Bool
    var onToggle: () -> Void

    @State private var showsJourney = false

    private var journey: JourneyController { JourneyController.shared }

    var body: some View {
        VStack(spacing: 0) {
            header
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onEnded { value in
                            let up = value.translation.height < -24
                            let down = value.translation.height > 24
                            if (up && !expanded) || (down && expanded) { onToggle() }
                        }
                )

            if expanded {
                CardScroll(topPadding: Metrics.tight) {
                    VStack(spacing: Metrics.regular) {
                        DriveControls()

                        if journey.isRunning {
                            CardGroup {
                                GroupActionRow(title: "Trip itinerary", symbol: "airplane") {
                                    showsJourney = true
                                }
                            }
                        }

                        Button(role: .destructive) {
                            Task { await model.panic() }
                            UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        } label: {
                            Text("Stop and disconnect")
                                .font(.body)
                                .foregroundStyle(Palette.danger)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityHint("Stops everything and turns the tunnel off")
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .cardSurface()
        .sheet(isPresented: $showsJourney) {
            if let pin = journey.destinationPin { JourneyView(pin: pin) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Metrics.tight + 2) {
            HStack(spacing: Metrics.snug) {
                Button(action: onToggle) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(Color(.label))
                            .lineLimit(1)
                        subtitle
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint(expanded ? "Hides the driving controls" : "Shows the driving controls")

                Button {
                    Task { await model.togglePause() }
                } label: {
                    Image(systemName: model.snapshot.isPaused ? "play.fill" : "pause.fill")
                        .font(.body)
                        .foregroundStyle(Color(.label))
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.14), in: Circle())
                        .contentShape(.circle)
                }
                .buttonStyle(PressableStyle(scale: 0.92))
                .accessibilityLabel(model.snapshot.isPaused ? "Resume" : "Pause")

                Button {
                    Task { await model.stop() }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: {
                    Text("Stop")
                        .font(.headline)
                        .foregroundStyle(Palette.danger)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 44)
                        .background(Palette.danger.opacity(0.18), in: Capsule())
                        .contentShape(.capsule)
                }
                .buttonStyle(PressableStyle(scale: 0.95))
                .accessibilityLabel("Stop, back to my real location")
            }

            trialLine

            if case .route = model.snapshot.mode {
                ProgressView(value: model.snapshot.progress)
                    .tint(Palette.accent)
                    .scaleEffect(x: 1, y: 0.75, anchor: .center)
                    .accessibilityLabel("Route progress")
            }
        }
        .padding(.horizontal, CardMetrics.padding)
        .padding(.vertical, Metrics.snug)
    }

    /// The free minutes counting down, for a free licence only. A paid one
    /// has no trial, so this is absent rather than saying something reassuring
    /// that nobody needs to read while driving.
    @ViewBuilder
    private var trialLine: some View {
        if let remaining = TrialPreview.remaining {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let left = TrialPreview.live(remaining)
                Text(left <= 0 ? "Free minutes used up" : "Free: \(TrialController.format(left)) left today")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(left <= 120 ? Palette.warn : Color(.secondaryLabel))
                    .lineLimit(1)
            }
        }
    }

    /// A believable trip under way names its leg; anything else names the run.
    private var title: String {
        if journey.isRunning, let leg = journey.currentLeg { return leg.name }
        return model.snapshot.mode.title
    }

    @ViewBuilder
    private var subtitle: some View {
        if model.snapshot.isPaused {
            Text("Paused")
                .font(.subheadline)
                .foregroundStyle(Palette.warn)
        } else if model.snapshot.mode.isMoving {
            // The longest version that fits, dropping the least important
            // number each time, rather than an ellipsis through one.
            let variants = telemetryVariants
            ViewThatFits(in: .horizontal) {
                ForEach(variants.indices, id: \.self) { index in
                    Text(variants[index])
                        .font(.live(.subheadline, weight: .regular))
                        .foregroundStyle(Color(.secondaryLabel))
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(variants.first ?? "")
        } else if let fix = model.snapshot.fix {
            Text(String(format: "%.5f, %.5f", fix.coordinate.latitude, fix.coordinate.longitude))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Color(.secondaryLabel))
                .lineLimit(1)
        } else {
            Text("Starting")
                .font(.subheadline)
                .foregroundStyle(Color(.secondaryLabel))
        }
    }

    /// Every number the run has, then the same list with the last one taken
    /// off, down to the speed alone. The limit is last, since the dial shows
    /// it.
    private var telemetryVariants: [String] {
        var parts = ["\(Int(Speed.toMph(model.snapshot.fix?.speed ?? 0).rounded())) mph"]
        if let remaining = model.snapshot.distanceRemaining {
            parts.append("\(Units.distance(remaining)) left")
        }
        if let next = model.snapshot.nextStopDistance {
            parts.append("next stop \(Units.distance(next))")
        }
        if let limit = model.snapshot.speedLimit, limit > 0 {
            parts.append("limit \(Int(Speed.toMph(limit).rounded()))")
        }
        return (1...parts.count).reversed().map { parts.prefix($0).joined(separator: ", ") }
    }
}

// MARK: - Needs attention

/// Something outside the map that needs doing soon. These used to be capsules
/// floating over the map; now they put a dot on the settings button and are
/// listed at the top of Settings, each opening what its capsule opened.
enum AttentionItem: Identifiable, Equatable {
    /// The link to the phone is down, with what went wrong. Opens Diagnostics.
    case link(String)
    /// On cellular without the relink shortcut. Opens the cellular setup.
    case cellular
    /// The signature lapses within two days, or already has. Opens Signing.
    case signing(daysLeft: Int, expired: Bool)
    /// Free minutes nearly gone, or gone. Opens the unlock screen.
    case trial(remaining: TimeInterval)

    var id: String {
        switch self {
        case .link: "link"
        case .cellular: "cellular"
        case .signing: "signing"
        case .trial: "trial"
        }
    }

    var title: String {
        switch self {
        case .link: "Link problem"
        case .cellular: "Set up relinking"
        case .signing(let days, let expired): expired ? "Signature expired" : "Signature ends in \(days) \(days == 1 ? "day" : "days")"
        case .trial(let remaining): remaining <= 0 ? "Free minutes used up" : "Free minutes almost gone"
        }
    }

    @MainActor
    var detail: String {
        switch self {
        case .link(let message): message
        case .cellular: "Keeps the link up off Wi-Fi"
        case .signing(_, let expired): expired ? "Refresh to keep using Cloak" : "Refresh now or set auto refresh"
        case .trial(let remaining): remaining <= 0 ? "Unlock to keep going today" : "\(TrialController.format(remaining)) left today"
        }
    }

    var symbol: String {
        switch self {
        case .link: "exclamationmark.triangle.fill"
        case .cellular: "antenna.radiowaves.left.and.right.slash"
        case .signing: "signature"
        case .trial: "hourglass"
        }
    }

    /// What puts the red dot on the settings button.
    ///
    /// Everything `current` finds except signing, which has its own ring on
    /// the rail now: a dot on Settings saying the same thing as a ring two
    /// inches away is the kind of doubling this screen keeps being trimmed of.
    @MainActor
    static func badge(model: AppModel) -> [AttentionItem] {
        current(model: model).filter { $0.id != "signing" }
    }

    /// Everything that needs attention now, most urgent first.
    @MainActor
    static func current(model: AppModel) -> [AttentionItem] {
        var items: [AttentionItem] = []
        if let message = model.snapshot.linkMessage { items.append(.link(message)) }
        if let info = SignatureInfo.fromBundle(), info.hasExpired || info.isUrgent {
            items.append(.signing(daysLeft: info.daysLeft, expired: info.hasExpired))
        }
        if CellularAssist.shared.needsShortcutNow { items.append(.cellular) }
        let trial = TrialController.shared
        if trial.isActive, trial.liveRemaining < 120 {
            items.append(.trial(remaining: trial.liveRemaining))
        }
        return items
    }
}

// MARK: - Exposure

/// Keeps the exposure check pointed at the place being reported: the running
/// fix when there is one, otherwise the dropped pin, and where a running
/// route says it ends. The rail's exposure button shows what it finds.
struct ExposureFeed: ViewModifier {
    @Environment(AppModel.self) private var model
    var selection: Coordinate?

    func body(content: Content) -> some View {
        content
            .onAppear { feed() }
            .onChange(of: currentPin) { _, _ in feed() }
            .onChange(of: model.snapshot.isRunning) { _, _ in feed() }
            .onChange(of: model.snapshot.fix?.speed) { _, _ in feed() }
    }

    private var currentPin: Coordinate? {
        if model.snapshot.isRunning, let fix = model.snapshot.fix { return fix.coordinate }
        return selection
    }

    /// The cover report is about whether the story holds up, and the story is
    /// where the trip is going. A joystick run, a replay and SHIELD have no
    /// settled destination, so the live fix is graded instead.
    private var routeEnd: Coordinate? {
        guard model.snapshot.isRunning, case .route = model.snapshot.mode else { return nil }
        return model.routeWaypoints.last?.coordinate
    }

    private func feed() {
        let exposure = ExposureController.shared
        exposure.track(pin: currentPin, destination: routeEnd)
        exposure.track(simulating: model.snapshot.isRunning, speed: model.snapshot.fix?.speed ?? 0)
    }
}

// MARK: - Trial

/// What the running card shows about the free trial, and nothing more.
///
/// `TrialController.isActive` is already "a free licence that has been
/// chosen", so a paid or unlocked copy never reaches the line at all. The
/// override exists only for screenshots, and only in debug builds: the trial
/// endpoints are not on the server yet, so a simulator reports no minutes.
enum TrialPreview {
    #if DEBUG
    /// Seconds to pretend are left, from CLOAK_TOUR_TRIAL.
    nonisolated(unsafe) static var override: TimeInterval?
    #endif

    @MainActor
    static var remaining: TimeInterval? {
        #if DEBUG
        if let override { return override }
        #endif
        let trial = TrialController.shared
        return trial.isActive ? trial.liveRemaining : nil
    }

    /// The live value, so the line ticks while a run eats into it.
    @MainActor
    static func live(_ fallback: TimeInterval) -> TimeInterval {
        #if DEBUG
        if override != nil { return fallback }
        #endif
        return TrialController.shared.liveRemaining
    }
}

// MARK: - Signing

/// The seven day signing clock the rail draws, with the same urgency rules
/// `AttentionItem` uses.
enum SigningPreview {
    /// What the bundle says, read once and cached by `SignatureInfo` itself.
    /// A build with no provisioning profile has no signature, and the rail
    /// then shows no ring.
    static var current: SignatureInfo? { SignatureInfo.fromBundle() }
}
