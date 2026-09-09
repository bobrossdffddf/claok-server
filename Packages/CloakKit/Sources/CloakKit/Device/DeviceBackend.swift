import Foundation

public protocol DeviceBackend: Sendable {
    func connect(pairing: PairingRecord) async throws
    func mountDeveloperImage() async throws
    func openLocationService() async throws
    func setLocation(_ coordinate: Coordinate) async throws
    func clearLocation() async throws
    func disconnect() async
    var isConnected: Bool { get async }

    /// False when the backend brings itself up without a record imported from a
    /// computer — the phone-only pairing path is like this.
    var requiresPairingRecord: Bool { get async }
}

public extension DeviceBackend {
    var requiresPairingRecord: Bool { get async { true } }
}

public enum DeviceBackendError: LocalizedError, Sendable {
    case notConnected
    case developerModeOff
    case handshakeFailed(String)
    case imageMountFailed(String)
    case serviceUnavailable(String)
    case bridgeMissing

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to the device services."
        case .developerModeOff: "Developer Mode is off. iOS hides its developer services until you turn it on in Settings."
        case .handshakeFailed(let detail): "The phone refused the connection. \(detail)"
        case .imageMountFailed(let detail): "The developer image would not mount. \(detail)"
        case .serviceUnavailable(let detail): "The location service is not reachable. \(detail)"
        case .bridgeMissing: "The device bridge framework is not built into this app."
        }
    }
}
