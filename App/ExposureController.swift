import Foundation
import CoreLocation
import CoreMotion
import Network
import Observation
import UIKit
import CloakKit

/// Gathers the environment around the pin and keeps the `Exposure` grade
/// current.
///
/// Three signals feed it, each read the way an outside observer would read
/// it: where the internet connection comes out (one request to a public
/// geolocation database, the same kind every fraud check uses), what time
/// zone the phone is set to, and whether the phone is physically moving. The
/// pin is reverse-geocoded once so the two sides can be named in words.
///
/// It re-checks on its own when the network path changes, because that is
/// exactly when somebody has just switched their VPN and wants to know if it
/// worked, and when the pin moves far enough to be a different place.
@MainActor
@Observable
final class ExposureController {
    static let shared = ExposureController()

    private(set) var reading: Exposure?
    private(set) var pinPlace: Exposure.PinPlace?
    private(set) var ipPlace: Exposure.IPPlace?
    private(set) var isChecking = false
    private(set) var lastError: String?
    private(set) var isStationary: Bool?
    private(set) var motionAvailable = CMMotionActivityManager.isActivityAvailable()

    private var pin: Coordinate?
    private var destination: Coordinate?
    private var simulatedSpeed: Double = 0
    private var isSimulating = false
    /// The fastest the run has gone since the last time it properly stopped.
    private var topSpeed: Double = 0
    /// The last moment the run was actually going somewhere.
    private var movedAt: Date?

    /// The place the grade is about: where the run says it ends, or where the
    /// pin is when there is no end to go to.
    private var gradedPin: Coordinate? { destination ?? pin }

    /// How long movement counts for after the last time the run moved.
    ///
    /// Measured from the last moment the run was actually going somewhere, not
    /// from the last reading, because no readings arrive at all while the car
    /// waits at a light: the reported speed is pinned at zero and nothing
    /// changes, so nothing is published. The longest halt the drive model
    /// produces is a parking manoeuvre at fifty-five seconds and a traffic
    /// signal at forty-five, so ninety seconds covers the worst of them with
    /// room. A run that has genuinely parked and is holding position drops the
    /// accusation once the window passes rather than carrying it all session.
    private static let movementWindow: TimeInterval = 90

    /// Called when the connection stops agreeing with the pin while a
    /// simulation is running. Typically a VPN dropping. The string is the
    /// one line to show.
    var onCoverBroke: ((String) -> Void)?
    /// Called when it starts agreeing again.
    var onCoverRestored: (() -> Void)?
    private var lastIPMatched: Bool?

    private let geocoder = CLGeocoder()
    // Not isolated to the main actor, deliberately. CoreMotion calls back on
    // `motionQueue`, and a closure written inside a @MainActor method inherits
    // that isolation, so Swift asserts it is on the main queue, finds it is
    // not, and traps. Both objects are safe to touch from the queue they were
    // handed to, which is the only place they are used.
    private nonisolated(unsafe) let motion = CMMotionActivityManager()
    private nonisolated(unsafe) let motionQueue = OperationQueue()
    private let pathMonitor = NWPathMonitor()
    private var pathTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var liveMotion = false

    /// A VPN Cloak can hand off to, and what its free tier really costs.
    ///
    /// Cloak cannot move a connection itself, so the useful thing it can do is
    /// name what will, including the free ones, and say what free buys in
    /// numbers rather than leaving somebody to discover the cap halfway
    /// through a drive. Every figure below was read off the provider's own
    /// page in September 2026, not off a review site. Nothing offered here is
    /// funded by selling the traffic that goes through it.
    struct VPNApp: Identifiable {
        let id: String
        /// What the button says.
        let name: String
        /// The app's URL scheme, or nil when Cloak cannot ask about it. Every
        /// scheme here is also in Info.plist under LSApplicationQueriesSchemes,
        /// or canOpenURL lies and answers false for all of them.
        let scheme: String?
        let symbol: String
        /// Whether there is a free tier worth pointing somebody at.
        let free: Bool
        /// The short version, for the button. Empty when there is no free tier.
        let offer: String
        /// The long version: exactly what the free tier does and does not do.
        let limit: String
        /// Where to get it when it is not on the phone.
        let store: URL?

