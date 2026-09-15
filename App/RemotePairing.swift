import Foundation
import UIKit
import os
import Observation
import CloakKit

/// Drives the computer-free pairing flow.
///
/// From iOS 27 the phone will only pair in one direction: it connects out to a
/// computer that advertises itself as pairable. So Cloak advertises itself that
/// way, generates the code, and the user types the code into the iOS prompt.
/// Once paired, Cloak connects back to the phone's own `_remotepairing._tcp`
/// service to raise the tunnel, and never needs a code again.
@MainActor
@Observable
final class RemotePairing {
    enum Phase: Equatable {
        case idle
        case advertising
        case deviceConnected
        case showPin(String)
        case enterPin
        case paired
        case searching
        case connecting
        case tunnelling
        case mounting
        /// iOS has put its own Trust alert on this phone's screen.
        case trusting
        case ready(services: Int, hasDvt: Bool)
        /// Stopped before it could start, because the loopback reflector is
        /// not up and nothing downstream of it can work without it.
        case needsTunnel
        case failed(String)
    }

    private static let log = Logger(subsystem: "app.cloak.ios", category: "remote-pairing")

    var phase: Phase = .idle {
        didSet { Self.log.notice("phase \(String(describing: self.phase), privacy: .public)") }
    }
    var pin = ""
    var detail: String?
    var note: String? {
        didSet { if let note { Self.log.error("note: \(note, privacy: .public)") } }
    }
    var services: [String] = []
    /// Which way this attempt is going about it, so the screen can describe
    /// the right thing rather than the thing that used to happen.
    var route: Route = .lockdown
    private var triedOutward = false
    /// Set when the failure was Local Network permission, so the screen can
    /// offer the one switch that fixes it rather than describing it.
    var needsLocalNetwork = false
    /// Why the direct route did not work, kept so a later failure can say that
    /// both were tried and what each of them said.
    var lockdownFailure: String?
    var hostName = UIDevice.current.name.isEmpty ? "Cloak" : "Cloak on \(UIDevice.current.name)"

    /// The same name, for screens that have no pairing object yet.
    static var hostNameForDisplay: String {
        UIDevice.current.name.isEmpty ? "Cloak" : "Cloak on \(UIDevice.current.name)"
    }

    enum Route: Equatable {
        /// Straight to this phone's own lockdown service on its fixed port.
        case lockdown
        /// iOS 27 and later, where the phone pairs outward to a computer.
        case pairableHost
        /// The old route through iOS's advertised pairing service.
        case discovered
    }

    private let advertiser = PairableHostAdvertiser()
    private var poller: Task<Void, Never>?
    private var mountTask: Task<Void, Never>?
    private var triedMount = false
    private var published = false
    private var startedTunnel = false
    private var assertion: UIBackgroundTaskIdentifier = .invalid

    /// Set when the tunnel card has been shown and the user chose to go on
    /// without it anyway.
    private var ignoreTunnel = false

    var storedRecord: String? { RemotePairingBackend.storedRecord }

    // MARK: - Entry points

    /// The full flow. Pairs first if this phone has never paired with Cloak,
    /// then raises the tunnel.
    /// iOS 27 flipped the direction: the phone pairs outward to a computer that
    /// advertises itself, and refuses `allowsPairSetup` on the way in. Before
    /// that, the phone accepted pairing from a computer and showed the code
    /// itself. Both routes work, they just run opposite ways round.
    static var usesPairableHost: Bool {
        PairingPlan.currentMajor >= PairingPlan.pairableHostMajor
    }

    /// What this phone will actually try, in order. Everything version
    /// dependent goes through here so it can be answered without a phone.
    static var plannedRoutes: [PairingRoute] {
        PairingPlan.routes(
            iOSMajor: PairingPlan.currentMajor,
            hasStoredRecord: RemotePairingBackend.storedRecord != nil
        )
    }

    /// Kept for the UI. Every supported system has a route now.
    static var isSupported: Bool { true }

