import Foundation
import CloakKit

public enum DeveloperModeProbe {
    public static func check() async -> Bool {
        let backend = BridgeDeviceBackend()
        let store = PairingStore()
        guard let record = try? store.load() else { return false }
        do {
            try await backend.connect(pairing: record)
            try await backend.mountDeveloperImage()
            await backend.disconnect()
            return true
        } catch {
            await backend.disconnect()
            if let backendError = error as? DeviceBackendError {
                switch backendError {
                case .imageMountFailed, .developerModeOff: return false
                default: return false
                }
            }
            return false
        }
    }

    public static let settingsURL = URL(string: "App-prefs:Privacy&path=SECURITY")
}
