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

    public static func find(timeout: TimeInterval = 8) async -> Endpoint? {
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
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

        guard !endpoints.isEmpty else { return offlineEndpoint() }

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

        guard let first = ports.first else { return offlineEndpoint() }

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
