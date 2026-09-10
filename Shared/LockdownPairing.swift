import Foundation
import UIKit
import CloakKit

/// Pairing this phone with itself over lockdown.
///
/// The route this replaces asked Bonjour where iOS had put its
/// `_remotepairing._tcp` service, because that one listens on a port that
/// changes every boot. Pairing therefore depended on Wi-Fi being on, on Local
/// Network permission, on multicast surviving the network, and on iOS choosing
/// to advertise at all. Miss any one and there was nothing to connect to and
/// nothing useful to say about why.
///
/// Lockdown has none of those conditions. It is the service every computer has
/// always used to pair with an iPhone, it is always listening, and it is always
/// on port 62078. There is nothing to discover. The loopback reflector is what
/// makes a connection this phone opens to itself arrive looking like it came
/// from somewhere else, and that works with Wi-Fi off entirely.
public enum LockdownPairing {
    public enum Progress: Equatable, Sendable {
        case idle
        case connecting(String)
        /// iOS has put its own Trust alert on screen.
        case waitingForTrust
        case paired
        case failed(String)
    }

    private static let hostIdKey = "lockdownHostId"
    private static let buidKey = "lockdownSystemBuid"

    /// Kept rather than regenerated, so a phone that has already trusted this
    /// app is not asked a second time.
    private static func identifier(for key: String) -> String {
        if let existing = AppGroup.defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        AppGroup.defaults.set(fresh, forKey: key)
        return fresh
    }

    public static var hostName: String {
        let device = UIDevice.current.name
        return device.isEmpty ? "Cloak" : "Cloak on \(device)"
    }

    /// Every address worth trying, reflector first.
    ///
    /// The reflector is the one that can work, because it is the only one where
    /// the connection arrives looking like it came from another machine. The
    /// rest are there so a failure says something specific rather than nothing.
    public static func addresses() -> [String] {
        var list = [LocalAddresses.reflector, LocalAddresses.reflector6]
        for address in LocalAddresses.candidates() where !list.contains(address) {
            list.append(address)
        }
        return list
    }
}

#if canImport(CloakBridge)
import CloakBridge

extension LockdownPairing {
    /// Asks iOS to pair, and keeps the record if it says yes.
    ///
    /// Returns once the phone has answered its own Trust alert, or given up on
    /// it. `onProgress` runs on the main actor so it can drive a screen.
    @discardableResult
    public static func pair(
        onProgress: @MainActor @escaping (Progress) -> Void = { _ in }
    ) async -> Bool {
        let joined = addresses().joined(separator: ",")
        let started = joined.withCString { list in
            identifier(for: hostIdKey).withCString { host in
                identifier(for: buidKey).withCString { buid in
                    hostName.withCString { name in
                        cloak_lockdown_pair_start(list, host, buid, name) == 0
                    }
                }
            }
        }

        guard started else {
            await MainActor.run { onProgress(.failed("Pairing is already running.")) }
            return false
        }

        // The bridge does the waiting; this only reads what it is up to. iOS
        // gives somebody as long as they like to answer the Trust alert, so
        // there is no deadline here beyond the bridge's own.
        while true {
            try? await Task.sleep(for: .milliseconds(400))

            var scratch = [CChar](repeating: 0, count: 32768)
            guard cloak_lockdown_pair_state(&scratch, scratch.count) == 0 else { continue }
            let text = String(cString: scratch)
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = object["state"] as? String else { continue }

            switch state {
            case "starting", "idle":
                continue

            case "connecting":
                let detail = object["detail"] as? String ?? ""
                await MainActor.run { onProgress(.connecting(detail)) }

            case "waiting-for-trust":
                await MainActor.run { onProgress(.waitingForTrust) }

            case "paired":
                guard let record = object["record"] as? String, !record.isEmpty else {
                    await MainActor.run {
                        onProgress(.failed("iOS agreed to pair but sent nothing back."))
                    }
                    return false
                }
                AppGroup.defaults.set(record, forKey: RemotePairingBackend.recordKey)
                await MainActor.run { onProgress(.paired) }
                return true

            case "failed":
                let reason = object["reason"] as? String ?? "Pairing did not complete."
                await MainActor.run { onProgress(.failed(reason)) }
                return false

            default:
                continue
            }
        }
    }
}

#else

extension LockdownPairing {
    @discardableResult
    public static func pair(
        onProgress: @MainActor @escaping (Progress) -> Void = { _ in }
    ) async -> Bool {
        await MainActor.run { onProgress(.failed("This build has no pairing bridge.")) }
        return false
    }
}

#endif
