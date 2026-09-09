import Foundation

public actor PreviewDeviceBackend: DeviceBackend {
    private var connected = false
    private var mounted = false
    private var serviceOpen = false
    public private(set) var lastLocation: Coordinate?
    public var failureToInject: DeviceBackendError?

    public init(failureToInject: DeviceBackendError? = nil) {
        self.failureToInject = failureToInject
    }

    public var isConnected: Bool { connected }

    public func connect(pairing: PairingRecord) async throws {
        if let failureToInject { throw failureToInject }
        try await Task.sleep(for: .milliseconds(220))
        connected = true
    }

    public func mountDeveloperImage() async throws {
        guard connected else { throw DeviceBackendError.notConnected }
        try await Task.sleep(for: .milliseconds(340))
        mounted = true
    }

    public func openLocationService() async throws {
        guard mounted else { throw DeviceBackendError.notConnected }
        try await Task.sleep(for: .milliseconds(120))
        serviceOpen = true
    }

    public func setLocation(_ coordinate: Coordinate) async throws {
        guard serviceOpen else { throw DeviceBackendError.notConnected }
        lastLocation = coordinate
    }

    public func clearLocation() async throws {
        lastLocation = nil
    }

    public func disconnect() async {
        connected = false
        mounted = false
        serviceOpen = false
        lastLocation = nil
    }
}