    func begin(ignoringTunnel: Bool = false) async {
        stop()
        reset()
        ignoreTunnel = ignoringTunnel

        // One list, decided by version and by whether a record already exists.
        let planned = Self.plannedRoutes

        if planned.contains(.stored) {
            await connectTunnel()
            return
        }

        // Lockdown first wherever it is planned. Its port never changes, so
        // nothing has to be discovered: no Bonjour, no Local Network
        // permission, no Wi-Fi. iOS shows its own Trust alert and that is the
        // whole ceremony.
        if planned.contains(.lockdown) {
            route = .lockdown
            if await pairOverLockdown() {
                await connectTunnel()
                return
            }
        }

        // Why it did not work matters more than what is tried next. Without
        // this, a failure here is invisible: the fallback runs, fails for its
        // own unrelated reason, and reports that instead, which reads as
        // though nothing was ever fixed.
        if planned.contains(.lockdown) {
            lockdownFailure = note ?? "no reason given"
        }

        // Only if that could not happen at all. The order below is the
        // version's plan: on 27 outward pairing is the only one that works, on
        // 26 the inbound remote pairing goes first and outward is the last
        // resort, and each falls through to the next on failure.
        let remaining = planned.filter { $0 == .pairableHost || $0 == .discovery }
        for (position, next) in remaining.enumerated() {
            let last = position == remaining.count - 1
            switch next {
            case .pairableHost:
                triedOutward = true
                route = .pairableHost
                startHost()
                return
            case .discovery:
                route = .discovered
                await connectTunnel()
                if case .failed(let reason) = phase, !last {
                    note = "Inbound pairing did not work (\(reason)). Trying outward pairing instead."
                    continue
                }
                return
            default:
                continue
            }
        }
    }

    /// Pairs by asking this phone's own lockdown service, over the reflector.
    private func pairOverLockdown() async -> Bool {
        phase = .searching
        detail = nil

        // iOS resets a connection a device makes to itself, so without the
        // reflector there is nothing on the other end of this.
        let reflector = await TunnelGate.ensureUp(target: RemotePairingDiscovery.serviceAddress())
        if !reflector && !ignoreTunnel {
            note = nil
            phase = .needsTunnel
            return false
        }

        let paired = await LockdownPairing.pair { [weak self] progress in
            guard let self else { return }
            switch progress {
            case .idle:
                break
            case .connecting(let address):
                self.phase = .searching
                self.detail = "Asking this phone to pair on \(address)"
            case .waitingForTrust:
                self.phase = .trusting
                self.detail = nil
            case .paired:
                self.phase = .paired
                self.detail = nil
                self.note = nil
            case .failed(let reason):
                self.note = reason
            }
        }

        if paired { note = nil }
        return paired
    }

    func submitPin() {
        let trimmed = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        RemotePairingBackend.submitPin(trimmed)
        pin = ""
        phase = .tunnelling
    }

    /// Force the pairing half again, even if a record exists. Used when the
    /// stored record has gone stale and the phone resets the connection.
    func repair() async {
        stop()
        reset()
        RemotePairingBackend.forgetRecord()
        // Repair goes straight to the route that survives a refused lockdown
        // port: outward pairing wherever this iOS can do it (26 and up), the
        // old discovery route only below that.
        if Self.plannedRoutes.contains(.pairableHost) {
            route = .pairableHost
            startHost()
        } else {
            await connectTunnel()
        }
    }

    func forget() {
        RemotePairingBackend.forgetRecord()
    }

    func stop() {
        poller?.cancel()
        poller = nil
        mountTask?.cancel()
        mountTask = nil
        advertiser.stop()
        published = false
        endAssertion()
    }

    private func reset() {
        triedMount = false
        triedOutward = false
        startedTunnel = false
        ignoreTunnel = false
        needsLocalNetwork = false
        lockdownFailure = nil
        route = .lockdown
        detail = nil
        note = nil
        services = []
    }

    // MARK: - Pairing half

    private func startHost() {
        // Pairing means leaving Cloak for Settings, and a suspended app stops
        // answering the socket. Hold the process awake across the trip.
        beginAssertion()

        guard RemotePairingBackend.startHost(name: hostName) else {
            endAssertion()
            phase = .failed("The bridge would not start advertising.")
            return
        }
        phase = .advertising
        startPolling()
    }

