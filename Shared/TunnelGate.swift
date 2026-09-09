import Foundation

/// The reflector tunnel is what makes iOS answer a connection from this phone
/// to itself, so nothing that needs it should assume somebody else started it.
///
/// The tunnel is driven by NetworkExtension, which only the app can talk to, so
/// the app installs a handler here at launch and shared code asks through it.
public enum TunnelGate {
    nonisolated(unsafe) private static var handler: (@Sendable (String?) async -> Bool)?
    nonisolated(unsafe) private static let lock = NSLock()

    public static func install(_ body: @escaping @Sendable (String?) async -> Bool) {
        lock.lock()
        handler = body
        lock.unlock()
    }

    /// Brings the tunnel up if it is not already, and says whether it is usable.
    ///
    /// `target` is the local address iOS has the pairing service bound to. The
    /// tunnel routes that one address and rewrites the source of traffic to it,
    /// so a change of network means the tunnel has to be restarted.
    public static func ensureUp(target: String? = nil) async -> Bool {
        guard let body = current() else { return false }
        return await body(target)
    }

    private static func current() -> (@Sendable (String?) async -> Bool)? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }
}