        init(
            id: String,
            name: String,
            scheme: String?,
            symbol: String = "shield.lefthalf.filled",
            free: Bool = false,
            offer: String = "",
            limit: String = "",
            store: URL? = nil
        ) {
            self.id = id
            self.name = name
            self.scheme = scheme
            self.symbol = symbol
            self.free = free
            self.offer = offer
            self.limit = limit
            self.store = store
        }

        /// The same app, labelled with what it gives you, for somebody who
        /// does not have it yet. The cap goes on the button because the cap is
        /// the decision being made.
        var asOffer: VPNApp {
            VPNApp(
                id: id,
                name: offer.isEmpty ? name : "\(name), \(offer)",
                scheme: scheme,
                symbol: "arrow.down.circle.fill",
                free: free,
                offer: offer,
                limit: limit,
                store: store
            )
        }
    }

    /// The free tiers, least restricted first. These are what Cloak offers to
    /// somebody who has no VPN at all.
    static let freeVPNs: [VPNApp] = [
        VPNApp(
            id: "proton",
            name: "Proton VPN",
            scheme: "protonvpn://",
            free: true,
            offer: "free, no data cap",
            limit: "Free with no data cap and no ads. One device at a time, and the free servers are in ten countries only: the Netherlands, Japan, Romania, Poland, Norway, Switzerland, Singapore, Mexico, Canada and the United States. A pin outside those cannot be covered on the free plan.",
            store: URL(string: "https://apps.apple.com/app/id1437005085")
        ),
        VPNApp(
            id: "windscribe",
            name: "Windscribe",
            scheme: "windscribe://",
            free: true,
            offer: "free, 10 GB a month",
            limit: "Ten gigabytes a month once you confirm an email address, two before that, on free servers in ten countries: the United States, Canada, the United Kingdom, Hong Kong, France, Germany, the Netherlands, Switzerland, Norway and Romania. Any number of devices.",
            store: URL(string: "https://apps.apple.com/app/id1129435228")
        ),
        VPNApp(
            id: "privado",
            name: "PrivadoVPN",
            // No scheme: this one is not in Info.plist, and canOpenURL answers
            // false for anything that is not, so asking would only ever lie.
            // It is offered every time instead of only when it is missing.
            scheme: nil,
            free: true,
            offer: "free, 10 GB a month",
            limit: "Ten gigabytes a month at full speed, no throttling, any number of devices. The free servers cover Argentina, Brazil, Canada, France, Germany, Mexico, the Netherlands, Switzerland, the United Kingdom and the United States.",
            store: URL(string: "https://apps.apple.com/app/id1498920805")
        ),
        VPNApp(
            id: "tunnelbear",
            name: "TunnelBear",
            scheme: "tunnelbear://",
            free: true,
            offer: "free, 2 GB a month",
            limit: "Two gigabytes a month, which covers checking a pin and very little else. Fine for confirming a server works before you pay for one.",
            store: URL(string: "https://apps.apple.com/app/id564842283")
        ),
    ]

