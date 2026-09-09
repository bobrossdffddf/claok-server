import Foundation
import CloakKit

public struct DeveloperImageBundle: Sendable {
    public var image: Data
    public var trustCache: Data
    public var manifest: Data

    public init(image: Data, trustCache: Data, manifest: Data) {
        self.image = image
        self.trustCache = trustCache
        self.manifest = manifest
    }

    public static var storageDirectory: URL {
        AppGroup.containerURL.appendingPathComponent("DeveloperImage", isDirectory: true)
    }

    public static func load() -> DeveloperImageBundle? {
        load(from: storageDirectory)
    }

    private static func load(from base: URL) -> DeveloperImageBundle? {
        guard let image = try? Data(contentsOf: base.appendingPathComponent("Image.dmg")),
              let trustCache = try? Data(contentsOf: base.appendingPathComponent("Image.dmg.trustcache")),
              let manifest = try? Data(contentsOf: base.appendingPathComponent("BuildManifest.plist")) else {
            return nil
        }
        return DeveloperImageBundle(image: image, trustCache: trustCache, manifest: manifest)
    }

    /// There is deliberately no copy inside the app.
    ///
    /// The image is what iOS needs before it will expose the location service
    /// at all, and it arrives from the licence server after activation. That
    /// makes the licence a dependency rather than a switch: a copy of Cloak
    /// with every check torn out still has nothing to simulate with.
    public static var source: String {
        load(from: storageDirectory) != nil ? "Downloaded after activation" : "Not downloaded yet"
    }

    public func save() throws {
        let base = Self.storageDirectory
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try image.write(to: base.appendingPathComponent("Image.dmg"), options: .atomic)
        try trustCache.write(to: base.appendingPathComponent("Image.dmg.trustcache"), options: .atomic)
        try manifest.write(to: base.appendingPathComponent("BuildManifest.plist"), options: .atomic)
    }

    public static var isPresent: Bool { load() != nil }
}

public struct DeviceDescription: Codable, Sendable {
    public var productVersion: String
    public var buildVersion: String
    public var productType: String
    public var deviceName: String
    public var uniqueChipId: UInt64
}

#if canImport(CloakBridge)
import CloakBridge

public actor BridgeDeviceBackend: DeviceBackend {
    private var session: OpaquePointer?
    private var serviceOpen = false
    public private(set) var description: DeviceDescription?

    public init() {}

    public var isConnected: Bool { session != nil && serviceOpen }

    public func connect(pairing: PairingRecord) async throws {
        await disconnect()

        let addresses = LocalAddresses.joined
        let created: OpaquePointer? = addresses.withCString { addressList in
            pairing.plist.withUnsafeBytes { buffer -> OpaquePointer? in
                guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
                return cloak_session_new(base, buffer.count, addressList)
            }
        }
        guard let created else {
            throw DeviceBackendError.handshakeFailed("The pairing record could not be read.")
        }
        session = created

        var scratch = [CChar](repeating: 0, count: 2048)
        let code = cloak_session_device_info(created, &scratch, scratch.count)
        guard code == CLOAK_OK else {
            throw DeviceBackendError.handshakeFailed(lastError(created) ?? "Code \(code)")
        }

        let json = Data(String(cString: scratch).utf8)
        description = try? JSONDecoder().decode(DeviceDescription.self, from: json)
    }

    public func mountDeveloperImage() async throws {
        guard let session else { throw DeviceBackendError.notConnected }
        guard let bundle = DeveloperImageBundle.load() else {
            throw DeviceBackendError.imageMountFailed("No developer image is stored on this device yet.")
        }

        let code: Int32 = bundle.image.withUnsafeBytes { image in
            bundle.trustCache.withUnsafeBytes { trustCache in
                bundle.manifest.withUnsafeBytes { manifest in
                    cloak_session_mount(
                        session,
                        image.bindMemory(to: UInt8.self).baseAddress, image.count,
                        trustCache.bindMemory(to: UInt8.self).baseAddress, trustCache.count,
                        manifest.bindMemory(to: UInt8.self).baseAddress, manifest.count
                    )
                }
            }
        }

        guard code == CLOAK_OK else {
            throw DeviceBackendError.imageMountFailed(lastError(session) ?? "Code \(code)")
        }
    }

    public func openLocationService() async throws {
        guard let session else { throw DeviceBackendError.notConnected }
        let code = cloak_session_open_service(session)
        guard code == CLOAK_OK else {
            throw DeviceBackendError.serviceUnavailable(lastError(session) ?? "Code \(code)")
        }
        serviceOpen = true
    }

    public func setLocation(_ coordinate: Coordinate) async throws {
        guard let session, serviceOpen else { throw DeviceBackendError.notConnected }
        let code = cloak_session_set_location(session, coordinate.latitude, coordinate.longitude)
        guard code == CLOAK_OK else {
            serviceOpen = false
            throw DeviceBackendError.serviceUnavailable(lastError(session) ?? "Code \(code)")
        }
    }

    public func clearLocation() async throws {
        guard let session else { return }
        _ = cloak_session_clear_location(session)
    }

    public func disconnect() async {
        if let session {
            _ = cloak_session_clear_location(session)
            cloak_session_free(session)
        }
        session = nil
        serviceOpen = false
    }

    private func lastError(_ pointer: OpaquePointer) -> String? {
        guard let raw = cloak_session_last_error(pointer) else { return nil }
        let text = String(cString: raw)
        return text.isEmpty ? nil : text
    }
}

#else

public actor BridgeDeviceBackend: DeviceBackend {
    public init() {}
    public private(set) var description: DeviceDescription?
    public var isConnected: Bool { false }
    public func connect(pairing: PairingRecord) async throws { throw DeviceBackendError.bridgeMissing }
    public func mountDeveloperImage() async throws { throw DeviceBackendError.bridgeMissing }
    public func openLocationService() async throws { throw DeviceBackendError.bridgeMissing }
    public func setLocation(_ coordinate: Coordinate) async throws { throw DeviceBackendError.bridgeMissing }
    public func clearLocation() async throws {}
    public func disconnect() async {}
}

#endif
