import Foundation
import CloakKit

/// Picks the way in.
///
/// Two routes reach this phone's own developer services, and which one is
/// better depends on what the phone has been given.
///
/// A lockdown pairing record — the kind a computer hands over when it installs
/// Cloak — is the better route by a distance. It goes straight to lockdownd
/// through the loopback reflector, needs no Bonjour, no six digit code and,
/// crucially, no Wi-Fi, so it keeps working on cellular alone.
///
/// Without one, Cloak pairs the phone with itself over `_remotepairing`. That
/// works with no computer anywhere in the story, but iOS only publishes that
/// service while a local network interface exists, which is why that route
/// asks for Wi-Fi.
public actor PreferredDeviceBackend: DeviceBackend {
    private let remote = RemotePairingBackend()
    private let lockdown = BridgeDeviceBackend()
    private var chosen: DeviceBackend?

    public init() {}

    public var isConnected: Bool {
        get async {
            guard let chosen else { return false }
            return await chosen.isConnected
        }
    }

    /// Whether a lockdown record is on hand.
    public static var hasLockdownRecord: Bool { PairingStore().hasRecord }

    public var usingRemotePairing: Bool {
        !Self.hasLockdownRecord
            && (RemotePairingBackend.storedRecord != nil || RemotePairingBackend.status().isReady)
    }

    public var requiresPairingRecord: Bool {
        get async { Self.hasLockdownRecord }
    }

    public func connect(pairing: PairingRecord) async throws {
        // Nothing works without the reflector, on either route.
        _ = await TunnelGate.ensureUp()

        if Self.hasLockdownRecord {
            do {
                try await lockdown.connect(pairing: pairing)
                chosen = lockdown
                return
            } catch {
                // Falling through to the other route is only worth doing when
                // there is one; otherwise the lockdown error is the real
                // answer and should be what the user sees.
                guard RemotePairingBackend.storedRecord != nil else { throw error }
            }
        }

        try await remote.connect(pairing: pairing)
        chosen = remote
    }

    public func mountDeveloperImage() async throws {
        guard let chosen else { throw DeviceBackendError.notConnected }
        try await chosen.mountDeveloperImage()
    }

    public func openLocationService() async throws {
        guard let chosen else { throw DeviceBackendError.notConnected }
        try await chosen.openLocationService()
    }

    public func setLocation(_ coordinate: Coordinate) async throws {
        guard let chosen else { throw DeviceBackendError.notConnected }
        try await chosen.setLocation(coordinate)
    }

    public func clearLocation() async throws {
        try await chosen?.clearLocation()
    }

    public func disconnect() async {
        await chosen?.disconnect()
        chosen = nil
    }
}
