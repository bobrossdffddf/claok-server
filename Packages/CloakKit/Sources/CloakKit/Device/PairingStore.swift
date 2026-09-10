import Foundation
import Security

public struct PairingStore: Sendable {
    private let service: String
    private let account: String

    public init(service: String = "app.cloak.pairing", account: String = "primary") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// Where the record goes when the keychain will not take it.
    ///
    /// The keychain is the better home and stays the first choice, but it can
    /// refuse: an app signed without the entitlement it wants gets
    /// errSecMissingEntitlement and nothing is stored. On a phone below iOS 27
    /// that record is the only way Cloak can reach the developer services at
    /// all, so losing it to a keychain refusal means the app simply does not
    /// work, with no obvious reason why.
    ///
    /// The container is private to this app, and the same record already ships
    /// inside the app bundle, so a file here gives away nothing that was not
    /// already sitting on disk.
    private var fallbackURL: URL {
        AppGroup.containerURL.appendingPathComponent("pairing-\(account).plist")
    }

    public func save(_ record: PairingRecord) throws {
        SecItemDelete(baseQuery as CFDictionary)

        var attributes = baseQuery
        attributes[kSecValueData as String] = record.plist
        attributes[kSecAttrLabel as String] = record.udid
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess {
            try? FileManager.default.removeItem(at: fallbackURL)
            return
        }

        do {
            try record.plist.write(to: fallbackURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            throw PairingError.keychainFailed(status)
        }
    }

    public func load() throws -> PairingRecord {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            // Nothing in the keychain is not the same as nothing anywhere.
            if let data = try? Data(contentsOf: fallbackURL) {
                return try PairingRecord.parse(data)
            }
            throw PairingError.keychainFailed(status)
        }

        guard let result = item as? [String: Any],
              let data = result[kSecValueData as String] as? Data else {
            throw PairingError.notStored
        }

        let label = result[kSecAttrLabel as String] as? String
        if let label, !label.isEmpty {
            return PairingRecord(plist: data, udid: label)
        }
        return try PairingRecord.parse(data)
    }

    public func clear() {
        SecItemDelete(baseQuery as CFDictionary)
        try? FileManager.default.removeItem(at: fallbackURL)
    }

    public var hasRecord: Bool { (try? load()) != nil }
}
