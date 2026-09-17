import Foundation
import os
import Observation
import CoreLocation
import SwiftUI
import CloakKit

@MainActor
@Observable
final class AppModel: NSObject {
    var snapshot = SimulationSnapshot.stopped
    var linkState = DeviceLinkState()
    var realPosition: Coordinate?

    /// What CoreLocation is telling every app right now, this one included.
    /// During a simulation this is the simulated fix as iOS delivers it, which
    /// is the only honest answer to "will Life360 think I am driving": if
    /// speed comes back as -1 here, no app on the phone is seeing a speed.
    struct ObservedLocation: Equatable {
        var speed: Double
        var course: Double
        var horizontalAccuracy: Double
        var timestamp: Date
        /// Speed worked out from this fix and the one before it, in m/s. This
        /// is the number Life360 and friends actually use when iOS hands them
        /// -1, so it is the number that says whether a drive registers.
        var derivedSpeed: Double?
        var derivedCourse: Double?
        var coordinate: Coordinate
    }
    var observedLocation: ObservedLocation?
    private static let locationLog = Logger(subsystem: "app.cloak.ios", category: "observed-location")
    private static let driveLog = Logger(subsystem: "app.cloak.ios", category: "drive-plan")
    var isOnboarded: Bool
    var persona: DriverPersona = .normal {
        // A different driver does not need a different route, only a different
        // speed profile over the same one, so this regrades rather than
        // spending another Apple Maps request.
        didSet { if persona.id != oldValue.id { routeInputsChanged(needsNewRoute: false) } }
    }
    var travelMode: TravelMode = .drive {
        didSet { if travelMode != oldValue { routeInputsChanged(needsNewRoute: true) } }
    }
    var playbackRate: Double = 1
    var loopRoute = false
    var geofence: GeofenceGuard
    var banner: String?
    var isBusy = false
    var routeWaypoints: [RouteWaypoint] = []
    /// Stops the person has said they do not actually make, keyed by the thing
    /// in the road data they came from. Applied where the controls are handed
    /// to the tunnel, so a light crossed off in the preview is a light the
    /// drive does not wait at.
    var suppressedControls: Set<String> = []
    var activePlan: RoutePlan? {
        didSet { if activePlan == nil { rehearsal = nil } }
    }
    /// Every route Apple Maps offered for the current stops, best first, each a
    /// complete plan with its own line, road data, walks, travel time and
    /// `label`. After a build `activePlan` is `routeAlternatives[selectedRouteIndex]`.
    /// The first route arrives alone and the others join it once they are
    /// finished, so this holds one route for a moment and then up to three.
    var routeAlternatives: [RoutePlan] = []
    /// Which of `routeAlternatives` is the active plan.
    var selectedRouteIndex: Int = 0

    /// Switches the active plan to another of the offered routes, without
    /// asking Apple Maps again: the line is already known, only which one to
    /// drive changes. A route built for other stops is refused.
    func selectRoute(_ index: Int) {
        var choice = RouteChoice(plans: routeAlternatives, selectedIndex: selectedRouteIndex)
        guard choice.select(index, waypoints: routeWaypoints, mode: travelMode), let plan = choice.active else { return }
        selectedRouteIndex = choice.selectedIndex
        activePlan = plan
        believability = grade(plan)
        rehearsal = rehearse(plan)
    }
    /// How convincing the built route looks, and why.
    var believability: Believability?
    var rehearsal: Rehearsal?
    /// What the route builder is doing right now, for the UI to show.
    var routeStatus: String?
    /// The pending automatic rebuild, so a second change cancels the first.
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    /// The build the route on screen came from, kept so the Start button can
    /// wait a moment for road data that is still on its way rather than
    /// driving on defaults a second before it lands.
    @ObservationIgnored private var pendingBuild: RouteBuild?
    /// How long the Start button waits for road data that has not landed yet.
    /// The map waits for none of it; a drive is worth a few seconds.
    static let roadDataStartWait: TimeInterval = 12
    /// One line, said once, when a route really has no road data.
    static let noRoadDataNotice = "Speed limits and stops did not load. Cloak is using road type defaults and will try again."

    var recordingFixes: [SimulatedFix] = []
    var isRecording = false
    /// True when the recording captures the phone's real movement rather than
    /// a running simulation. Decided when recording starts: with nothing
    /// simulating, it records the real drive.
    var isRecordingReal = false
    /// How fast a simulated drive sits against the posted limits.
    var speedHelp = SpeedHelp.load() {
        didSet { routeInputsChanged(needsNewRoute: false) }
    }
    var shield = ShieldSettings.load()
    /// Road data around a SHIELD drive, refreshed as the car leaves the box.
    private var shieldRoadBox: BoundingBox?
    private var shieldRoadTask: Task<Void, Never>?
    private let shieldRoadCache = RoadDataCache()
    private let shieldOverpass = OverpassClient()
    var imageTransfer: String?
    var hasDeveloperImage = DeveloperImageBundle.isPresent
    var hasPairing = false
    var hasRemotePairing = false
    var setupProblem: String?
    var autoStopMinutes = 0
    /// Pause the simulation the moment the connection stops matching the pin,
    /// rather than carrying on exposed until somebody notices.
    var pauseWhenCoverBreaks: Bool {
        didSet { AppGroup.defaults.set(pauseWhenCoverBreaks, forKey: "pauseWhenCoverBreaks") }
    }
    private(set) var pausedByCover = false
    var isPeeking = false
    var locationAuthorization: CLAuthorizationStatus = .notDetermined
    private let peek = LocationPeek()
    /// Whether the continuous location feed is currently running, so it is not
    /// started twice or stopped when it was never going.
    private var locationActive = false
    private let liveActivity = DriveActivityController()
    private var autoStopTask: Task<Void, Never>?

    let reflector = ReflectorGate()
    let imageDelivery = ImageDelivery()
    private let engine = SimulationEngine()
    let pairingStore = PairingStore()
    private let routeBuilder = RouteBuilder()
    private let locationManager = CLLocationManager()
    private var pollTask: Task<Void, Never>?

