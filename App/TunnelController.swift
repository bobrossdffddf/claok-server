import Foundation
import NetworkExtension
import CloakKit

@MainActor
final class TunnelController {
    private var manager: NETunnelProviderManager?

    private var activeTarget: String?

    func prepare(target: String? = nil) async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let existing = managers.first ?? NETunnelProviderManager()

        let proto = (existing.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AppGroup.tunnelBundleIdentifier
        proto.serverAddress = "Cloak, on this device"
        proto.providerConfiguration = target.map { ["target": $0] } ?? [:]
        proto.disconnectOnSleep = false

        existing.protocolConfiguration = proto
        existing.localizedDescription = "Cloak"
        existing.isEnabled = true

        // No on-demand rules. On-demand is driven by iOS's view of the network,
        // and this tunnel does not use the network at all: it reflects packets
        // straight back at the phone. Leaving it on meant iOS tearing the
        // tunnel down the moment Wi-Fi went away, which is exactly when the
        // reflector is most needed. Cloak starts and stops it explicitly.
        existing.onDemandRules = []
        existing.isOnDemandEnabled = false

        try await existing.saveToPreferences()
        try await existing.loadFromPreferences()
        manager = existing
        activeTarget = target
    }

    var status: NEVPNStatus {
        manager?.connection.status ?? .invalid
    }

    func start(target: String? = nil) async throws {
        // The routed address is baked into the tunnel settings, so a different
        // one means tearing it down and bringing it back.
        let changed = target != nil && target != activeTarget

        if manager == nil || changed {
            try await prepare(target: target ?? activeTarget)
        }
        guard let manager else { return }

        if manager.connection.status == .connected {
            if !changed { return }
            manager.connection.stopVPNTunnel()
            for _ in 0..<20 {
                if manager.connection.status == .disconnected { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        try manager.connection.startVPNTunnel()
        try await waitForConnection()
    }

    func stop() async {
        manager?.connection.stopVPNTunnel()
    }

    func send(_ command: TunnelCommand) async throws -> TunnelReply {
        if manager == nil { try await prepare() }
        if manager?.connection.status != .connected { try await start() }
        guard let session = manager?.connection as? NETunnelProviderSession else {
            return .failed("The tunnel is not running.")
        }
        let payload = try JSONEncoder().encode(command)

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(payload) { response in
                    guard let response, let reply = try? JSONDecoder().decode(TunnelReply.self, from: response) else {
                        continuation.resume(returning: .acknowledged)
                        return
                    }
                    continuation.resume(returning: reply)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func waitForConnection() async throws {
        for _ in 0..<40 {
            if manager?.connection.status == .connected { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw NEVPNError(.configurationInvalid)
    }
}