    private func beginAssertion() {
        guard assertion == .invalid else { return }
        assertion = UIApplication.shared.beginBackgroundTask(withName: "Cloak pairing") { [weak self] in
            Task { @MainActor in self?.endAssertion() }
        }
    }

    private func endAssertion() {
        guard assertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(assertion)
        assertion = .invalid
    }

    private func publishIfNeeded(_ status: RemotePairingStatus) {
        guard !published, status.port != 0, let identifier = status.identifier else { return }
        published = true
        advertiser.publish(name: identifier, port: status.port, txt: status.txt) { [weak self] message in
            Task { @MainActor in self?.note = message }
        }
        detail = "Advertising as \"\(hostName)\" on port \(status.port)"
    }

    // MARK: - Tunnel half

    private func connectTunnel() async {
        phase = .searching

        // Warn rather than refuse. iOS almost certainly will not answer without
        // Wi-Fi, but attempting anyway is what produces the address and
        // interface detail that says why.
        if !RemotePairingDiscovery.hasLocalNetworkInterface {
            note = RemotePairingBackend.wifiOffMessage
        }

        // iOS will not let an app on this phone talk to the phone's own pairing
        // service directly: the handshake gets reset before a byte comes back.
        // The loopback tunnel fixes that. It swaps source and destination on
        // every packet, so a connection to 10.7.0.1 arrives at the phone's own
        // stack looking like it came from another machine.
        let reflectorReady = await TunnelGate.ensureUp(target: RemotePairingDiscovery.serviceAddress())
        if !reflectorReady && !ignoreTunnel {
            // Carrying on without it means a socket iOS resets before a byte
            // comes back, and a failure that reads as though pairing itself
            // went wrong. Stop here instead, so the screen can offer the one
            // thing that actually fixes it.
            note = nil
            phase = .needsTunnel
            return
        }
        if !reflectorReady {
            note = Reflector.missingAdvice
        }

        guard var endpoint = await RemotePairingDiscovery.find() else {
            // One message for three quite different problems was useless. The
            // browser's own state says which one it is.
            let direct = lockdownFailure.map {
                "\n\nPairing directly with this phone was tried first and did not work: \($0)"
            } ?? ""
            let scan = RemotePairingDiscovery.lastScanReport.map { "\n\nPort scan: \($0)" } ?? ""

            switch RemotePairingDiscovery.lastObstacle {
            case .localNetworkDenied:
                needsLocalNetwork = true
                phase = .failed("""
                    Cloak is not allowed to see this phone's own network, and iOS will not tell it where the pairing service is without that.

                    Open Settings, tap Cloak, and turn on Local Network. Then come back and start pairing again.
                    """ + direct + scan)
            case .noNetwork:
                phase = .failed("""
                    This phone has no Wi-Fi address, and iOS only offers its pairing service on a real network interface.

                    Join a Wi-Fi network, or turn on Personal Hotspot, then try again. It can be a network with no internet at all.
                    """ + direct + scan)
            default:
                phase = .failed("""
                    iOS is not advertising its pairing service right now.

                    Make sure Wi-Fi is on and that Cloak has Local Network permission in Settings, then try again. Locking and unlocking the phone often brings it back.
                    """ + direct + scan + "\n\nInterfaces: " + RemotePairingDiscovery.interfaceReport())
            }
            return
        }

        // The remoted port, for the route iOS 26.4+ still opens.
        if let remoted = await RemotePairingDiscovery.findRemotedPort() {
            detail = "remoted on port \(remoted)"
            RemotePairingBackend.setRemotedPort(remoted)
            for extra in RemotePairingDiscovery.remotedCandidates(port: remoted) where !endpoint.hosts.contains(extra) {
                endpoint.hosts.append(extra)
            }
        }

        let hosts = reflectorReady
            ? RemotePairingBackend.candidates(for: endpoint)
            : endpoint.joined

        detail = hosts.replacingOccurrences(of: "|", with: ":").replacingOccurrences(of: ",", with: ", ")

        guard RemotePairingBackend.start(hosts: hosts, port: endpoint.port, record: storedRecord) else {
            phase = .failed("The bridge would not start.")
            return
        }

        phase = .connecting
        startPolling()
    }

