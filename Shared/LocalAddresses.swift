import Foundation

public enum LocalAddresses {
    public static let reflector = "10.7.0.1"

    /// The IPv6 side of the same reflector. Needed on cellular, where the phone
    /// has no real IPv4 address and so no IPv4 listener to reach.
    public static let reflector6 = "fd00:c10a:0:7::1"

    public static func candidates() -> [String] {
        var found: [String] = [reflector, "127.0.0.1"]

        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return found }
        defer { freeifaddrs(pointer) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }

            guard let address = entry.pointee.ifa_addr else { continue }
            guard address.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: entry.pointee.ifa_name)
            guard name != "lo0" else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }

            let text = String(cString: host)
            guard !text.isEmpty, !found.contains(text), text != "10.7.0.0" else { continue }
            found.append(text)
        }

        return found
    }

    public static var joined: String { candidates().joined(separator: ",") }
}
