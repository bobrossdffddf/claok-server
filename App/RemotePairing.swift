import Foundation
import UIKit
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
        case ready(services: Int, hasDvt: Bool)
        case failed(String)
    }

    var phase: Phase = .idle
    var pin = ""
    var detail: String?
    var note: String?
    var services: [String] = []
    var hostName = UIDevice.current.name.isEmpty ? "Cloak" : "Cloak on \(UIDevice.current.name)"

    private let advertiser = PairableHostAdvertiser()
    private var poller: Task<Void, Never>?
    private var mountTask: Task<Void, Never>?
    private var triedMount = false
    private var published = false
    private var startedTunnel = false
    private var assertion: UIBackgroundTaskIdentifier = .invalid

    var storedRecord: String? { RemotePairingBackend.storedRecord }

    // MARK: - Entry points

    /// The full flow. Pairs first if this phone has never paired with Cloak,
    /// then raises the tunnel.
    /// iOS 27 flipped the direction: the phone pairs outward to a computer that
    /// advertises itself, and refuses `allowsPairSetup` on the way in. Before
    /// that, the phone accepted pairing from a computer and showed the code
    /// itself. Both routes work, they just run opposite ways round.
    static var usesPairableHost: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }

    /// Kept for the UI. Every supported system has a route now.
    static var isSupported: Bool { true }

    func begin() async {
        stop()
        reset()

        if storedRecord != nil || !Self.usesPairableHost {
            // On iOS 26 the tunnel route does the pairing itself: the handshake
            // fails to verify, the bridge falls through to pair-setup, and iOS
            // puts a code on screen for the user to type in here.
            await connectTunnel()
        } else {
            startHost()
        }
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
        if Self.usesPairableHost {
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
        startedTunnel = false
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
        if !reflectorReady {
            note = "The loopback tunnel is not running. iOS will not answer a connection from this phone without it, so approve the VPN profile for Cloak."
        }

        guard let endpoint = await RemotePairingDiscovery.find() else {
            phase = .failed("""
                iOS is not advertising its pairing service right now.

                Check that Cloak has Local Network permission in Settings and that Wi-Fi is on, then try again.
                """)
            return
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
        poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.apply(RemotePairingBackend.status())
                if case .failed = self.phase { return }
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
