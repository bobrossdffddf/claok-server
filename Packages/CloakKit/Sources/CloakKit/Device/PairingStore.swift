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

    public func save(_ record: PairingRecord) throws {
        SecItemDelete(baseQuery as CFDictionary)

        var attributes = baseQuery
        attributes[kSecValueData as String] = record.plist
        attributes[kSecAttrLabel as String] = record.udid
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
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
        guard status == errSecSuccess else { throw PairingError.keychainFailed(status) }

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
    }

    public var hasRecord: Bool { (try? load()) != nil }
}