    override init() {
        let defaults = AppGroup.defaults
        self.isOnboarded = defaults.bool(forKey: "onboarded")
        if let data = defaults.data(forKey: "geofence"),
           let decoded = try? JSONDecoder().decode(GeofenceGuard.self, from: data) {
            self.geofence = decoded
        } else {
            self.geofence = GeofenceGuard(center: Coordinate(latitude: 0, longitude: 0), isEnabled: false)
        }
        self.pauseWhenCoverBreaks = defaults.object(forKey: "pauseWhenCoverBreaks") as? Bool ?? true
        super.init()
        self.autoStopMinutes = defaults.integer(forKey: "autoStopMinutes")
        watchCover()
        reflector.install()
        registerLiveControl()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        // A copy handed over by the desktop installer counts as being paired,
        // and it arrives before the first launch finishes.
        PairingHandoff.adopt(into: pairingStore)
        PairingHandoff.adoptRemoteRecord()
        hasPairing = pairingStore.hasRecord
        hasRemotePairing = RemotePairingBackend.storedRecord != nil
        let engine = self.engine
        RenewController.shared.ensureLink = { await engine.linkProblem() }
        CellularAssist.shared.install()
        TrialController.shared.onExpired = { [weak self] in
            await self?.stop()
            self?.banner = "Free minutes used up for today. Back to your real location."
        }
    }

    /// True once this phone can reach its own developer services, by either
    /// route: the record it earned by pairing with itself, or one imported from
    /// a Mac.
    /// The installer's lockdown record is only usable below iOS 27; from 27 the
    /// phone refuses its own lockdown port, so only the record the phone earned
    /// by pairing outward counts. Without this the onboarding skipped the one
    /// step that could make the phone work.
    var hasAnyPairing: Bool {
        if PairingPlan.currentMajor >= PairingPlan.pairableHostMajor {
            return hasRemotePairing
        }
        return hasPairing || hasRemotePairing
    }

    var isSetupComplete: Bool { hasAnyPairing && hasDeveloperImage }

    func onAppear() {
        // No permission prompt here. Onboarding has a step that explains why
        // Cloak wants location and asks then; asking the moment the app opens
        // (it used to fire over the licence screen) is what Apple's guidelines
        // tell apps not to do, and people say no to prompts they do not
        // understand. `requestAlwaysLocation()` is the one place that asks.
        applyLocationAuthorization(locationManager.authorizationStatus)
        startPolling()
        Task { await linkInBackground() }
    }

