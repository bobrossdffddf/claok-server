import Foundation
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
    var isOnboarded: Bool
    var persona: DriverPersona = .normal
    var travelMode: TravelMode = .drive
    var playbackRate: Double = 1
    var loopRoute = false
    var geofence: GeofenceGuard
    var banner: String?
    var isBusy = false
    var routeWaypoints: [RouteWaypoint] = []
    var activePlan: RoutePlan?
    /// How convincing the built route looks, and why.
    var believability: Believability?
    /// What the route builder is doing right now, for the UI to show.
    var routeStatus: String?
    var recordingFixes: [SimulatedFix] = []
    var isRecording = false
    var imageTransfer: String?
    var hasDeveloperImage = DeveloperImageBundle.isPresent
    var hasPairing = false
    var hasRemotePairing = false
    var setupProblem: String?
    var autoStopMinutes = 0
    var isPeeking = false
    var locationAuthorization: CLAuthorizationStatus = .notDetermined
    private let peek = LocationPeek()
    private let liveActivity = DriveActivityController()
    private var autoStopTask: Task<Void, Never>?

    let reflector = ReflectorGate()
    let imageDelivery = ImageDelivery()
    private let engine = SimulationEngine()
    private let pairingStore = PairingStore()
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
        super.init()
        self.autoStopMinutes = defaults.integer(forKey: "autoStopMinutes")
        reflector.install()
        registerLiveControl()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        // A copy handed over by the desktop installer counts as being paired,
        // and it arrives before the first launch finishes.
        PairingHandoff.adopt(into: pairingStore)
        hasPairing = pairingStore.hasRecord
        hasRemotePairing = RemotePairingBackend.storedRecord != nil
    }

    /// True once this phone can reach its own developer services, by either
    /// route: the record it earned by pairing with itself, or one imported from
    /// a Mac.
    var hasAnyPairing: Bool { hasPairing || hasRemotePairing }

    var isSetupComplete: Bool { hasAnyPairing && hasDeveloperImage }

    func onAppear() {
        locationManager.requestAlwaysAuthorization()
        applyLocationAuthorization(locationManager.authorizationStatus)
        startPolling()
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

        guard status == .authorizedAlways || status == .authorizedWhenInUse else {
            locationManager.stopUpdatingLocation()
            return
        }

        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.allowsBackgroundLocationUpdates = (status == .authorizedAlways)
        locationManager.showsBackgroundLocationIndicator = true
        locationManager.startUpdatingLocation()
    }

    /// True when the simulation will keep running with the app off screen.
    var canRunInBackground: Bool { locationAuthorization == .authorizedAlways }

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
            while !Task.isCancelled {
                await self?.refreshSnapshot()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func refreshSnapshot() async {
        hasLocalNetwork = RemotePairingDiscovery.hasLocalNetworkInterface
        snapshot = await engine.current
        liveActivity.sync(with: snapshot)
        if isRecording, let fix = snapshot.fix {
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
        guard routeWaypoints.count >= 2 else {
            banner = "Add at least two stops."
            return nil
        }
        isBusy = true
        routeStatus = "Asking Apple Maps for a route"
        defer { isBusy = false; routeStatus = nil }

        do {
            let plan = try await routeBuilder.build(waypoints: routeWaypoints, mode: travelMode)
            activePlan = plan
            believability = grade(plan)
            return plan
        } catch let error as RouteBuilderError {
            banner = Self.describe(error)
            return nil
        } catch {
            banner = error.localizedDescription
            return nil
        }
    }

    static func describe(_ error: RouteBuilderError) -> String {
        switch error {
        case .notEnoughWaypoints: "Add at least two stops."
        case .routingFailed(let detail): detail
        }
    }

    func startRoute() async {
        guard routeWaypoints.count >= 2 else {
            banner = "Add at least two stops."
            return
        }
        isBusy = true
        routeStatus = "Asking Apple Maps for a route"
        defer { isBusy = false; routeStatus = nil }
        do {
            let plan: RoutePlan
            if let existing = activePlan {
                plan = existing
            } else {
                plan = try await routeBuilder.build(waypoints: routeWaypoints, mode: travelMode)
            }
            activePlan = plan
            believability = grade(plan)
            routeStatus = "Starting"
            let densified = plan.polyline.densified(spacing: 5)
            let limits = plan.metadata.limits(along: densified, fallback: travelMode == .drive ? .residential : .footway)
            let controls = plan.metadata.snappedControls(to: densified)
            let payload = TunnelStartPayload(
                points: densified.points,
                postedLimits: limits,
                controls: controls,
                personaID: persona.id,
                mode: travelMode,
                playbackRate: playbackRate,
                loop: loopRoute,
                seed: UInt64.random(in: 1...UInt64.max),
                label: routeWaypoints.last?.title ?? "Route"
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
    private func grade(_ plan: RoutePlan) -> Believability {
        let densified = plan.polyline.densified(spacing: 5)
        let limits = plan.metadata.limits(along: densified, fallback: travelMode == .drive ? .residential : .footway)
        return Believability.grade(
            plan: densified.points,
            postedLimits: limits,
            controls: plan.metadata.snappedControls(to: densified),
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

    /// Adds a stop and clears any built route, since the route no longer matches.
    func addStop(_ coordinate: Coordinate, title: String) {
        routeWaypoints.append(RouteWaypoint(coordinate: coordinate, title: title))
        activePlan = nil
    }

    func removeStop(_ waypoint: RouteWaypoint) {
        routeWaypoints.removeAll { $0.id == waypoint.id }
        activePlan = nil
    }

    func moveStops(from source: IndexSet, to destination: Int) {
        routeWaypoints.move(fromOffsets: source, toOffset: destination)
        activePlan = nil
    }

    func clearStops() {
        routeWaypoints.removeAll()
        activePlan = nil
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
        let token = LicenseStore.savedToken
        _ = await imageDelivery.fetch(token: token)
        hasDeveloperImage = DeveloperImageBundle.isPresent
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
        await reflector.stop()
        snapshot = .stopped
    }

    func setPlaybackRate(_ rate: Double) async {
        playbackRate = rate
        await send(.setPlaybackRate(rate))
    }

    func saveGeofenceHere() {
        guard let real = realPosition else {
            banner = "No real position yet."
            return
        }
        geofence.center = real
        geofence.isEnabled = true
        persistGeofence()
    }

    func setGeofenceEnabled(_ enabled: Bool) {
        geofence.isEnabled = enabled
        persistGeofence()
    }

    private func persistGeofence() {
        guard let data = try? JSONEncoder().encode(geofence) else { return }
        AppGroup.defaults.set(data, forKey: "geofence")
    }

    func startRecording() {
        recordingFixes = []
        isRecording = true
    }

    func finishRecording() -> [SimulatedFix] {
        isRecording = false
        let captured = recordingFixes
        recordingFixes = []
        return captured
    }

    private func send(_ command: TunnelCommand) async {
        // Checked here as well as at the root, and checked properly rather
        // than by reading a flag somebody set earlier.
        if case .start = command, !Licensing.verifiedNow {
            banner = "Cloak needs an active licence to start a simulation."
            return
        }

        guard await reflector.ensureUp() else {
            banner = reflectorProblem
            return
        }

        let reply = await engine.handle(command)
        if case .failed(let message) = reply { banner = message }
        snapshot = await engine.current
        if case .start = command { armAutoStop() }
        if case .steer = command { armAutoStop() }
    }
}

extension AppModel: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let coordinate = Coordinate(last.coordinate)
        Task { @MainActor in
            self.realPosition = coordinate
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.applyLocationAuthorization(status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
