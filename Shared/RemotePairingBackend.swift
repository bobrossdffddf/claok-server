import Foundation
import Network
import CloakKit

/// State the bridge publishes about the remote-pairing tunnel.
public struct RemotePairingStatus: Sendable, Equatable {
    public var state: String = "idle"
    public var detail: String?
    public var note: String?
    public var reason: String?
    public var serviceCount: Int = 0
    public var hasDvt = false
    public var canMount = false
    public var simulating = false
    public var services: [String] = []
    public var record: String?
    public var altIrk: String?
    public var pin: String?
    public var port: UInt16 = 0
    public var identifier: String?
    public var txt: [String: String] = [:]
    public var chipId: UInt64 = 0
    public var udid: String?

    public var isReady: Bool { state == "ready" }
    public var needsPin: Bool { state == "needs-pin" }
    public var failed: Bool { state == "error" }
    public var isAdvertising: Bool { state == "advertising" }
    public var isPaired: Bool { state == "paired" }
}

#if canImport(CloakBridge)
import CloakBridge

/// Talks to iOS's own `_remotepairing._tcp` service on this very phone. No Mac,
/// no cable, no lockdown loopback: the phone pairs with itself, shows a code,
/// and everything afterwards runs over the tunnel that pairing hands back.
public actor RemotePairingBackend: DeviceBackend {
    public static let recordKey = "remotePairingRecord"
    public static let irkKey = "remotePairingAltIrk"
    public static let chipKey = "uniqueChipId"
    public static let udidKey = "uniqueDeviceId"
    public static var storedUdid: String? { AppGroup.defaults.string(forKey: udidKey) }

    private var opened = false

    public init() {}

    public var isConnected: Bool { Self.status().isReady }

    public var requiresPairingRecord: Bool { false }

    // MARK: - Status

    public static func status() -> RemotePairingStatus {
        var scratch = [CChar](repeating: 0, count: 16384)
        guard cloak_rp_state(&scratch, scratch.count) == 0 else { return RemotePairingStatus() }

        let text = String(cString: scratch)
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return RemotePairingStatus()
        }

        var status = RemotePairingStatus()
        status.state = object["state"] as? String ?? "idle"
        status.detail = object["detail"] as? String
        status.note = object["note"] as? String
        status.reason = object["reason"] as? String
        status.serviceCount = object["serviceCount"] as? Int ?? 0
        status.hasDvt = (object["hasDvt"] as? Bool) == true
        status.canMount = (object["canMount"] as? Bool) == true
        status.simulating = (object["simulating"] as? Bool) == true
        status.services = (object["services"] as? [String]) ?? []
        status.record = object["pairing"] as? String
        status.altIrk = object["altIrk"] as? String
        status.pin = object["pin"] as? String
        status.port = UInt16((object["port"] as? Int) ?? 0)
        status.identifier = object["identifier"] as? String
        if status.state == "ready", let winner = object["host"] as? String, !winner.isEmpty {
            Self.rememberWinner(winner)
        }
        if let txt = object["txt"] as? [String: String] { status.txt = txt }

        if let irk = status.altIrk, !irk.isEmpty,
           SecureDefaults.string(forKey: irkKey) != irk {
            SecureDefaults.set(irk, forKey: irkKey)
        }

        // The RSD handshake is the only place the ECID turns up on this path,
        // and the personalized mount is refused without it.
        if let chip = object["chipId"] as? NSNumber, chip.uint64Value != 0 {
            status.chipId = chip.uint64Value
            AppGroup.defaults.set(chip, forKey: chipKey)
        }
        if let udid = object["udid"] as? String, !udid.isEmpty {
            status.udid = udid
            AppGroup.defaults.set(udid, forKey: udidKey)
        }

        // Persist the record the moment it exists: after this the phone never
        // has to show a code again.
        if let record = status.record, !record.isEmpty,
           SecureDefaults.string(forKey: recordKey) != record {
            SecureDefaults.set(record, forKey: recordKey)
        }

        return status
    }

    public static var storedRecord: String? { SecureDefaults.string(forKey: recordKey) }

    public static var storedIrk: String? { SecureDefaults.string(forKey: irkKey) }

    public static func forgetRecord() {
        SecureDefaults.remove(forKey: recordKey)
        SecureDefaults.remove(forKey: irkKey)
    }

    /// Advertise this app as a computer the phone can pair with. iOS 27 and
    /// later will only pair in this direction.
    @discardableResult
    public static func startHost(name: String) -> Bool {
        name.withCString { label in
            withOptional(storedRecord) { record in
                withOptional(storedIrk) { irk in
                    cloak_rp_host_start(label, record, irk) == 0
                }
            }
        }
    }

    private static func withOptional<T>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
        guard let value, !value.isEmpty else { return body(nil) }
        return value.withCString { body($0) }
    }

    /// Kick off pairing. `hosts` is a comma separated candidate list.
    @discardableResult
    public static func start(hosts: String, port: UInt16, record: String?) -> Bool {
        hosts.withCString { address in
            if let record, !record.isEmpty {
                return record.withCString { stored in
                    cloak_rp_start(address, port, stored) == 0
                }
            }
            return cloak_rp_start(address, port, nil) == 0
        }
    }

    /// iOS refuses a client running on this same phone, so the loopback tunnel
    /// goes first: it swaps source and destination on every packet, and the
    /// phone's own stack then sees the connection arriving from elsewhere. The
    /// direct addresses stay behind it in case a future iOS stops caring.
    public static func candidates(for endpoint: RemotePairingDiscovery.Endpoint) -> String {
        var hosts = endpoint.hosts

        // First choice is the address iOS actually has the service bound to.
        // The tunnel routes exactly that address and rewrites the source, so
        // the connection arrives on the right socket looking like it came from
        // another machine.
        var leading: [String] = []
        if let service = RemotePairingDiscovery.serviceAddress() {
            leading.append("\(service)|\(endpoint.port)")
        }

        // Then plain reflection, which works when the service happens to be
        // bound wildcard. Both families, since on cellular there is no IPv4.
        leading.append("\(LocalAddresses.reflector)|\(endpoint.port)")
        leading.append("\(LocalAddresses.reflector6)|\(endpoint.port)")

        // Every IPv6 road this phone has, because IPv4 can be refused to this
        // app outright and the reflector is IPv4 only. These go after the
        // reflector and before the rest; each wrong one fails instantly.
        for address in RemotePairingDiscovery.extraIPv6Candidates() {
            let candidate = "\(address)|\(endpoint.port)"
            if !leading.contains(candidate) { leading.append(candidate) }
        }

        hosts.removeAll { leading.contains($0) }
        // The phone's own interface addresses, scoped link-local, from the
        // remoted advertisement.
        let own = hosts.filter { $0.contains("%") }
        let rest = hosts.filter { !$0.contains("%") }

        // Order matters far more than the list does.
        //
        // These used to go first, on the iOS 26.4 reasoning that the only open
        // pairing service lives there and needs no reflector. On iOS 27 that
        // is wrong and expensive: every direct address resets the handshake,
        // because the service refuses a connection from the phone to itself,
        // so putting them first spends several slow failures before reaching
        // the one road that works. With a reflector up, it goes first.
        var ordered = Reflector.isUp ? (leading + own + rest) : (own + leading + rest)

        // Whatever carried the link last time goes ahead of all of it. The
        // answer rarely changes between runs, and starting there turns a walk
        // down the whole ladder into one connection.
        if let winner = lastWinner {
            let match = ordered.first { $0.components(separatedBy: "|").first == winner }
            if let match {
                ordered.removeAll { $0 == match }
                ordered.insert(match, at: 0)
            } else {
                ordered.insert("\(winner)|\(endpoint.port)", at: 0)
            }
        }
        return ordered.joined(separator: ",")
    }

    private static let winnerKey = "remotePairingWinner"

    /// The address that carried the link last time, if any.
    public static var lastWinner: String? {
        let value = AppGroup.defaults.string(forKey: winnerKey)
        return (value?.isEmpty == false) ? value : nil
    }

    static func rememberWinner(_ host: String) {
        guard AppGroup.defaults.string(forKey: winnerKey) != host else { return }
        AppGroup.defaults.set(host, forKey: winnerKey)
    }

    public static let wifiOffMessage = """
        This phone has no local network interface right now.

        iOS only offers its pairing service once one exists, so on cellular alone there is nothing for Cloak to connect to. Two things give it one, and either is enough.

        Turn Wi-Fi on. It does not have to join a network.

        Or turn on Personal Hotspot, which works on cellular and gives the phone a local network of its own.

        Once the link is up you can turn either back off and Cloak keeps running.
        """

    public static func setRemotedPort(_ port: UInt16) {
        _ = cloak_rp_set_rsd_port(port)
    }

    public static func submitPin(_ pin: String) {
        let trimmed = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = trimmed.withCString { cloak_rp_submit_pin($0) }
    }

    // MARK: - DeviceBackend

    /// Bring the tunnel up on its own, reusing the stored record. Only used when
    /// pairing has already happened once, so no code is needed.
    public func connect(pairing: PairingRecord) async throws {
        if Self.status().isReady { opened = true; return }

        guard let record = Self.storedRecord else {
            throw DeviceBackendError.handshakeFailed("This phone has not paired with itself yet.")
        }

        // Nothing here works without the reflector, and nothing else on this
        // path guarantees it is running.
        let reflector = await TunnelGate.ensureUp(target: RemotePairingDiscovery.serviceAddress())

        guard RemotePairingDiscovery.hasLocalNetworkInterface else {
            throw DeviceBackendError.handshakeFailed(
                Self.wifiOffMessage + "\n\nInterfaces: " + RemotePairingDiscovery.interfaceReport())
        }

        guard var endpoint = await RemotePairingDiscovery.find() else {
            throw DeviceBackendError.handshakeFailed(
                "iOS is not advertising its pairing service, and Cloak has no remembered port to fall back on. Allow Cloak local network access in Settings and try again.")
        }

        guard reflector else {
            throw DeviceBackendError.handshakeFailed(Reflector.missingAdvice)
        }

        // The remoted port, for the route iOS 26.4+ still opens.
        if let remoted = await RemotePairingDiscovery.findRemotedPort() {
            _ = cloak_rp_set_rsd_port(remoted)
            for extra in RemotePairingDiscovery.remotedCandidates(port: remoted) where !endpoint.hosts.contains(extra) {
                endpoint.hosts.append(extra)
            }
        }

        // The tunnel interface takes a moment to carry traffic after the VPN
        // reports connected, and a connection attempt in that window comes back
        // refused rather than retried.
        var started = false
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(700)) }
            started = Self.start(hosts: Self.candidates(for: endpoint), port: endpoint.port, record: record)
            if started { break }
        }

        guard started else {
            throw DeviceBackendError.handshakeFailed("The bridge would not start.")
        }

        try await waitForReady(seconds: 25)
        opened = true
    }

    public func mountDeveloperImage() async throws {
        let status = Self.status()
        if status.hasDvt { return }

        guard status.canMount else {
            throw DeviceBackendError.imageMountFailed(
                "The tunnel does not expose the image mounter, so the image cannot be mounted from here.")
        }
        guard let bundle = DeveloperImageBundle.load() else {
            throw DeviceBackendError.imageMountFailed("No developer image is stored on this device yet.")
        }

        let live = status.chipId
        let stored = (AppGroup.defaults.object(forKey: Self.chipKey) as? NSNumber)?.uint64Value ?? 0
        // Zero is fine to send: the bridge reads the ECID off the handshake
        // itself when we do not have one.
        let chipId = live != 0 ? live : stored

        let sent: Int32 = bundle.image.withUnsafeBytes { image in
            bundle.trustCache.withUnsafeBytes { trustCache in
                bundle.manifest.withUnsafeBytes { manifest in
                    cloak_rp_mount(
                        image.bindMemory(to: UInt8.self).baseAddress, image.count,
                        trustCache.bindMemory(to: UInt8.self).baseAddress, trustCache.count,
                        manifest.bindMemory(to: UInt8.self).baseAddress, manifest.count,
                        chipId
                    )
                }
            }
        }
        guard sent == 0 else {
            throw DeviceBackendError.imageMountFailed("The bridge would not take the image.")
        }

        // Mounting is slow: it uploads the image and talks to Apple's signing
        // server. Give it room, then check the service list again.
        for _ in 0..<120 {
            try? await Task.sleep(for: .seconds(1))
            let now = Self.status()
            if now.hasDvt { return }
            if let note = now.note, note.hasPrefix("mount failed") {
                throw DeviceBackendError.imageMountFailed(String(note.dropFirst("mount failed: ".count)))
            }
        }
        throw DeviceBackendError.imageMountFailed("The mount did not finish in time.")
    }

    public func openLocationService() async throws {
        let status = Self.status()
        guard status.isReady else { throw DeviceBackendError.notConnected }
        guard status.hasDvt else {
            throw DeviceBackendError.serviceUnavailable(
                "iOS is not advertising the location service, which means the developer image is not mounted.")
        }
        opened = true
    }

    public func setLocation(_ coordinate: Coordinate) async throws {
        guard opened else { throw DeviceBackendError.notConnected }
        guard cloak_rp_set_location(coordinate.latitude, coordinate.longitude) == 0 else {
            opened = false
            throw DeviceBackendError.serviceUnavailable("The tunnel dropped.")
        }
        if let note = Self.status().note, !note.isEmpty {
            opened = false
            throw DeviceBackendError.serviceUnavailable(note)
        }
    }

    public func clearLocation() async throws {
        _ = cloak_rp_clear_location()
    }

    public func disconnect() async {
        _ = cloak_rp_clear_location()
        opened = false
    }

    private func waitForReady(seconds: Int) async throws {
        for _ in 0..<(seconds * 2) {
            let status = Self.status()
            if status.isReady { return }
            if status.failed {
                throw DeviceBackendError.handshakeFailed(status.reason ?? "unknown")
            }
            if status.needsPin {
                throw DeviceBackendError.handshakeFailed(
                    "iOS wants a fresh pairing code. Open Setup and pair again.")
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        throw DeviceBackendError.handshakeFailed("The tunnel did not come up in time.")
    }
}

#else

public actor RemotePairingBackend: DeviceBackend {
    public static let recordKey = "remotePairingRecord"
    public init() {}
    public var isConnected: Bool { false }
    public var requiresPairingRecord: Bool { false }
    public static func status() -> RemotePairingStatus { RemotePairingStatus() }
    public static var storedRecord: String? { nil }
    public static var storedIrk: String? { nil }
    public static func forgetRecord() {}
    @discardableResult
    public static func start(hosts: String, port: UInt16, record: String?) -> Bool { false }
    @discardableResult
    public static func startHost(name: String) -> Bool { false }
    public static func submitPin(_ pin: String) {}
    public static func setRemotedPort(_ port: UInt16) {}
    public func connect(pairing: PairingRecord) async throws { throw DeviceBackendError.bridgeMissing }
    public func mountDeveloperImage() async throws { throw DeviceBackendError.bridgeMissing }
    public func openLocationService() async throws { throw DeviceBackendError.bridgeMissing }
    public func setLocation(_ coordinate: Coordinate) async throws { throw DeviceBackendError.bridgeMissing }
    public func clearLocation() async throws {}
    public func disconnect() async {}
}

#endif