    /// Brings the link up on launch, without anybody opening Settings.
    ///
    /// Once this phone has paired with itself the link is pure machinery, so
    /// making somebody walk to Settings and tap "Pair without a computer"
    /// every single time was busywork. It only runs when a pairing record
    /// already exists, so it never hijacks first-run setup, and it stays quiet
    /// on failure: whatever the person does next raises the real error.
    func linkInBackground() async {
        guard RemotePairingBackend.storedRecord != nil else { return }
        guard !linkState.isReady else { return }
        do {
            try await startTunnelOnly()
        } catch {
            Self.driveLog.notice("background link did not come up: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Background running depends entirely on this.
    ///
    /// iOS keeps an app alive in the background while it is genuinely receiving
    /// location updates, and only with Always authorization. Setting
    /// `allowsBackgroundLocationUpdates` before that is granted does nothing,
    /// which is why the simulation used to advance only while the app was on
    /// screen.
    private func applyLocationAuthorization(_ status: CLAuthorizationStatus) {
        locationAuthorization = status
        updateLocationNeed()
    }

    /// Whether anything actually wants the real position right now.
    ///
    /// Three things do: a running simulation, which iOS keeps alive in the
    /// background only while location is genuinely being delivered; a recording,
    /// which is made of real positions; and the geofence guard, which cannot
    /// notice you leaving an area it is not watching.
    ///
    /// Nothing else does. Sitting on the map does not.
    private var needsRealLocation: Bool {
        snapshot.isRunning || isRecording || geofence.isEnabled
    }

    var isShielding: Bool {
        if case .shield = snapshot.mode { return snapshot.isRunning }
        return false
    }

    /// Starts and stops location to match.
    ///
    /// This used to switch on the moment permission was granted and never
    /// switch off, so the arrow in the status bar was lit from launch until the
    /// app was killed, whether or not anything was happening. iOS shows that
    /// arrow because an app is holding location open, and the honest way to put
    /// it out is to stop holding it.
    private func updateLocationNeed() {
        let allowed = locationAuthorization == .authorizedAlways
            || locationAuthorization == .authorizedWhenInUse

        guard allowed, needsRealLocation else {
            if locationActive {
                locationManager.stopUpdatingLocation()
                // Left on while idle, this alone is enough to keep the arrow lit
                // on some versions.
                locationManager.allowsBackgroundLocationUpdates = false
                locationActive = false
            }
            return
        }

        guard !locationActive else { return }

        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.pausesLocationUpdatesAutomatically = false
        // While Using is enough: with the location background mode declared,
        // iOS keeps a When In Use app running in the background as long as it
        // is receiving fixes, and shows the blue pill while it does. Gating
        // this on Always meant anyone who picked the other button had the
        // drive freeze the moment they switched to Life360 to look.
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.showsBackgroundLocationIndicator = true
        locationManager.startUpdatingLocation()
        locationActive = true
    }

    /// Reads the real position once, for the things that want it now and then
    /// rather than continuously.
    ///
    /// Without this, asking where the phone is would mean turning the
    /// continuous feed on and leaving it on, which is the behaviour being
    /// removed. A single request lights the arrow for a moment and no longer.
    func readRealPositionOnce() {
        let allowed = locationAuthorization == .authorizedAlways
            || locationAuthorization == .authorizedWhenInUse
        guard allowed, !locationActive else { return }
        locationManager.requestLocation()
    }

    /// True when the simulation will keep running with the app off screen.
    ///
    /// While Using counts. With the location background mode declared, iOS
    /// keeps a When In Use app running while it is receiving fixes (see
    /// `startLocation`), and the engine was changed to rely on exactly that.
    /// This still said Always only, so Settings opened with an orange warning
    /// that the drive stops when you leave the app, right above Diagnostics
    /// saying the opposite, and the Diagnostics one was the true one.
    var canRunInBackground: Bool {
        locationAuthorization == .authorizedAlways || locationAuthorization == .authorizedWhenInUse
    }

    /// Whether the phone currently has the kind of interface iOS needs before
    /// it will offer its pairing service. Recomputed on every poll so the
    /// onboarding check ticks over live.
    var hasLocalNetwork = RemotePairingDiscovery.hasLocalNetworkInterface

    func openLocationSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                await self?.refreshSnapshot()
                if tick % 600 == 0 {
                    await MainActor.run { _ = RenewController.shared.renewIfDue() }
                }
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func refreshSnapshot() async {
        hasLocalNetwork = RemotePairingDiscovery.hasLocalNetworkInterface
        updateLocationNeed()
        snapshot = await engine.current
        liveActivity.sync(with: snapshot)
        if isRecording, !isRecordingReal, let fix = snapshot.fix {
            recordingFixes.append(fix)
        }
        if let message = snapshot.linkMessage, banner == nil {
            banner = message
        }
        if let real = realPosition, geofence.shouldStop(realPosition: real), snapshot.isRunning {
            await panic()
            banner = "Geofence guard stopped simulation. Your real position left the allowed area."
        }
    }

    func importSetup(data: Data) async {
        setupProblem = nil

        guard let payload = SetupPayload.decode(data) else {
            store(pairing: data)
            return
        }

        if let inline = payload.pairing, !inline.isEmpty {
            store(pairing: inline)
        }

        guard let source = payload.developerImage else {
            if let setupProblem { banner = setupProblem }
            return
        }

        if !hasPairing {
            imageTransfer = "Fetching pairing record"
            do {
                let fetched = try await DeveloperImageFetcher().fetchPairing(from: source)
                store(pairing: fetched)
            } catch {
                setupProblem = "Could not reach the helper for the pairing record: \(error.localizedDescription)"
                banner = setupProblem
            }
            imageTransfer = nil
        }

        if !DeveloperImageBundle.isPresent {
            await downloadDeveloperImage(from: source)
        }

        if let setupProblem {
            banner = setupProblem
        }
    }

    private func store(pairing: Data) {
        guard !pairing.isEmpty else {
            setupProblem = "The pairing record in that code was empty."
            banner = setupProblem
            return
        }

        do {
            let record = try PairingRecord.parse(pairing)
            try pairingStore.save(record)
            hasPairing = pairingStore.hasRecord
            if !hasPairing {
                setupProblem = "The pairing record saved but could not be read back."
                banner = setupProblem
            }
        } catch {
            hasPairing = false
            setupProblem = "Pairing record: \(error.localizedDescription)"
            banner = setupProblem
        }
    }

    private func downloadDeveloperImage(from source: SetupPayload.ImageSource) async {
        imageTransfer = "Starting"
        let fetcher = DeveloperImageFetcher()
        let succeeded = await fetcher.fetch(from: source) { progress in
            Task { @MainActor [weak self] in
                switch progress {
                case .started(let name):
                    self?.imageTransfer = "Fetching \(name)"
                case .bytes(let received, let expected, let name):
                    if expected > 0 {
                        let percent = Int(Double(received) / Double(expected) * 100)
                        self?.imageTransfer = "\(name) \(percent)%"
                    } else {
                        self?.imageTransfer = "\(name) \(received / 1_048_576) MB"
                    }
                case .finished:
                    self?.imageTransfer = nil
                case .failed(let message):
                    self?.imageTransfer = nil
                    self?.banner = message
                }
            }
        }
        hasDeveloperImage = DeveloperImageBundle.isPresent
        if succeeded { banner = "Developer image stored. The computer is done." }
    }

    func clearPairing() {
        pairingStore.clear()
        hasPairing = false
        setupProblem = nil
        banner = "Pairing record removed."
    }

    func completeOnboarding() {
        isOnboarded = true
        AppGroup.defaults.set(true, forKey: "onboarded")
    }

    func teleport(to coordinate: Coordinate, label: String) async {
        isBusy = true
        defer { isBusy = false }
        await send(.start(.fixed(coordinate, label: label)))
    }

    /// Builds the route and shows it, without starting the simulation. Lets you
    /// see what you are about to drive before committing to it.
    @discardableResult
    func previewRoute() async -> RoutePlan? {
        // A route with only a destination starts where the phone really is.
        // Nobody should have to understand that the first stop is the start
        // before they can go anywhere.
        if routeWaypoints.count == 1 {
            guard await startFromRealPosition() else { return nil }
        }
        guard routeWaypoints.count >= 2 else {
            banner = "Choose where you want to go."
            return nil
        }
        isBusy = true
        routeStatus = "Asking Apple Maps for a route"
        defer { isBusy = false; routeStatus = nil }

        do {
            // The line comes back as soon as Apple Maps answers it. Its posted
            // limits and its stops are still being fetched and land on the same
            // route, by identity, a few seconds later. Waiting for them here is
            // what made a route take the better part of a minute to appear.
            let build = try await routeBuilder.beginRoutes(waypoints: routeWaypoints, mode: travelMode)
            let plan = build.primary
            // The stops or the mode changed while Apple Maps was answering.
            // This route is for a trip that is no longer the one on screen.
            guard plan.matches(waypoints: routeWaypoints, mode: travelMode) else { return nil }

            var choice = RouteChoice()
            choice.begin(with: plan)
            routeAlternatives = choice.plans
            selectedRouteIndex = choice.selectedIndex
            activePlan = plan
            believability = grade(plan)
            rehearsal = rehearse(plan)
            pendingBuild = build

            // Held where the pending rebuild is held, so moving a stop or
            // clearing the stops cancels it, and its Overpass requests with
            // it. A regrade leaves it running. Whatever the handle held
            // before is not cancelled here: it can be another build still
            // waiting on its road data, and cancelling that would land a
            // route with none. A late answer is thrown away by the checks
            // below instead.
            rebuildTask = Task { [weak self] in
                // The road data first. The route on screen is on per class
                // defaults until it lands, and the other offered routes are
                // decided from it, so there is no point starting them sooner.
                var settled = await build.settled()
                guard !Task.isCancelled, let self else { return }
                self.absorb(settled)

                if settled.metadata.wasFallback {
                    settled = await build.retryingRoadData()
                    guard !Task.isCancelled else { return }
                    self.absorb(settled)
                    if settled.metadata.wasFallback, self.activePlan?.id == plan.id {
                        self.banner = Self.noRoadDataNotice
                    }
                }

                guard build.hasAlternatives else { return }
                let all = await build.alternatives()
                guard !Task.isCancelled else { return }
                guard self.activePlan?.id == plan.id,
                      plan.matches(waypoints: self.routeWaypoints, mode: self.travelMode) else { return }
                var choice = RouteChoice(plans: self.routeAlternatives, selectedIndex: self.selectedRouteIndex)
                guard choice.complete(with: all), let active = choice.active else { return }
                self.routeAlternatives = choice.plans
                self.selectedRouteIndex = choice.selectedIndex
                // The same route relabelled, so nothing needs regrading.
                self.activePlan = active
            }
            return plan
        } catch let error as RouteBuilderError {
            banner = Self.describe(error)
            return nil
        } catch {
            banner = error.localizedDescription
            return nil
        }
    }

    /// The same route again with its road data in place.
    ///
    /// The line, the walks and the travel time do not change, only what is
    /// known about the roads under them, so the route keeps its identity and
    /// its place in the choice. Nothing about a drive already running is
    /// touched: swapping the speed profile under a car that is moving is how
    /// you get a jump, and the drive that started on defaults finishes on them.
    private func absorb(_ settled: RoutePlan) {
        guard settled.matches(waypoints: routeWaypoints, mode: travelMode) else { return }
        var choice = RouteChoice(plans: routeAlternatives, selectedIndex: selectedRouteIndex)
        guard choice.refresh(with: settled) else { return }
        routeAlternatives = choice.plans
        selectedRouteIndex = choice.selectedIndex
        guard let active = choice.active, activePlan?.id == active.id else { return }
        activePlan = active
        believability = grade(active)
        rehearsal = rehearse(active)
    }

    static func describe(_ error: RouteBuilderError) -> String {
        switch error {
        case .notEnoughWaypoints: "Add at least two stops."
        case .routingFailed(let detail): detail
        }
    }

    func startRoute(shieldMode: ShieldSettings.Mode? = nil) async {
        if TrialController.shared.requirePaid(shieldMode == nil ? "Routes and driving" : "SHIELD") { return }
        if routeWaypoints.count == 1 {
            guard await startFromRealPosition() else { return }
        }
        guard routeWaypoints.count >= 2 else {
            banner = "Choose where you want to go."
            return
        }
        isBusy = true
        routeStatus = "Asking Apple Maps for a route"
        defer { isBusy = false; routeStatus = nil }
        do {
            var plan: RoutePlan
            if let existing = activePlan {
                // Whichever offered route is selected. Building again here would
                // ask Apple Maps afresh and drive its first route instead.
                plan = existing
            } else {
                // Nothing is on screen, so whatever was on offer belonged to
                // stops that have since been replaced.
                var choice = RouteChoice(plans: routeAlternatives, selectedIndex: selectedRouteIndex)
                choice.clear()
                routeAlternatives = choice.plans
                selectedRouteIndex = choice.selectedIndex
                let build = try await routeBuilder.beginRoutes(waypoints: routeWaypoints, mode: travelMode)
                pendingBuild = build
                routeStatus = "Reading speed limits and stops"
                let built = await build.settled(waitingUpTo: Self.roadDataStartWait)
                choice.begin(with: built)
                routeAlternatives = choice.plans
                selectedRouteIndex = choice.selectedIndex
                plan = built
            }

            // The route on screen never waited for its road data, so it may
            // still be on per class defaults. A drive is worth a short wait for
            // the posted limits and the stop signs, and then it goes anyway.
            if plan.metadata.wasFallback, let build = pendingBuild, build.primary.id == plan.id {
                routeStatus = "Reading speed limits and stops"
                let settled = await build.settled(waitingUpTo: Self.roadDataStartWait)
                if !settled.metadata.wasFallback, settled.matches(waypoints: routeWaypoints, mode: travelMode) {
                    absorb(settled)
                    plan = settled
                }
            }
            if plan.metadata.wasFallback { banner = Self.noRoadDataNotice }

            activePlan = plan
            believability = grade(plan)
            routeStatus = "Starting"
            let profileStart = RouteTiming.now()
            let densified = plan.polyline.densified(spacing: 4)
            let limits = plan.metadata.limits(along: densified, fallback: travelMode == .drive ? .residential : .footway)
            let controls = liveControls(plan.metadata.snappedControls(to: densified))
            Self.driveLog.notice("route \(Int(densified.length))m, \(plan.metadata.segments.count) roads known (fallback: \(plan.metadata.wasFallback)), \(controls.count) controls on route")
            if let lo = limits.min(), let hi = limits.max() {
                let mean = limits.reduce(0, +) / Double(max(1, limits.count))
                Self.driveLog.notice("limits mph min \(Int(Speed.toMph(lo))) max \(Int(Speed.toMph(hi))) mean \(Int(Speed.toMph(mean)))")
            }
            for control in controls {
                Self.driveLog.notice("control \(control.kind.rawValue, privacy: .public) at \(Int(control.alongTrack))m \(control.coordinate.latitude),\(control.coordinate.longitude) minorOnly=\(control.appliesToMinorRoadOnly) signalled=\(control.isSignalled)")
            }
            RouteTiming.done(
                "profile",
                profileStart,
                "\(densified.points.count) points, \(plan.metadata.segments.count) roads, \(controls.count) controls"
            )
            let payload = TunnelStartPayload(
                points: densified.points,
                postedLimits: limits,
                controls: controls,
                personaID: shieldMode.map { DriverPersona.shield(allowanceMph: $0.allowanceMph).id } ?? persona.id,
                mode: shieldMode == nil ? travelMode : .drive,
                playbackRate: shieldMode == nil ? playbackRate : 1,
                loop: shieldMode == nil && loopRoute,
                seed: UInt64.random(in: 1...UInt64.max),
                label: routeWaypoints.last?.title ?? "Route",
                shieldMode: shieldMode,
                // The builder already asked Apple Maps for the walking parts,
                // so it knows which stretches are on foot. Carrying that here
                // means the simulation never has to guess it back out of the
                // speed limits, which is a guess that reads a mapped pavement
                // beside the road as a footway.
                walkingSpans: plan.walkingSpans
            )
            await send(.start(payload))
        } catch let error as RouteBuilderError {
            banner = Self.describe(error)
        } catch {
            banner = error.localizedDescription
        }
    }

    /// Grades a built route against the things that actually give a simulated
    /// location away, so the weakness is visible before it runs rather than
    /// after somebody notices it.
    /// The controls still in force, with anything the person crossed off in
    /// the route preview taken out. Everything that describes the drive has to
    /// go through here, or two cards on the same screen will disagree about
    /// how many times the car stops.
    func liveControls(_ controls: [TrafficControl]) -> [TrafficControl] {
        guard !suppressedControls.isEmpty else { return controls }
        return controls.filter { !suppressedControls.contains($0.suppressionKey) }
    }

    private func grade(_ plan: RoutePlan) -> Believability {
        let started = RouteTiming.now()
        defer { RouteTiming.done("grade", started, "\(plan.metadata.segments.count) roads") }
        let densified = plan.polyline.densified(spacing: 4)
        let limits = plan.metadata.limits(along: densified, fallback: travelMode == .drive ? .residential : .footway)
        return Believability.grade(
            plan: densified.points,
            postedLimits: limits,
            controls: liveControls(plan.metadata.snappedControls(to: densified)),
            mode: travelMode,
            realPosition: realPosition,
            lastRunSignature: AppGroup.defaults.string(forKey: "lastRouteSignature"),
            signature: signature(for: densified.points)
        )
    }

    private func signature(for points: [Coordinate]) -> String {
        guard let first = points.first, let last = points.last else { return "" }
        return String(format: "%.4f,%.4f>%.4f,%.4f@%d",
                      first.latitude, first.longitude,
                      last.latitude, last.longitude,
                      points.count)
    }

    /// Makes where the phone really is the first stop of the route.
    ///
    /// Two things were wrong with the button this backs. It only appeared once
    /// the app already had a real position, and the app only reads one while
    /// something is simulating, so on a fresh launch it simply was not there.
    /// And it appended, so "start from where I am" pressed after choosing a
    /// destination put you at the end and built the route backwards.
    ///
    /// So this goes and finds the position if it has to, and inserts at the
    /// front. If the route already starts where you are it does nothing.
    @discardableResult
    func startFromRealPosition() async -> Bool {
        guard let here = await realPositionNow() else {
            banner = "Cloak cannot see where you are yet. Allow location for Cloak in Settings, then try again."
            return false
        }
        if let first = routeWaypoints.first, first.coordinate.distance(to: here) < Self.sameSpot {
            return true
        }
        routeWaypoints.insert(RouteWaypoint(coordinate: here, title: "Where I am"), at: 0)
        routeInputsChanged(needsNewRoute: true)
        return true
    }

    /// Closer than this and two points are the same place for a route.
    static let sameSpot: Double = 30

    /// The real position, fetched if it is not already known.
    ///
    /// Tries the last position this app saw, then CoreLocation's own cached
    /// fix as long as it is not a simulated one, then asks for a single fix
    /// and waits a few seconds for it. Never returns a simulated position,
    /// because while a simulation runs every app, this one included, is handed
    /// the fake one.
    func realPositionNow(timeout: Duration = .seconds(6)) async -> Coordinate? {
        if let realPosition { return realPosition }

        if let cached = locationManager.location,
           cached.horizontalAccuracy >= 0,
           cached.sourceInformation?.isSimulatedBySoftware != true {
            let coordinate = Coordinate(cached.coordinate)
            realPosition = coordinate
            return coordinate
        }

        var asked = false
        func askOnce() {
            // One request, not one per poll. `requestLocation` can take several
            // seconds, and calling it again restarts it, so asking on every
            // pass would mean it never finishes.
            guard !asked else { return }
            let allowed = locationAuthorization == .authorizedWhenInUse || locationAuthorization == .authorizedAlways
            guard allowed else { return }
            asked = true
            readRealPositionOnce()
        }

        if locationAuthorization == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        askOnce()

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let realPosition { return realPosition }
            try? await Task.sleep(for: .milliseconds(200))
            // Covers the permission prompt being answered while this waits.
            askOnce()
        }
        return realPosition
    }

    /// Adds a stop. The route no longer matches, so it is rebuilt.
    func addStop(_ coordinate: Coordinate, title: String) {
        routeWaypoints.append(RouteWaypoint(coordinate: coordinate, title: title))
        routeInputsChanged(needsNewRoute: true)
    }

    /// Something about the route changed, so bring what is on screen back in
    /// line with it.
    ///
    /// Two different kinds of change end up here. Moving a stop or switching
    /// between driving and walking means the line itself is wrong and Apple
    /// Maps has to be asked again, which costs a network request and is
    /// debounced so that dragging a slider or adding three stops in a row does
    /// not fire three of them. Changing the driver or the speed help leaves
    /// the line exactly where it is and only changes how it is driven, so that
    /// regrades in place with no request at all.
    ///
    /// Either way nothing is left stale on screen waiting for somebody to
    /// press build, which is what used to happen.
    func routeInputsChanged(needsNewRoute: Bool) {
        // A new line clears every offered route and the choice between them.
        // A regrade keeps both, and the active plan it regrades is the
        // selected route.
        var choice = RouteChoice(plans: routeAlternatives, selectedIndex: selectedRouteIndex)
        choice.inputsChanged(needsNewRoute: needsNewRoute)
        routeAlternatives = choice.plans
        selectedRouteIndex = choice.selectedIndex

        guard needsNewRoute else {
            // A regrade moves no line, so it does not cancel a pending rebuild
            // or the offered routes still being finished.
            guard let plan = activePlan else { return }
            believability = grade(plan)
            rehearsal = rehearse(plan)
            return
        }

        rebuildTask?.cancel()
        // The road data still arriving belongs to the old line.
        pendingBuild = nil
        let hadPlan = activePlan != nil
        activePlan = nil
        rehearsal = nil
        if routeWaypoints.count < 2 {
            believability = nil
            return
        }
        // Only rebuild by itself for somebody who had already built one. On a
        // first route, adding the second stop should not start a network
        // request before they have said what they want.
        guard hadPlan else { return }

        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.rebuildSettle))
            guard !Task.isCancelled else { return }
            await self?.previewRoute()
        }
    }

    /// How long to wait for the person to stop fiddling before asking Apple
    /// Maps again.
    static let rebuildSettle: Int = 450

    /// Plays the plan through the motion engine offline and grades the trace it
    /// would produce, so the drive can be judged before it runs.
    private func rehearse(_ plan: RoutePlan) -> Rehearsal {
        let started = RouteTiming.now()
        defer { RouteTiming.done("rehearse", started, "\(Int(plan.polyline.length))m") }
        let seed = UInt64(bitPattern: Int64(signature(for: plan.polyline.points).hashValue))
        let profile = plan.speedProfile(
            persona: persona,
            speedHelp: speedHelp,
            suppressing: suppressedControls,
            seed: seed
        )
        return Rehearsal.run(profile: profile, persona: persona, mode: travelMode, seed: seed)
    }

    func removeStop(_ waypoint: RouteWaypoint) {
        routeWaypoints.removeAll { $0.id == waypoint.id }
        routeInputsChanged(needsNewRoute: true)
    }

    func moveStops(from source: IndexSet, to destination: Int) {
        routeWaypoints.move(fromOffsets: source, toOffset: destination)
        routeInputsChanged(needsNewRoute: true)
    }

    func clearStops() {
        rebuildTask?.cancel()
        routeWaypoints.removeAll()
        // The crossings off belonged to that route. Keeping them would let a
        // key from an old route quietly match a light on a new one.
        suppressedControls.removeAll()
        var choice = RouteChoice(plans: routeAlternatives, selectedIndex: selectedRouteIndex)
        choice.clear()
        routeAlternatives = choice.plans
        selectedRouteIndex = choice.selectedIndex
        activePlan = nil
        rehearsal = nil
        believability = nil
    }

    /// True while the person is driving this themselves, which tells the
    /// routine runner to keep its hands off.
    var manualOverride = false

    /// Sits at a place, drifting the way a real phone on a table does.
    func hold(at coordinate: Coordinate, label: String, drift: Double) async {
        await send(.start(.fixed(coordinate, label: label, dwellRadius: drift)))
    }

    /// Drives or walks between two points, building the route on the way.
    func travel(from: Coordinate, to: Coordinate, label: String, mode: TravelMode) async {
        travelMode = mode
        routeWaypoints = [
            RouteWaypoint(coordinate: from, title: "Start"),
            RouteWaypoint(coordinate: to, title: label)
        ]
        activePlan = nil
        await startRoute()
    }

    /// Loads a saved route and runs it.
    func run(_ route: SavedRoute) async {
        routeWaypoints = route.waypoints
        travelMode = route.mode
        persona = DriverPersona.all.first { $0.id == route.personaID } ?? .normal
        activePlan = nil
        route.lastRunAt = .now
        await startRoute()
    }

    /// Whether replays and repeated routes should differ from one another.
    var variesEachRun = true

    func replay(_ trip: RecordedTrip) async {
        await replay(trip, varying: variesEachRun)
    }

    /// Replays a recording, optionally perturbed so it is never the same twice.
    func replay(_ trip: RecordedTrip, varying: Bool) async {
        if TrialController.shared.requirePaid("Replaying trips") { return }
        let recorded = trip.fixes
        let fixes = varying
            ? TripVariation().apply(to: recorded, seed: UInt64(abs(Int(Date.now.timeIntervalSince1970) / 3600)) &+ UInt64(truncatingIfNeeded: trip.id.hashValue))
            : recorded
        guard fixes.count > 1 else {
            banner = "That recording has no usable points."
            return
        }
        let payload = TunnelStartPayload(
            points: fixes.map(\.coordinate),
            postedLimits: [],
            controls: [],
            personaID: persona.id,
            mode: travelMode,
            playbackRate: playbackRate,
            loop: loopRoute,
            seed: UInt64(truncatingIfNeeded: trip.id.hashValue),
            label: trip.name
        )
        await send(.start(payload))
    }

    func stop() async {
        autoStopTask?.cancel()
        autoStopTask = nil
        await send(.stop)
        await TrialController.shared.end()
    }

    func peekRealLocation() async {
        guard !isPeeking else { return }
        isPeeking = true
        defer { isPeeking = false }

        let wasRunning = snapshot.isRunning
        let engine = self.engine

        // Take a fresh sample with the simulation actually cleared. Pausing on
        // its own leaves the last fake fix in place, which would just read our
        // own simulation back.
        let result = await peek.sample(
            clearing: {
                if wasRunning { _ = await engine.handle(.peekBegin) }
            },
            restoring: {
                if wasRunning { _ = await engine.handle(.peekEnd) }
            }
        )

        if let result {
            realPosition = result.coordinate
            banner = String(format: "You are actually at %.5f, %.5f",
                            result.coordinate.latitude, result.coordinate.longitude)
        } else if let real = realPosition {
            banner = String(format: "Last known real position: %.5f, %.5f", real.latitude, real.longitude)
        } else {
            banner = "No real position available."
        }

        snapshot = await engine.current
    }

    /// Lets App Intents — Shortcuts, and the buttons on the Live Activity —
    /// drive the same simulation this screen is driving.
    private func registerLiveControl() {
        LiveControl.register(LiveControl.Handlers(
            start: { [weak self] payload in
                guard let self else { return LiveControl.unavailable }
                await self.send(.start(payload))
                return self.banner
            },
            stop: { [weak self] in await self?.stop() },
            togglePause: { [weak self] in await self?.togglePause() },
            panic: { [weak self] in await self?.panic() },
            setRate: { [weak self] rate in await self?.setPlaybackRate(rate) },
            snapshot: { [weak self] in self?.snapshot ?? .stopped }
        ))
    }

    /// Pulls the developer disk image down from the licence server. Nothing
    /// simulates until this has happened once.
    func fetchDeveloperImage() async {
        var token = LicenseStore.savedToken
        if token == nil, TrialController.shared.isChosen {
            // On the free trial the token is minted by the trial server. Get
            // one before the download, and if the trial server refused, say
            // that plainly instead of letting the download report the generic
            // "needs an active licence", which is what made the trial look
            // broken.
            if TrialController.shared.token == nil { await TrialController.shared.refresh() }
            token = TrialController.shared.token
            if token == nil {
                imageDelivery.markFailed(TrialController.shared.problem
                    ?? "The free trial could not start. Check your connection and try again.")
                hasDeveloperImage = DeveloperImageBundle.isPresent
                return
            }
        }
        _ = await imageDelivery.fetch(token: token)
        hasDeveloperImage = DeveloperImageBundle.isPresent
    }

    // MARK: - SHIELD

    func setShield(_ value: ShieldSettings) {
        shield = value
        value.save()
    }

    /// SHIELD drives the built route at the posted limit plus the chosen
    /// allowance, whatever the car is really doing.
    ///
    /// It cannot follow the real car: while a simulation runs, iOS hands every
    /// app on the phone the simulated fix, this one included, so the only real
    /// position Cloak can know is the one from before it started. What it can
    /// do is drive the road you are about to drive, at a speed nobody will
    /// question, so start it as you pull out and it arrives shortly after you.
    @discardableResult
    /// SHIELD: your real drive, reported at the speed the road allows.
    ///
    /// The hard constraint, measured and worth writing down because it is not
    /// obvious: the instant Cloak reports a simulated position, iOS replaces
    /// the location for **every** app, Cloak included. So while SHIELD is
    /// running Cloak cannot see where the phone really is, and a shadow that
    /// reacts to your live speed is therefore impossible. Anything claiming
    /// otherwise either sits still, having nothing to follow, or invents a
    /// path and drives it on its own.
    ///
    /// So SHIELD works from a route you set. You drive it for real, Cloak
    /// reports you along the same road at the posted limit plus your chosen
    /// allowance, and when you go faster than that the report falls behind and
    /// catches up when you slow. Stops and signals come from the real road
    /// data, so the reported drive brakes where the road makes you brake.
    ///
    /// It will not guess. Without a destination this used to build a path from
    /// whatever roads were nearby and loop it forever, which is exactly why it
    /// appeared to set off while the car was parked.
    func startShield() async -> String? {
        if TrialController.shared.requirePaid("SHIELD") { return nil }
        guard !routeWaypoints.isEmpty else {
            return "SHIELD needs to know where you are going. Choose a destination in Route first, then start SHIELD and drive it."
        }
        await startRoute(shieldMode: shield.mode)
        return snapshot.isRunning ? nil : banner
    }

    /// Fetches the roads around the car once it strays outside the last box.
    /// About 1.5 km each way, cached on disk, so a commute costs a handful of
    /// requests and a repeat of it costs none.
    private func refreshShieldRoads(around point: Coordinate) {
        if let box = shieldRoadBox,
           point.latitude > box.minLatitude + 0.004, point.latitude < box.maxLatitude - 0.004,
           point.longitude > box.minLongitude + 0.005, point.longitude < box.maxLongitude - 0.005 {
            return
        }
        guard shieldRoadTask == nil else { return }
        let box = BoundingBox(
            minLatitude: point.latitude - 0.014, minLongitude: point.longitude - 0.018,
            maxLatitude: point.latitude + 0.014, maxLongitude: point.longitude + 0.018
        )
        shieldRoadBox = box
        let cache = shieldRoadCache
        let overpass = shieldOverpass
        let engine = self.engine
        shieldRoadTask = Task {
            let metadata = await cache.metadata(for: box) { try await overpass.fetch(box: $0) }
            await engine.updateShieldRoads(metadata)
            await MainActor.run { self.shieldRoadTask = nil }
        }
    }

    /// Takes effect on the next drive without anything being restarted, since
    /// the profile is read when a route is built.
    func setSpeedHelp(_ value: SpeedHelp) {
        speedHelp = value
        value.save()
    }

    /// Asks for Always location, which is what keeps a drive running with the
    /// phone locked. iOS only shows the prompt once, so a second call on a
    /// phone that already said no does nothing and the screen offers Settings.
    func requestAlwaysLocation() {
        locationManager.requestAlwaysAuthorization()
        applyLocationAuthorization(locationManager.authorizationStatus)
    }

    /// Brings up whichever reflector this build uses.
    @discardableResult
    func ensureTunnelUp(target: String? = nil) async -> Bool {
        await reflector.ensureUp(target: target ?? RemotePairingDiscovery.serviceAddress())
    }

    /// Plain-language reason the reflector is not running, if it is not.
    var reflectorProblem: String? {
        switch reflector.trouble {
        case .none: nil
        case .needsLocalDevVPN:
            "Cloak needs LocalDevVPN, a free app from the App Store, to talk to this phone's developer services."
        case .localDevVPNDidNotStart:
            "LocalDevVPN did not turn its tunnel on. Open it, switch it on, then come back."
        case .builtInFailed(let detail):
            "The tunnel would not start: \(detail)"
        }
    }

    /// Sends the user back through setup without throwing anything away.
    func restartOnboarding() {
        AppGroup.defaults.set(false, forKey: "onboarded")
        isOnboarded = false
    }

    func refreshPairingState() {
        hasPairing = pairingStore.hasRecord
        hasRemotePairing = RemotePairingBackend.storedRecord != nil
        hasDeveloperImage = DeveloperImageBundle.isPresent
    }

    func startTunnelOnly() async throws {
        guard await reflector.ensureUp() else {
            throw DeviceBackendError.handshakeFailed(reflectorProblem ?? "The tunnel would not start.")
        }
    }

    func retryLink() async {
        banner = nil
        snapshot.linkMessage = nil

        guard await reflector.ensureUp() else {
            banner = reflectorProblem
            return
        }

        let reply = await engine.handle(.status)
        snapshot = await engine.current

        if case .failed(let message) = reply {
            banner = message
        } else {
            banner = "Link is up. Everything is connected."
        }
    }

    func dropLinkForTest() async {
        guard !snapshot.isRunning else { return }
        await engine.dropLink()
        try? await Task.sleep(for: .milliseconds(800))
    }

    func linkProblemForTest() async -> String? {
        guard !snapshot.isRunning else { return "Stop the simulation before testing." }
        guard await reflector.ensureUp() else { return reflectorProblem ?? "The tunnel would not start." }
        return await engine.probe()
    }

    func togglePause() async {
        await send(snapshot.isPaused ? .resume : .pause)
    }

    func steer(bearing: Double, throttle: Double) async {
        await send(.steer(bearing: bearing, throttle: throttle))
    }

    func releaseSteering() async {
        await send(.releaseSteering)
    }

    func setAutoStop(minutes: Int) {
        autoStopMinutes = minutes
        AppGroup.defaults.set(minutes, forKey: "autoStopMinutes")
        armAutoStop()
    }

    private func armAutoStop() {
        autoStopTask?.cancel()
        autoStopTask = nil
        guard autoStopMinutes > 0, snapshot.isRunning else { return }
        let seconds = Double(autoStopMinutes) * 60
        autoStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.stop()
            await MainActor.run { self?.banner = "Auto stop reached. Back to your real location." }
        }
    }

    func panic() async {
        await send(.panic)
        await TrialController.shared.end()
        await reflector.stop()
        snapshot = .stopped
    }

    func setPlaybackRate(_ rate: Double) async {
        playbackRate = rate
        await send(.setPlaybackRate(rate))
    }

    func saveGeofenceHere() {
        guard let real = realPosition else {
            // The continuous feed is only held while something needs it, so
            // there may be no position yet. Ask for one rather than refusing.
            readRealPositionOnce()
            banner = "Finding where you are. Try that again in a moment."
            return
        }
        geofence.center = real
        geofence.isEnabled = true
        persistGeofence()
    }

    func setGeofenceEnabled(_ enabled: Bool) {
        // The guard reads the real position, so this is a moment location
        // permission genuinely matters. Ask here if it was skipped earlier.
        if enabled, locationAuthorization == .notDetermined { requestAlwaysLocation() }
        geofence.isEnabled = enabled
        persistGeofence()
    }

    private func persistGeofence() {
        guard let data = try? JSONEncoder().encode(geofence) else { return }
        AppGroup.defaults.set(data, forKey: "geofence")
    }

    func startRecording() {
        if locationAuthorization == .notDetermined { requestAlwaysLocation() }
        recordingFixes = []
        isRecordingReal = !snapshot.isRunning
        isRecording = true
        updateLocationNeed()
    }

    func finishRecording() -> [SimulatedFix] {
        isRecording = false
        isRecordingReal = false
        let captured = recordingFixes
        recordingFixes = []
        updateLocationNeed()
        return captured
    }

    private func send(_ command: TunnelCommand) async {
        // Checked here as well as at the root, and checked properly rather
        // than by reading a flag somebody set earlier.
        if case .start(let payload) = command, !Licensing.verifiedNow {
            let trial = TrialController.shared
            guard trial.isActive else {
                banner = "Cloak needs an active licence to start a simulation."
                return
            }
            if payload.points.count != 1 || payload.shieldMode != nil {
                _ = trial.requirePaid("Routes and driving")
                return
            }
            guard await trial.begin() else { return }
        }
        if case .steer = command, TrialController.shared.requirePaid("The joystick") { return }

        guard await reflector.ensureUp() else {
            banner = reflectorProblem
            return
        }

        let reply = await engine.handle(command)
        if case .failed(let message) = reply { banner = message }
        snapshot = await engine.current
        if case .start(let payload) = command {
            armAutoStop()
            if banner == nil, let warning = coverWarning(for: payload) { banner = warning }
        }
        if case .steer = command { armAutoStop() }
    }

    private func watchCover() {
        let exposure = ExposureController.shared
        exposure.onCoverBroke = { [weak self] line in
            guard let self, self.pauseWhenCoverBreaks, self.snapshot.isRunning, !self.snapshot.isPaused else { return }
            Task { @MainActor in
                await self.send(.pause)
                self.pausedByCover = true
                self.banner = "Paused. " + line
                RenewController.notify(
                    id: "cover-broke",
                    title: "Cloak paused",
                    body: line + " Fix the connection, then resume."
                )
            }
        }
        exposure.onCoverRestored = { [weak self] in
            guard let self, self.pausedByCover else { return }
            self.pausedByCover = false
            self.banner = "Your connection matches the pin again. Resume when ready."
            RenewController.notify(id: "cover-back", title: "Cover restored", body: "Your connection matches the pin again.")
        }
    }

    /// One line, at the moment of starting, if something around the pin is
    /// already giving it away. The place to find out is here, not from the
    /// app the pin was meant for.
    private func coverWarning(for payload: TunnelStartPayload) -> String? {
        guard let first = payload.points.first else { return nil }
        let exposure = ExposureController.shared
        // Grade where the trip ends up, so this does not flip the graded pin
        // to the route's start and straight back again.
        exposure.track(pin: first, destination: payload.points.last)
        guard let reading = exposure.reading else { return nil }
        let worst = reading.problems.first { $0.severity == .bad }
        guard let worst else { return nil }
        switch worst.kind {
        case .ip:
            let distance = reading.ipDistance.map(Exposure.describe) ?? "a long way"
            return "Started. Your connection comes out \(distance) from this pin. Open Exposure to fix that."
        case .country:
            return "Started. Your connection is in a different country from this pin. Open Exposure to fix that."
        case .timeZone:
            return "Started. Your clock is in the wrong zone for this pin. Open Exposure to fix that."
        case .motion:
            return "Started. The phone is still while you report movement. Apps that read motion will see both."
        case .softwareFlag, .unchecked:
            return nil
        }
    }
}

