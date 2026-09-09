import Foundation
import NetworkExtension

private struct Unchecked<T>: @unchecked Sendable {
    let value: T
}

/// Makes iOS answer a connection this phone is making to itself.
///
/// iOS refuses clients running on the same device, and the way round that is to
/// make the packet look like it came from somewhere else. Two mechanisms live
/// here:
///
/// **Reflection.** A packet sent to 10.7.0.1 comes back with source and
/// destination swapped, so it reaches the phone's own stack from a "remote"
/// address. This works only when the service is bound wildcard, which is not
/// always true.
///
/// **Source rewriting.** iOS binds its pairing service to the addresses of real
/// local interfaces — the Wi-Fi address, or 172.20.10.1 when Personal Hotspot
/// is on — and not to this tunnel's address. So for a nominated target address
/// the packet keeps its destination and only its source is rewritten, from the
/// tunnel's own 10.7.0.0 to 10.7.0.1. It then lands on the socket that is
/// actually listening, from an address that is not this device.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    /// This tunnel's own address, and the address packets appear to come from.
    /// They differ in one 16-bit word, which keeps the checksum fixup trivial.
    private static let localV4: [UInt8] = [10, 7, 0, 0]
    private static let peerV4: [UInt8] = [10, 7, 0, 1]

    private var target: [UInt8]?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let configured = (options?["target"] as? String)
            ?? ((protocolConfiguration as? NETunnelProviderProtocol)?
                .providerConfiguration?["target"] as? String)

        target = configured.flatMap(Self.parseV4)

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.7.0.1")

        let ipv4 = NEIPv4Settings(addresses: ["10.7.0.0"], subnetMasks: ["255.255.255.0"])
        var routes = [NEIPv4Route(destinationAddress: "10.7.0.0", subnetMask: "255.255.255.0")]
        // Just the one address, never a whole private range: capturing the
        // user's LAN would break everything else they do while Cloak runs.
        if let configured, target != nil {
            routes.append(NEIPv4Route(destinationAddress: configured, subnetMask: "255.255.255.255"))
        }
        ipv4.includedRoutes = routes
        settings.ipv4Settings = ipv4

        let ipv6 = NEIPv6Settings(addresses: ["fd00:c10a:0:7::2"], networkPrefixLengths: [64])
        ipv6.includedRoutes = [NEIPv6Route(destinationAddress: "fd00:c10a:0:7::", networkPrefixLength: 64)]
        settings.ipv6Settings = ipv6

        settings.mtu = 1280

        let done = Unchecked(value: completionHandler)
        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error {
                done.value(error)
                return
            }
            self?.pump()
            done.value(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        completionHandler?(Data("ok".utf8))
    }

    private func pump() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }

            var outgoing: [Data] = []
            var families: [NSNumber] = []
            outgoing.reserveCapacity(packets.count)
            families.reserveCapacity(packets.count)

            for index in packets.indices {
                let family = protocols[index].int32Value
                guard let handled = self.handle(packets[index], family: family) else { continue }
                outgoing.append(handled)
                families.append(protocols[index])
            }

            if !outgoing.isEmpty {
                self.packetFlow.writePackets(outgoing, withProtocols: families)
            }

            self.pump()
        }
    }

    private func handle(_ packet: Data, family: Int32) -> Data? {
        if family == AF_INET, let target, packet.count >= 20 {
            let source = [UInt8](packet[12..<16])
            let destination = [UInt8](packet[16..<20])

            // Going out to the service: keep the destination, change who it is
            // from.
            if destination == target, source == Self.localV4 {
                return Self.rewrite(packet, sourceNotDestination: true, to: Self.peerV4)
            }

            // Its reply, coming back to the address we invented.
            if source == target, destination == Self.peerV4 {
                return Self.rewrite(packet, sourceNotDestination: false, to: Self.localV4)
            }
        }

        return Self.reflect(packet, family: family)
    }

    // MARK: - Rewriting

    /// Replaces the last two bytes of the source or destination address.
    ///
    /// Only the low 16-bit word changes, so both the IP header checksum and the
    /// transport checksum (which covers a pseudo-header containing the
    /// addresses) can be patched incrementally rather than recomputed.
    static func rewrite(_ packet: Data, sourceNotDestination: Bool, to address: [UInt8]) -> Data? {
        guard packet.count >= 20 else { return nil }
        var copy = packet

        let fieldOffset = sourceNotDestination ? 12 : 16
        let wordOffset = fieldOffset + 2

        let length = packet.count
        copy.withUnsafeMutableBytes { raw in
            guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

            let old = (UInt16(bytes[wordOffset]) << 8) | UInt16(bytes[wordOffset + 1])
            let new = (UInt16(address[2]) << 8) | UInt16(address[3])
            if old == new { return }

            bytes[wordOffset] = address[2]
            bytes[wordOffset + 1] = address[3]

            // IP header checksum.
            patch(bytes, at: 10, from: old, to: new)

            let headerLength = Int(bytes[0] & 0x0F) * 4
            guard headerLength >= 20, length >= headerLength + 8 else { return }

            switch bytes[9] {
            case 6: // TCP
                if length >= headerLength + 18 {
                    patch(bytes, at: headerLength + 16, from: old, to: new)
                }
            case 17: // UDP, where a zero checksum means "not computed"
                let offset = headerLength + 6
                let existing = (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
                if existing != 0 {
                    patch(bytes, at: offset, from: old, to: new)
                }
            default:
                break
            }
        }

        return copy
    }

    /// RFC 1624: HC' = ~(~HC + ~m + m')
    private static func patch(_ bytes: UnsafeMutablePointer<UInt8>, at offset: Int, from old: UInt16, to new: UInt16) {
        let current = (UInt32(bytes[offset]) << 8) | UInt32(bytes[offset + 1])
        var sum = (~current & 0xFFFF) + (UInt32(~old) & 0xFFFF) + UInt32(new)
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        let updated = ~sum & 0xFFFF
        bytes[offset] = UInt8((updated >> 8) & 0xFF)
        bytes[offset + 1] = UInt8(updated & 0xFF)
    }

    static func parseV4(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        for part in parts {
            guard let value = UInt8(part) else { return nil }
            out.append(value)
        }
        return out
    }

    // MARK: - Reflection

    static func reflect(_ packet: Data, family: Int32) -> Data? {
        var copy = packet

        if family == AF_INET {
            guard copy.count >= 20 else { return nil }
            copy.withUnsafeMutableBytes { raw in
                guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for offset in 0..<4 {
                    let source = bytes[12 + offset]
                    bytes[12 + offset] = bytes[16 + offset]
                    bytes[16 + offset] = source
                }
            }
            return copy
        }

        if family == AF_INET6 {
            guard copy.count >= 40 else { return nil }
            copy.withUnsafeMutableBytes { raw in
                guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for offset in 0..<16 {
                    let source = bytes[8 + offset]
                    bytes[8 + offset] = bytes[24 + offset]
                    bytes[24 + offset] = source
                }
            }
            return copy
        }

        return nil
    }
}
