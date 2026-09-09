import Foundation

/// The loopback reflector.
///
/// iOS refuses a connection from this phone to its own pairing service. A
/// packet-tunnel provider that swaps source and destination on every packet
/// fixes that: the connection leaves the phone and arrives back at it looking
/// like it came from somewhere else.
///
/// Two apps can provide that reflector and Cloak works with either.
///
/// * Cloak's own tunnel extension, which only exists in builds signed by a
///   paid Apple Developer account. A free Apple ID cannot sign a network
///   extension at all, so a sideloaded Cloak ships without one.
/// * LocalDevVPN, a free App Store app that does exactly the same thing. It
///   is the route Vanish uses, and it is what makes a free-signed Cloak work.
public enum Reflector {
    /// Address the phone answers on once a reflector is running. Both apps use
    /// this as the tunnel's peer address, so the connection target is the same
    /// either way.
    public static let peer = "10.7.0.1"

    /// The IPv6 side of Cloak's own reflector.
    public static let peer6 = "fd00:c10a:0:7::1"

    /// Address Cloak's own tunnel gives this phone.
    public static let cloakInterface = "10.7.0.0"

    /// Address LocalDevVPN gives this phone by default.
    public static let localDevVPNInterface = "10.7.1.1"

    /// Any address in LocalDevVPN's /24 counts: the app lets people change it.
    private static let localDevVPNPrefix = "10.7.1."

    public enum Kind: String, Sendable, Equatable {
        case builtIn
        case localDevVPN
        case none

        public var name: String {
            switch self {
            case .builtIn: "Cloak's own tunnel"
            case .localDevVPN: "LocalDevVPN"
            case .none: "no tunnel"
            }
        }
    }

    /// Which reflector, if any, is carrying traffic right now.
    ///
    /// Read off the interface list rather than from NetworkExtension, so the
    /// answer is the same whether the tunnel belongs to Cloak or to another
    /// app entirely.
    public static func active() -> Kind {
        for address in interfaceAddresses() {
            if address == cloakInterface { return .builtIn }
            if address == localDevVPNInterface || address.hasPrefix(localDevVPNPrefix) {
                return .localDevVPN
            }
        }
        return .none
    }

    public static var isUp: Bool { active() != .none }

    /// Whether this copy of Cloak carries its own tunnel extension.
    ///
    /// A sideloaded build has no `PlugIns/CloakTunnel.appex`, so asking the
    /// bundle is both accurate and free.
    public static var hasBuiltInTunnel: Bool {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return false }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: plugins.path)) ?? []
        return contents.contains { $0.hasSuffix(".appex") && $0.localizedCaseInsensitiveContains("tunnel") }
    }

    // MARK: - LocalDevVPN

    public enum LocalDevVPN {
        public static let scheme = "localdevvpn"
        public static let appStoreID = "6755608044"

        public static var appStoreURL: URL {
            URL(string: "https://apps.apple.com/app/id\(appStoreID)")!
        }

        /// Turn the tunnel on and come straight back to Cloak.
        public static func enableURL(returningTo callback: String) -> URL {
            URL(string: "\(scheme)://enable?scheme=\(callback)")!
        }

        public static func disableURL(returningTo callback: String) -> URL {
            URL(string: "\(scheme)://disable?scheme=\(callback)")!
        }
    }

    // MARK: - Interfaces

    static func interfaceAddresses() -> [String] {
        var found: [String] = []

        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return found }
        defer { freeifaddrs(pointer) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }

            let text = String(cString: host)
            if !text.isEmpty { found.append(text) }
        }

        return found
    }
}