extension AppModel: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let coordinate = Coordinate(last.coordinate)
        var observed = ObservedLocation(
            speed: last.speed,
            course: last.course,
            horizontalAccuracy: last.horizontalAccuracy,
            timestamp: last.timestamp,
            derivedSpeed: nil,
            derivedCourse: nil,
            coordinate: coordinate
        )
        let real = RealFix(coordinate: coordinate, speed: max(0, last.speed), timestamp: last.timestamp)
        // iOS marks every fix it produced from a developer simulation. That is
        // the one flag Cloak cannot hide from other apps, but it can certainly
        // read it about itself, and it is the only way to tell a real fix from
        // Cloak's own output while a simulation runs.
        let isSimulated = last.sourceInformation?.isSimulatedBySoftware ?? false
        Task { @MainActor in
            if let previous = self.observedLocation {
                let gap = last.timestamp.timeIntervalSince(previous.timestamp)
                if gap >= 0.5, gap <= 10 {
                    observed.derivedSpeed = previous.coordinate.distance(to: coordinate) / gap
                    observed.derivedCourse = previous.coordinate.bearing(to: coordinate)
                }
            }
            if let derived = observed.derivedSpeed, Int(last.timestamp.timeIntervalSince1970) % 10 == 0 {
                Self.locationLog.info("apps can infer \(derived * 2.23694, format: .fixed(precision: 1)) mph from movement (iOS speed field \(last.speed))")
            }
            // While a simulation runs, CoreLocation hands every app the
            // simulated fix, this one included. Writing that into
            // `realPosition` would put the real-location marker on top of the
            // fake one and feed the geofence its own output. Filtering on the
            // simulated flag rather than on "is something running" means the
            // real marker keeps moving with you even while you are spoofing,
            // which is the point of showing it.
            if !isSimulated { self.realPosition = coordinate }

            // SHIELD follows the real drive. This is the feed that makes that
            // true: without it the shadow got one fix at startup and never
            // moved again, which is why it looked like it drove on its own.
            // A simulated fix must never reach it or it would follow its own
            // output in a circle.
            if !isSimulated, self.snapshot.isRunning, self.snapshot.mode.isShield {
                await self.engine.observeReal(real)
            }
            self.observedLocation = observed
            if self.isRecording, self.isRecordingReal, last.horizontalAccuracy >= 0, last.horizontalAccuracy < 50 {
                // A real trip, as driven. Course and speed come straight from
                // CoreLocation when it has them, else from the previous point.
                let previous = self.recordingFixes.last
                let speed = last.speed >= 0 ? last.speed
                    : previous.map { p in max(0, p.coordinate.distance(to: coordinate) / max(0.5, last.timestamp.timeIntervalSince(p.timestamp))) } ?? 0
                let course = last.course >= 0 ? last.course
                    : previous.map { $0.coordinate.bearing(to: coordinate) } ?? -1
                if previous == nil || previous!.coordinate.distance(to: coordinate) >= 1 || last.timestamp.timeIntervalSince(previous!.timestamp) >= 1 {
                    self.recordingFixes.append(SimulatedFix(
                        coordinate: coordinate,
                        speed: speed,
                        course: course,
                        altitude: last.altitude,
                        horizontalAccuracy: last.horizontalAccuracy,
                        timestamp: last.timestamp
                    ))
                }
            }
            if self.snapshot.isRunning {
                Self.locationLog.notice("iOS delivered speed=\(last.speed, privacy: .public) course=\(last.course, privacy: .public) acc=\(last.horizontalAccuracy, privacy: .public)")
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.applyLocationAuthorization(status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A one shot request that fails is not worth a banner: the map simply
        // keeps whatever it had.
    }
}
