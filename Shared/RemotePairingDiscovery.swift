import Foundation
import Network
import CloakKit

/// Finds iOS's own `_remotepairing._tcp` advertisement on this phone and works
/// out every address worth dialling. The service lives on this very device, so
/// the phone's own interface addresses are always valid fallbacks — and they
/// are what saves us when Bonjour hands back a scoped IPv6 the stack refuses.
public enum RemotePairingDiscovery {
    public struct Endpoint: Sendable, Equatable {
        public var hosts: [String]
        public var port: UInt16

        /// Just the address of the first candidate, for display.
        public var host: String {
            (hosts.first ?? "").components(separatedBy: "|").first ?? ""
        }
        public var joined: String { hosts.joined(separator: ",") }
    }

    public static let serviceType = "_remotepairing._tcp"

    /// The port iOS last advertised its pairing service on. Bonjour needs a
    /// network to answer, but the loopback tunnel does not, so remembering the
    /// port is what keeps Cloak working with Wi-Fi off entirely.
    private static let portKey = "remotePairingPort"

    public static var cachedPort: UInt16? {
        let value = AppGroup.defaults.integer(forKey: portKey)
        return value > 0 ? UInt16(value) : nil
    }

    /// Everything we can reach without a network: the phone talking to itself
    /// through the reflector.
    public static func offlineEndpoint() -> Endpoint? {
        guard let port = cachedPort else { return nil }
        return Endpoint(
            hosts: [
                "\(LocalAddresses.reflector)|\(port)",
                "\(LocalAddresses.reflector6)|\(port)"
            ],
            port: port
        )
    }

    /// Why the last search came back empty, in the app's own words.
    ///
    /// There is no API that reports whether Local Network access was granted,
    /// so the browser's own state is the only evidence there is. A denied
    /// browser goes to `waiting` with a policy error rather than failing, and
    /// telling those two apart is the difference between sending somebody to
    /// the right switch in Settings and sending them to look at their router.
    public enum Obstacle: Sendable, Equatable {
        case localNetworkDenied
        case noNetwork
        case notAdvertising
    }

    nonisolated(unsafe) public private(set) static var lastObstacle: Obstacle?

    public static func find(timeout: TimeInterval = 20) async -> Endpoint? {
        // The first search on a new phone races the Local Network permission
        // alert. iOS puts that alert up the moment a browser starts, the
        // browser sees nothing while it is on screen, and a browser started
        // before permission was granted does not always recover once it is.
        // So: search, and if nothing comes back, throw the browser away and
        // start a fresh one. By then the alert has been answered.
        let halfway = max(timeout / 2, 6)
        if let found = await browse(for: halfway) {
            return found
        }
        // A second browser is refused exactly like the first when permission
        // is the problem, so skip straight to the routes that need none.
        if lastObstacle != .localNetworkDenied, let found = await browse(for: halfway) {
            return found
        }
        if let cached = offlineEndpoint() {
            return cached
        }
        // Bonjour has failed twice and nothing is remembered. The service is
        // still there, on this very phone, listening on some port in the
        // ephemeral range iOS hands out. So knock on the doors through the
        // reflector until one answers, rather than telling the person to go
        // and look at a Settings switch that may not be the problem.
        if let port = await scanForPairingPort() {
            AppGroup.defaults.set(Int(port), forKey: portKey)
            lastObstacle = nil
            return Endpoint(
                hosts: [
                    "\(LocalAddresses.reflector)|\(port)",
                    "\(LocalAddresses.reflector6)|\(port)"
                ],
                port: port
            )
        }
        // Still nothing. The bridge has one more route that needs no
        // advertisement at all: the phone's remoted service on its fixed
        // port. Hand it the reflector so it can try; the classic port is
        // only a placeholder here.
        return Endpoint(
            hosts: ["\(LocalAddresses.reflector)|49152"],
            port: 49152
        )
    }