    /// Paid VPNs Cloak can hand off to when they are already on the phone.
    /// Nothing here is recommended, only launched.
    ///
    /// Hotspot Shield is on this list and deliberately not on the free one.
    /// Its free tier is advertising funded, and in August 2017 the Center for
    /// Democracy and Technology filed a complaint with the FTC alleging the
    /// app injected code into users' traffic and shared data with advertisers
    /// while promising anonymity. Somebody who already runs it should still be
    /// able to reach it from here; nobody should be sent to it by Cloak.
    ///
    /// Atlas VPN used to be on this list. Nord Security shut it down in 2024
    /// and moved its users to NordVPN, so the button could only ever have
    /// opened an app that no longer exists.
    static let paidVPNs: [VPNApp] = [
        VPNApp(id: "nord", name: "NordVPN", scheme: "nordvpn://"),
        VPNApp(id: "mullvad", name: "Mullvad", scheme: "mullvad://"),
        VPNApp(id: "express", name: "ExpressVPN", scheme: "expressvpn://"),
        VPNApp(id: "surfshark", name: "Surfshark", scheme: "surfshark://"),
        VPNApp(id: "cyberghost", name: "CyberGhost", scheme: "cyberghost://"),
        VPNApp(id: "pia", name: "Private Internet Access", scheme: "piavpn://"),
        VPNApp(id: "ipvanish", name: "IPVanish", scheme: "ipvanish://"),
        VPNApp(id: "hotspotshield", name: "Hotspot Shield", scheme: "hotspotshield://"),
        VPNApp(id: "norton", name: "Norton VPN", scheme: "nortonvpn://"),
        VPNApp(id: "ivpn", name: "IVPN", scheme: "ivpn://"),
        VPNApp(id: "wireguard", name: "WireGuard", scheme: "wireguard://", symbol: "lock.shield"),
        VPNApp(id: "openvpn", name: "OpenVPN", scheme: "openvpn://", symbol: "lock.shield"),
        VPNApp(id: "tailscale", name: "Tailscale", scheme: "tailscale://", symbol: "lock.shield"),
    ]

    static let knownVPNs: [VPNApp] = freeVPNs + paidVPNs

    /// What to put in front of somebody: every VPN app already on the phone,
    /// then the free ones that are not, so a person with no VPN at all is not
    /// shown an empty row and told to go and sort it out.
    var installedVPNs: [VPNApp] {
        let installed = Self.knownVPNs.filter { isInstalled($0) }
        let offers = Self.freeVPNs.filter { !isInstalled($0) && $0.store != nil }.map(\.asOffer)
        return installed + offers
    }

    /// The free tiers and what each one actually limits, for anybody who wants
    /// the numbers before they install something.
    var freeVPNOffers: [VPNApp] { Self.freeVPNs }

    private func isInstalled(_ app: VPNApp) -> Bool {
        guard let scheme = app.scheme, let url = URL(string: scheme) else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    private init() {
        motionQueue.maxConcurrentOperationCount = 1
        watchPath()
    }

    // MARK: - Inputs

    /// The place being reported, and where the run is going.
    ///
    /// `destination` is the last stop of the route, when the run has one. That
    /// is what gets graded, not the kerb the car happens to be passing. The
    /// grade asks whether the place being claimed holds up, and on a route the
    /// place being claimed is where you say you will be, not the eleven
    /// hundred intermediate points on the way there. Grading the car meant the
    /// reverse geocode, the country and the time zone all belonged to
    /// somewhere the trip is only driving through, and the answer moved under
    /// you for the length of the drive.
    ///
    /// A run with no fixed end, like the joystick or SHIELD, passes nil and is
    /// graded where it is, which is the only honest thing to grade it against.
    func track(pin newPin: Coordinate?, destination newDestination: Coordinate? = nil) {
        let before = gradedPin
        pin = newPin
        destination = newDestination
        let after = gradedPin
        let moved: Bool
        if let before, let after {
            moved = before.distance(to: after) > 1500
        } else {
            moved = (before == nil) != (after == nil)
        }
        if moved {
            pinPlace = nil
            scheduleRefresh(after: 0.6)
        } else {
            regrade()
        }
    }

    /// What the simulation is doing right now, for the motion check.
    func track(simulating: Bool, speed: Double) {
        let changed = simulating != isSimulating
        isSimulating = simulating
        simulatedSpeed = speed
        rememberMovement(speed, running: simulating)
        if changed {
            if simulating { startLiveMotion() } else { stopLiveMotion() }
        }
        regrade()
    }

    /// Peak hold with a window on it, so the motion check is asked about the
    /// journey rather than about this second.
    ///
    /// Fed once per fix. The reported speed goes to exactly zero at every
    /// light and every stop sign, and without this the same drive scored two
    /// different ways depending on whether the light happened to be red.
    private func rememberMovement(_ speed: Double, running: Bool) {
        guard running else {
            topSpeed = 0
            movedAt = nil
            return
        }
        let now = Date()
        if speed > Exposure.movingSpeed {
            topSpeed = max(topSpeed, speed)
            movedAt = now
            return
        }
        // Braking, a red light, a crawl in traffic. None of it ends the
        // journey and the phone was still for all of it, so only a run that
        // has gone nowhere for the whole window stops claiming to move.
        guard let movedAt, now.timeIntervalSince(movedAt) > Self.movementWindow else { return }
        self.movedAt = nil
        topSpeed = 0
    }

    // MARK: - Refreshing

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { await performRefresh() }
    }

