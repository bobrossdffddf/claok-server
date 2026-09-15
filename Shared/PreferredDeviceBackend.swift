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

    /// Whether a lockdown record is on hand and this iOS can use it. From
    /// iOS 27 the phone refuses connections to its own lockdown port even via
    /// the reflector, so the record is worthless there and the outward pairing
    /// route is used instead.
    public static var hasLockdownRecord: Bool {
        PairingPlan.currentMajor < PairingPlan.pairableHostMajor && PairingStore().hasRecord
    }

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

        // From iOS 26 the remote pairing is the one that is known to work,
        // and the lockdown attempt is slow to fail (several handshakes on
        // several addresses). So when a remote record exists it goes first
        // there, and lockdown is the fallback rather than the other way round.
        if PairingPlan.currentMajor >= PairingPlan.outwardPairingMajor,
           RemotePairingBackend.storedRecord != nil {
            do {
                try await remote.connect(pairing: pairing)
                chosen = remote
                return
            } catch {
                guard Self.hasLockdownRecord else { throw error }
            }
        }

        if Self.hasLockdownRecord {
            do {
                try await lockdown.connect(pairing: pairing)
                chosen = lockdown
                return
            } catch {
                // Falling through to the other route is only worth doing when
                // there is one. Otherwise say what actually fixes it: some
                // iOS builds below 27 (26.4 onwards, going by SideStore's
                // reports) refuse their own lockdown port the way 27 does, and
                // the way out is the same pairing the phone does for itself.
                guard RemotePairingBackend.storedRecord != nil else {
                    throw DeviceBackendError.handshakeFailed(
                        error.localizedDescription
                            + "\n\nThis iPhone did not answer the direct route. Open Settings in Cloak and choose Pair without a computer; Cloak will use that pairing from then on."
                    )
                }
            }
        }

        guard RemotePairingBackend.storedRecord != nil else {
            throw DeviceBackendError.handshakeFailed(
                "This phone has not paired with Cloak yet. Open Settings in Cloak and pair without a computer."
            )
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