    /// Finds the pairing service by trying ports on the reflector address.
    ///
    /// iOS puts `remotepairingd` on a port from the ephemeral range, 49152
    /// upwards, and the loopback reflector delivers a connection to it
    /// without any discovery. A plain TCP accept is not proof on its own, so
    /// each open port is asked to start the RPPairing handshake: the real
    /// service answers the magic, anything else does not.
    /// The port `_remoted._tcp` (Remote Service Discovery) is advertised on.
    /// On the cable it is always 58783; on Wi-Fi iOS picks one, and 26.6.2
    /// only offers pairing through this service, so the port has to be read
    /// off the advertisement. Remembered so the next start needs no browse.
    private static let remotedPortKey = "remotedPort"

    public static var cachedRemotedPort: UInt16? {
        let value = AppGroup.defaults.integer(forKey: remotedPortKey)
        return value > 0 ? UInt16(value) : nil
    }

    public static func findRemotedPort(timeout: TimeInterval = 8) async -> UInt16? {
        let browser = NWBrowser(for: .bonjour(type: "_remoted._tcp", domain: nil), using: .tcp)
        let box = FoundEndpoints()
        browser.browseResultsChangedHandler = { results, _ in
            for result in results { Task { await box.add(result.endpoint) } }
        }
        browser.start(queue: .global())
        let deadline = Date().addingTimeInterval(timeout)
        var endpoints: [NWEndpoint] = []
        while endpoints.isEmpty && Date() < deadline {
            endpoints = await box.values
            if endpoints.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
        }
        browser.cancel()
        for endpoint in endpoints {
            if let resolved = await resolve(endpoint, timeout: 4) {
                AppGroup.defaults.set(Int(resolved.port), forKey: remotedPortKey)
                lastRemotedHosts = resolved.hosts
                return resolved.port
            }
        }
        return cachedRemotedPort
    }

    /// The addresses `_remoted._tcp` resolved to, so they can be dialled
    /// directly as well as through the reflector.
    nonisolated(unsafe) public private(set) static var lastRemotedHosts: [String] = []

    /// Extra candidates for the bridge: the remoted addresses, each tagged
    /// with the remoted port.
    public static func remotedCandidates(port: UInt16) -> [String] {
        lastRemotedHosts.map { "\($0)|\(port)" }
    }

    /// What the last scan saw, for the failure card.
    nonisolated(unsafe) public private(set) static var lastScanReport: String?

    public static func scanForPairingPort(range: ClosedRange<UInt16> = 49152...49450) async -> UInt16? {
        lastScanReport = nil
        let ports = Array(range).filter { $0 != 62078 }
        let batch = 24
        var index = 0
        var openPorts: [UInt16] = []
        while index < ports.count {
            let slice = ports[index..<min(index + batch, ports.count)]
            index += batch
            let hits = await withTaskGroup(of: (UInt16, PortAnswer).self) { group -> [(UInt16, PortAnswer)] in
                for port in slice {
                    group.addTask { (port, await answersPairing(host: LocalAddresses.reflector, port: port)) }
                }
                var found: [(UInt16, PortAnswer)] = []
                for await result in group where result.1 != .closed { found.append(result) }
                return found.sorted { $0.0 < $1.0 }
            }
            if let talks = hits.first(where: { $0.1 == .talks }) {
                lastScanReport = "port \(talks.0) on \(LocalAddresses.reflector) answered the pairing handshake"
                return talks.0
            }
            openPorts.append(contentsOf: hits.map(\.0))
        }
        // Nothing spoke the handshake, but something is listening. The bridge
        // will find out for certain; a wrong guess costs one failed attempt.
        lastScanReport = openPorts.isEmpty
            ? "scanned \(LocalAddresses.reflector) ports \(range.lowerBound)-\(range.upperBound): nothing listening (tunnel up: \(Reflector.isUp))"
            : "scanned \(LocalAddresses.reflector) ports \(range.lowerBound)-\(range.upperBound): open but silent: \(openPorts.map(String.init).joined(separator: ", "))"
        return openPorts.first
    }

