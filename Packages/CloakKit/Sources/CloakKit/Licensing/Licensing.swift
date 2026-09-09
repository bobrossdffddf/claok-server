import Foundation
import CryptoKit
import Security

/// Where the licence server lives, and what it signs with.
///
/// Both are set once, at build time. The public key is only ever used to check
/// a signature, so shipping it in the app gives nothing away.
public enum Licensing {
    /// Change this to your own host before shipping.
    public static var serverBase: URL {
        if let override = AppGroup.defaults.string(forKey: "licenseServer"),
           let url = URL(string: override) {
            return url
        }
        return URL(string: "https://cloak.example.com")!
    }

    /// Base64 of the server's Ed25519 public key, printed by the server on
    /// first run. Empty means licensing is not configured and the app runs
    /// unlocked, which is what a development build wants.
    public static let serverPublicKey = ""

    public static var isConfigured: Bool { !serverPublicKey.isEmpty }

    /// Re-checks the stored token from scratch, right now.
    ///
    /// Deliberately not a cached boolean. Every caller redoes the signature
    /// check, the expiry check and the device check, so there is no single
    /// flag to flip and no single branch to remove. It is still only a client
    /// side check and a determined person can patch all of them; what stops
    /// that being enough is that the developer disk image is not in the app
    /// at all, and only the server hands it over.
    public static var verifiedNow: Bool {
        guard isConfigured else { return true }
        guard let raw = AppGroup.defaults.string(forKey: "licenseToken"),
              let token = LicenseToken.parse(raw) else { return false }
        return !token.isExpired && token.device == DeviceIdentity.id
    }
}

// MARK: - The token

/// What the server hands back: a small signed statement that this licence
/// belongs to this device until a date.
///
/// The phone can check it without asking anyone, which is the point. A server
/// that is down for a fortnight is an inconvenience rather than every paying
/// customer's app going dark.
public struct LicenseToken: Sendable, Equatable {
    public var raw: String
    public var license: String
    public var device: String
    public var plan: String
    public var expiresAt: Date
    public var issuedAt: Date

    public var isExpired: Bool { expiresAt < .now }

    /// Whether it is worth quietly asking the server for a fresh one.
    public var wantsRefresh: Bool {
        expiresAt.timeIntervalSinceNow < 5 * 24 * 3600
    }

    public var daysLeft: Int {
        max(0, Int(expiresAt.timeIntervalSinceNow / 86_400))
    }

    /// Parses `<payload>.<signature>` and checks the signature before
    /// believing a single field inside it.
    public static func parse(_ raw: String, publicKey: String = Licensing.serverPublicKey) -> LicenseToken? {
        let parts = raw.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let payload = base64url(String(parts[0])),
              let signature = base64url(String(parts[1])) else { return nil }

        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              key.isValidSignature(signature, for: payload) else { return nil }

        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let license = object["lic"] as? String,
              let device = object["dev"] as? String,
              let expiry = object["exp"] as? Double else { return nil }

        return LicenseToken(
            raw: raw,
            license: license,
            device: device,
            plan: object["plan"] as? String ?? "standard",
            expiresAt: Date(timeIntervalSince1970: expiry),
            issuedAt: Date(timeIntervalSince1970: object["iat"] as? Double ?? 0)
        )
    }

    private static func base64url(_ text: String) -> Data? {
        var padded = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        return Data(base64Encoded: padded)
    }
}

// MARK: - This device

public enum DeviceIdentity {
    private static let service = "app.cloak.device"
    private static let account = "id"

    /// A stable identifier for this install, made here rather than taken from
    /// the system, so nothing identifying leaves the phone. It is a random
    /// value in the keychain and means nothing anywhere else.
    public static var id: String {
        if let existing = read() { return existing }
        let fresh = UUID().uuidString
        write(fresh)
        return fresh
    }

    private static func read() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        query.removeAll()
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

// MARK: - Talking to the server

public struct LicenseUpdate: Sendable, Equatable {
    public var available: Bool
    public var build: Int
    public var version: String
    public var url: URL?
    public var notes: String
    public var required: Bool
}

public enum LicenseError: LocalizedError, Sendable {
    case notConfigured
    case offline
    case refused(String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Licensing is not set up in this build."
        case .offline: "Cloak could not reach the licence server. Check the connection and try again."
        case .refused(let message): message
        case .badResponse: "The licence server said something Cloak did not understand."
        }
    }
}

public struct LicenseClient: Sendable {
    public init() {}

    public func activate(license: String, deviceName: String) async throws -> LicenseToken {
        try await token(path: "/v1/activate", body: [
            "license": license,
            "device_id": DeviceIdentity.id,
            "device_name": deviceName
        ])
    }

    public func validate(license: String) async throws -> LicenseToken {
        try await token(path: "/v1/validate", body: [
            "license": license,
            "device_id": DeviceIdentity.id
        ])
    }

    public func release(license: String) async throws {
        _ = try await send(path: "/v1/deactivate", body: [
            "license": license,
            "device_id": DeviceIdentity.id
        ])
    }

    public func update(build: Int) async throws -> LicenseUpdate {
        var components = URLComponents(
            url: Licensing.serverBase.appendingPathComponent("v1/update"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "platform", value: "ios"),
            URLQueryItem(name: "build", value: String(build))
        ]
        guard let url = components?.url else { throw LicenseError.badResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LicenseError.offline
        }

        return LicenseUpdate(
            available: object["available"] as? Bool ?? false,
            build: object["build"] as? Int ?? 0,
            version: object["version"] as? String ?? "",
            url: (object["url"] as? String).flatMap(URL.init(string:)),
            notes: object["notes"] as? String ?? "",
            required: object["required"] as? Bool ?? false
        )
    }

    private func token(path: String, body: [String: String]) async throws -> LicenseToken {
        let object = try await send(path: path, body: body)
        guard let raw = object["token"] as? String,
              let parsed = LicenseToken.parse(raw) else {
            throw LicenseError.badResponse
        }
        return parsed
    }

    private func send(path: String, body: [String: String]) async throws -> [String: Any] {
        guard Licensing.isConfigured else { throw LicenseError.notConfigured }

        var request = URLRequest(url: Licensing.serverBase.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            throw LicenseError.offline
        }

        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200..<300).contains(status) else {
            throw LicenseError.refused(object["error"] as? String ?? "That licence was refused.")
        }
        return object
    }
}

// MARK: - Keeping it

public enum LicenseStore {
    private static let tokenKey = "licenseToken"
    private static let keyKey = "licenseKey"

    public static var savedToken: LicenseToken? {
        guard let raw = AppGroup.defaults.string(forKey: tokenKey) else { return nil }
        return LicenseToken.parse(raw)
    }

    public static var savedKey: String? {
        AppGroup.defaults.string(forKey: keyKey)
    }

    public static func save(_ token: LicenseToken, key: String) {
        AppGroup.defaults.set(token.raw, forKey: tokenKey)
        AppGroup.defaults.set(key, forKey: keyKey)
    }

    public static func forget() {
        AppGroup.defaults.removeObject(forKey: tokenKey)
        AppGroup.defaults.removeObject(forKey: keyKey)
    }
}