    // MARK: - Polling

    private func startPolling() {
        let advertisingSince = ContinuousClock.now
        poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.apply(RemotePairingBackend.status())
                if case .failed = self.phase { return }
                // Below iOS 27 the outward route is a fallback, and a phone
                // that does not browse for pairable hosts never connects. Give
                // it a fair window, then move on to the discovery route rather
                // than sit here advertising to nobody.
                if case .advertising = self.phase,
                   !Self.usesPairableHost,
                   Self.plannedRoutes.firstIndex(of: .discovery).map({ $0 > (Self.plannedRoutes.firstIndex(of: .pairableHost) ?? -1) }) == true,
                   ContinuousClock.now - advertisingSince > .seconds(45) {
                    self.note = "This phone did not come looking for Cloak, trying the pairing service it advertises instead."
                    self.advertiser.stop()
                    self.published = false
                    self.endAssertion()
                    self.route = .discovered
                    self.poller = nil
                    await self.connectTunnel()
                    return
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func apply(_ status: RemotePairingStatus) async {
        if let value = status.note, !value.isEmpty { note = value }
        if !status.services.isEmpty { services = status.services }

        switch status.state {
        case "advertising":
            publishIfNeeded(status)
            phase = .advertising

        case "host-connected":
            advertiser.stop()
            published = false
            detail = status.detail.map { "The phone connected from \($0)" }
            phase = .deviceConnected

        case "show-pin":
            if let pin = status.pin, !pin.isEmpty { phase = .showPin(pin) }

        case "paired":
            advertiser.stop()
            published = false
            guard !startedTunnel else { return }
            startedTunnel = true
            endAssertion()
            phase = .paired
            poller?.cancel()
            poller = nil
            // Straight on to the tunnel, using the record we just earned.
            await connectTunnel()

        case "connecting":
            if case .mounting = phase { return }
            phase = .connecting
            detail = status.detail ?? detail

        case "needs-pin":
            phase = .enterPin

        case "pairing", "tunnelling":
            phase = .tunnelling

        case "ready":
            if status.hasDvt {
                phase = .ready(services: status.serviceCount, hasDvt: true)
                return
            }

            if !triedMount, status.canMount, DeveloperImageBundle.isPresent {
                triedMount = true
                phase = .mounting
                mountTask = Task { [weak self] in
                    let backend = RemotePairingBackend()
                    do {
                        try await backend.mountDeveloperImage()
                    } catch {
                        await MainActor.run { self?.note = error.localizedDescription }
                    }
                }
                return
            }
            if case .mounting = phase { return }
            phase = .ready(services: status.serviceCount, hasDvt: false)

        case "error":
            // Append what the interfaces looked like, because a refusal means
            // something quite different depending on whether the tunnel was
            // actually carrying traffic.
            let reason = (status.reason ?? "unknown")
                + "\n\nInterfaces: " + RemotePairingDiscovery.interfaceReport()
            // On iOS 26 the inbound route may be refused the way 27 refuses it;
            // the outward route is the planned last resort, tried once.
            if route == .discovered, !triedOutward, storedRecord == nil,
               Self.plannedRoutes.last == .pairableHost {
                triedOutward = true
                note = "Inbound pairing was refused (\(status.reason ?? "unknown")). Trying outward pairing instead."
                poller?.cancel()
                poller = nil
                route = .pairableHost
                startHost()
                return
            }
            phase = .failed(reason)
            return

        case "error-unused":
            // Never throw the record away on its own. A reset usually means
            // Cloak reached some other device on the network rather than this
            // phone, and deleting a good pairing over that would be the worst
            // possible response. Re-pairing stays a deliberate choice.
            phase = .failed(status.reason ?? "unknown")

        default:
            break
        }
    }
}