    private enum PortAnswer: Equatable { case closed, open, talks }

    /// True when the port accepts a connection and replies to the RPPairing
    /// handshake magic within a moment.
    private static func answersPairing(host: String, port: UInt16, timeout: TimeInterval = 0.9) async -> PortAnswer {
        await withCheckedContinuation { continuation in
            let resumed = ResumeOnce()
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let finish: @Sendable (PortAnswer) -> Void = { answer in
                Task {
                    guard await resumed.claim() else { return }
                    connection.cancel()
                    continuation.resume(returning: answer)
                }
            }
            let opened = OpenFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Task { await opened.set() }
                    // RPPairing wire header: magic, version, then a length.
                    var hello = Data("RPPairing".utf8)
                    hello.append(19)
                    hello.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
                    connection.send(content: hello, completion: .contentProcessed { _ in
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, _, _ in
                            finish((data?.count ?? 0) > 0 ? .talks : .open)
                        }
                    })
                case .failed, .cancelled:
                    Task { finish(await opened.value ? .open : .closed) }
                case .waiting:
                    finish(.closed)
                default:
                    break
                }
            }
            connection.start(queue: .global())
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                finish(await opened.value ? .open : .closed)
            }
        }
    }

    private static func browse(for timeout: TimeInterval) async -> Endpoint? {
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
        let box = FoundEndpoints()
        let denied = DeniedFlag()

        browser.browseResultsChangedHandler = { results, _ in
            for result in results { Task { await box.add(result.endpoint) } }
        }
        browser.stateUpdateHandler = { state in
            switch state {
            case .waiting(let error), .failed(let error):
                // A refused browser reports EPERM or a policy denial rather
                // than saying anything about permission directly.
                let text = "\(error)".lowercased()
                if text.contains("denied") || text.contains("eperm")
                    || text.contains("policy") || text.contains("noauth") {
                    Task { await denied.set() }
                }
            default:
                break
            }
        }
        browser.start(queue: .global())

        let deadline = Date().addingTimeInterval(timeout)
        var endpoints: [NWEndpoint] = []
        while endpoints.isEmpty && Date() < deadline {
            endpoints = await box.values
            if endpoints.isEmpty, await denied.value { break }
            if endpoints.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
        }
        let wasDenied = await denied.value
        browser.cancel()

        guard !endpoints.isEmpty else {
            lastObstacle = wasDenied
                ? .localNetworkDenied
                : (hasLocalNetworkInterface ? .notAdvertising : .noNetwork)
            return nil
        }
        lastObstacle = nil

        // Every candidate carries its own port as "host|port", because more
        // than one device on the network answers and they will not agree on a
        // port. The bridge walks the list until one of them talks back.
        var foreign: [String] = []
        var ports: [UInt16] = []

        for endpoint in endpoints {
            guard let resolved = await resolve(endpoint, timeout: 4) else { continue }
            if !ports.contains(resolved.port) { ports.append(resolved.port) }
            for host in resolved.hosts {
                let candidate = "\(host)|\(resolved.port)"
                if !foreign.contains(candidate) { foreign.append(candidate) }
            }
        }

        guard let first = ports.first else {
            // Something answered the browse but would not resolve, which is
            // not the same as nothing being there. Let the caller try again.
            lastObstacle = .notAdvertising
            return nil
        }

        AppGroup.defaults.set(Int(first), forKey: portKey)

        // The service we actually want is on this very phone. Other devices on
        // the network advertise the same service and will accept the socket
        // before resetting it, so this phone's own addresses go first and
        // everything else is only a fallback.
        let mine = localAddresses()
        var own: [String] = []
        for host in mine {
            for port in ports {
                let candidate = "\(host)|\(port)"
                if !own.contains(candidate) { own.append(candidate) }
            }
        }

        let isMine: (String) -> Bool = { candidate in
            let host = candidate.components(separatedBy: "|").first ?? candidate
            let bare = host.components(separatedBy: "%").first ?? host
            return mine.contains { existing in
                (existing.components(separatedBy: "%").first ?? existing) == bare
            }
        }

        // IPv4 first within each group: it is the least fussy of the candidates.
        let byFamily: (String, String) -> Bool = { lhs, rhs in
            let l = (lhs.components(separatedBy: "|").first?.contains(":") == true) ? 1 : 0
            let r = (rhs.components(separatedBy: "|").first?.contains(":") == true) ? 1 : 0
            return l < r
        }

        own.sort(by: byFamily)
        var rest = foreign.filter { !isMine($0) && !own.contains($0) }
        rest.sort(by: byFamily)

        return Endpoint(hosts: own + rest, port: first)
    }

    /// Everything Bonjour can actually see from this phone, as text somebody
    /// can paste into a message.
    ///
    /// Written because guessing at why pairing cannot find the phone has cost
    /// enough time already. It browses every service the pairing routes depend
    /// on and records what each browser reported, including the states that
    /// distinguish a refusal from an empty network.
    public static func survey(timeout: TimeInterval = 6) async -> String {
        var lines: [String] = ["Cloak pairing report"]
        lines.append(ProcessInfo.processInfo.operatingSystemVersionString)
        lines.append("reflector: \(Reflector.active().name)")
        lines.append("remembered pairing port: \(cachedPort.map(String.init) ?? "none")")
        lines.append("stored pairing record: \(RemotePairingBackend.storedRecord != nil ? "yes" : "no")")
        lines.append("wifi or wired address: \(hasLocalNetworkInterface ? "yes" : "no")")
        lines.append("")

        for type in [
            "_remotepairing._tcp",
            "_remotepairing-pairable-host._tcp",
            "_remoted._tcp",
            "_apple-mobdev2._tcp",
        ] {
            lines.append("\(type)  ->  \(await probe(type: type, timeout: timeout))")
        }

        lines.append("")
        lines.append("interfaces:")
        lines.append(interfaceReport())
        return lines.joined(separator: "\n")
    }

    private static func probe(type: String, timeout: TimeInterval) async -> String {
        let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
        let box = FoundEndpoints()
        let notes = Notes()

        browser.browseResultsChangedHandler = { results, _ in
            for result in results { Task { await box.add(result.endpoint) } }
        }
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready: Task { await notes.add("ready") }
            case .waiting(let error): Task { await notes.add("waiting: \(error)") }
            case .failed(let error): Task { await notes.add("failed: \(error)") }
            case .cancelled: break
            default: break
            }
        }
        browser.start(queue: .global())

        let deadline = Date().addingTimeInterval(timeout)
        var found: [NWEndpoint] = []
        while found.isEmpty && Date() < deadline {
            found = await box.values
            if found.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
        }
        browser.cancel()

        let states = await notes.values
        let detail = states.isEmpty ? "no state reported" : states.joined(separator: "; ")
        return found.isEmpty ? "nothing (\(detail))" : "\(found.count) found (\(detail))"
    }

    private actor Notes {
        private var items: [String] = []
        func add(_ text: String) { if !items.contains(text) { items.append(text) } }
        var values: [String] { items }
    }

    private actor DeniedFlag {
        private var flag = false
        func set() { flag = true }
        var value: Bool { flag }
    }

    struct Resolution: Sendable {
        var hosts: [String]
        var port: UInt16
    }

    private static func resolve(_ endpoint: NWEndpoint, timeout: TimeInterval) async -> Resolution? {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let box = ResolvedEndpoint()

        connection.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            guard let remote = connection.currentPath?.remoteEndpoint else { return }
            guard case .hostPort(let host, let port) = remote else { return }

            var candidates: [String] = []
            switch host {
            case .ipv4(let value):
                let text = "\(value)"
                candidates.append(text.components(separatedBy: "%").first ?? text)
            case .ipv6(let value):
                // Keep the scope on a link-local address; getaddrinfo needs it.
                let text = "\(value)"
                candidates.append(text)
                if !text.lowercased().hasPrefix("fe80"),
                   let bare = text.components(separatedBy: "%").first, bare != text {
                    candidates.append(bare)
                }
            default:
                candidates.append("\(host)")
            }

            Task { await box.set(Resolution(hosts: candidates, port: port.rawValue)) }
        }
        connection.start(queue: .global())

        let deadline = Date().addingTimeInterval(timeout)
        var result: Resolution?
        while result == nil && Date() < deadline {
            result = await box.value
            if result == nil { try? await Task.sleep(for: .milliseconds(150)) }
        }
        connection.cancel()
        return result
    }

    /// The address iOS actually binds its pairing service to: the IPv4 address
    /// of a real local interface. Wi-Fi when joined, 172.20.10.1 when Personal
    /// Hotspot is on. This is the address the tunnel rewrites traffic towards.
    public static func serviceAddress() -> String? {
        localAddresses().first { !$0.contains(":") }
    }

    /// True when this phone has a Wi-Fi or wired address.
    ///
    /// It matters because iOS only offers its pairing service on that kind of
    /// interface. With Wi-Fi off the service keeps a loopback socket and
    /// nothing else, which is why the reflector gets a refusal there while
    /// ::1 gets a reset: something is listening, just not anywhere a connection
    /// can be made to look like it came from another machine.
    public static var hasLocalNetworkInterface: Bool {
        !localAddresses().isEmpty
    }

    /// Every interface and address on the phone, for diagnostics. The point of
    /// interest is whether a utun carrying the reflector's address exists at
    /// the moment a connection is refused: if it does, the refusal came from
    /// this phone's own stack and the pairing service really is not listening
    /// there. If it does not, the tunnel is the problem instead.
    public static func interfaceReport() -> String {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return "no interfaces" }
        defer { freeifaddrs(head) }

        var lines: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = pointer.pointee.ifa_addr else { continue }
            guard sa.pointee.sa_family == UInt8(AF_INET) || sa.pointee.sa_family == UInt8(AF_INET6) else { continue }

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                              &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }

            let name = String(cString: pointer.pointee.ifa_name)
            let up = Int32(pointer.pointee.ifa_flags) & IFF_UP == IFF_UP
            lines.append("\(name)\(up ? "" : "(down)")=\(String(cString: buffer))")
        }
        return lines.joined(separator: " ")
    }

    /// This phone's own addresses, Wi-Fi first.
    public static func localAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var v4: [String] = []
        var v6: [String] = []

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else { continue }
            guard let sa = pointer.pointee.ifa_addr else { continue }

            // Wi-Fi and wired only. The pairing service is not on the cellular
            // interfaces, and every pdp_ip address just burns a connect timeout.
            let name = String(cString: pointer.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                              &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }

            let text = String(cString: buffer)
            if sa.pointee.sa_family == UInt8(AF_INET) {
                if !v4.contains(text) { v4.append(text) }
            } else if sa.pointee.sa_family == UInt8(AF_INET6) {
                let scoped = (text.lowercased().hasPrefix("fe80") && !text.contains("%"))
                    ? "\(text)%\(name)"
                    : text
                if !v6.contains(scoped) { v6.append(scoped) }
            }
        }

        return v4 + v6
    }
}

private actor FoundEndpoints {
    private(set) var values: [NWEndpoint] = []
    func add(_ endpoint: NWEndpoint) {
        guard !values.contains(where: { "\($0)" == "\(endpoint)" }) else { return }
        values.append(endpoint)
    }
}

private actor ResolvedEndpoint {
    private(set) var value: RemotePairingDiscovery.Resolution?
    func set(_ value: RemotePairingDiscovery.Resolution) { if self.value == nil { self.value = value } }
}


private actor ResumeOnce {
    private var done = false
    func claim() -> Bool {
        if done { return false }
        done = true
        return true
    }
}

private actor OpenFlag {
    private(set) var value = false
    func set() { value = true }
}