    private func scheduleRefresh(after seconds: Double) {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await performRefresh()
        }
    }

    private func performRefresh() async {
        guard let pin = gradedPin else {
            reading = nil
            return
        }
        isChecking = true
        lastError = nil
        defer { isChecking = false }

        async let place = resolvePin(pin)
        async let address = lookupIP()
        async let still = sampleMotion()

        let resolvedPlace = await place
        let resolvedIP = await address
        let resolvedStill = await still

        guard !Task.isCancelled else { return }
        pinPlace = resolvedPlace
        if let resolvedIP { ipPlace = resolvedIP }
        if let resolvedStill { isStationary = resolvedStill }
        regrade()
    }

    private func regrade() {
        guard let pin = gradedPin else {
            reading = nil
            return
        }
        let place = pinPlace ?? Exposure.PinPlace(coordinate: pin)
        let env = Exposure.Environment(
            pin: place,
            ip: ipPlace,
            deviceTimeZone: .current,
            deviceIsStationary: isStationary,
            simulatedSpeed: simulatedSpeed,
            recentTopSpeed: isSimulating ? topSpeed : nil,
            isSimulating: isSimulating
        )
        let graded = Exposure.grade(env)
        reading = graded
        noticeCoverChange(graded)
    }

    /// Whether the connection still backs the pin up.
    ///
    /// Distance was the whole test. Country is the test that actually gets
    /// run, by every payment and streaming service there is, and a server two
    /// hundred kilometres away over a border passes the distance test while
    /// failing that one. Both now count as the cover breaking.
    private func coverHolds(_ graded: Exposure) -> Bool? {
        guard let distance = graded.ipDistance else { return nil }
        if graded.leaks.contains(where: { $0.kind == .country }) { return false }
        return distance < Exposure.ipFarMetres
    }

    private func noticeCoverChange(_ graded: Exposure) {
        guard let matched = coverHolds(graded) else { return }
        defer { lastIPMatched = matched }
        guard let previous = lastIPMatched, previous != matched else { return }
        if !matched, isSimulating {
            let where_ = ipPlace?.placeName ?? "somewhere else"
            let how = graded.ipDistance.map { ", \(Exposure.describe($0)) from the pin" } ?? ""
            onCoverBroke?("Your connection now comes out in \(where_)\(how).")
        } else if matched, previous == false {
            onCoverRestored?()
        }
    }

    // MARK: - The pin, in words

    private func resolvePin(_ coordinate: Coordinate) async -> Exposure.PinPlace {
        if let cached = pinPlace, cached.coordinate.distance(to: coordinate) < 1500 {
            return cached
        }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        do {
            let marks = try await geocoder.reverseGeocodeLocation(location)
            if let mark = marks.first {
                return Exposure.PinPlace(
                    coordinate: coordinate,
                    city: mark.locality ?? mark.subAdministrativeArea,
                    region: mark.administrativeArea,
                    countryCode: mark.isoCountryCode,
                    timeZone: mark.timeZone
                )
            }
        } catch {
            lastError = "Could not name the pin: \(error.localizedDescription)"
        }
        return Exposure.PinPlace(coordinate: coordinate)
    }

    // MARK: - Where the connection comes out

    private struct IPInfo: Decodable {
        let ip: String
        let city: String?
        let region: String?
        let country: String?
        let loc: String?
        let timezone: String?
    }

    private func lookupIP() async -> Exposure.IPPlace? {
        guard let url = URL(string: "https://ipinfo.io/json") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                lastError = "The address lookup answered oddly."
                return nil
            }
            let info = try JSONDecoder().decode(IPInfo.self, from: data)
            guard let loc = info.loc else {
                lastError = "The address lookup had no position."
                return nil
            }
            let parts = loc.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { return nil }
            return Exposure.IPPlace(
                address: info.ip,
                coordinate: Coordinate(latitude: parts[0], longitude: parts[1]),
                city: info.city,
                region: info.region,
                countryCode: info.country,
                timeZone: info.timezone.flatMap(TimeZone.init(identifier:)),
                checkedAt: Date()
            )
        } catch {
            lastError = "Could not look up your address: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Whether the phone is really moving

    private nonisolated func sampleMotion() async -> Bool? {
        guard CMMotionActivityManager.isActivityAvailable() else { return nil }
        let end = Date()
        let start = end.addingTimeInterval(-25)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            motion.queryActivityStarting(from: start, to: end, to: motionQueue) { activities, _ in
                // The most recent reading that actually says something. The
                // very last one is often a shrug, and a shrug is not evidence
                // that the phone moved.
                let told = activities?.reversed().compactMap(Self.stillness).first
                continuation.resume(returning: told)
            }
        }
    }

    /// Whether this reading is a phone that is not going anywhere, or nil when
    /// the reading says nothing either way.
    ///
    /// CoreMotion reports `unknown` while it is making its mind up, and marks
    /// guesses as low confidence. Reading either of those as "the phone is
    /// moving" clears a twenty-five point leak on no evidence at all, and
    /// since updates arrive every time the classifier changes its mind, that
    /// alone made the grade flicker with the phone flat on a table. No
    /// evidence now changes nothing and the last real observation stands.
    private nonisolated static func stillness(_ activity: CMMotionActivity) -> Bool? {
        guard !activity.unknown, activity.confidence != .low else { return nil }
        return activity.stationary && !activity.walking && !activity.running && !activity.automotive && !activity.cycling
    }

    private func startLiveMotion() {
        guard motionAvailable, !liveMotion else { return }
        liveMotion = true
        // Same trap as above: this handler runs on motionQueue, so it must not
        // be main-actor isolated. It reads the activity there and hops.
        let handler: @Sendable (CMMotionActivity?) -> Void = { [weak self] activity in
            guard let activity, let still = ExposureController.stillness(activity) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isStationary != still else { return }
                self.isStationary = still
                self.regrade()
            }
        }
        motion.startActivityUpdates(to: motionQueue, withHandler: handler)
    }

    private func stopLiveMotion() {
        guard liveMotion else { return }
        liveMotion = false
        motion.stopActivityUpdates()
    }

    // MARK: - Watching for a VPN switch

    private func watchPath() {
        let stream = AsyncStream<NWPath> { continuation in
            pathMonitor.pathUpdateHandler = { continuation.yield($0) }
            pathMonitor.start(queue: DispatchQueue(label: "app.cloak.exposure.path"))
        }
        pathTask = Task { [weak self] in
            var last: Date?
            for await _ in stream {
                guard let self else { return }
                let now = Date()
                if let last, now.timeIntervalSince(last) < 2 { continue }
                last = now
                await MainActor.run {
                    guard self.gradedPin != nil else { return }
                    self.scheduleRefresh(after: 2.5)
                }
            }
        }
    }

    // MARK: - Handing off

    /// Opens the app when it is there, and the App Store page when it is not.
    func open(_ app: VPNApp) {
        if let scheme = app.scheme, let url = URL(string: scheme), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else if let store = app.store {
            UIApplication.shared.open(store)
        }
    }

    func openDateTimeSettings() {
        if let url = URL(string: "App-prefs:General&path=DATE_AND_TIME"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
