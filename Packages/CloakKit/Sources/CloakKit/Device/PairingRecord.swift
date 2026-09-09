import Foundation
import Security

public struct PairingRecord: Hashable, Sendable {
    public var plist: Data
    public var udid: String
    public var importedAt: Date

    public init(plist: Data, udid: String, importedAt: Date = .now) {
        self.plist = plist
        self.udid = udid
        self.importedAt = importedAt
    }

    public static func parse(_ data: Data) throws -> PairingRecord {
        guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any] else {
            throw PairingError.notAPropertyList
        }
        let udid = (dictionary["UDID"] as? String)
            ?? (dictionary["SystemBUID"] as? String)
            ?? (dictionary["HostID"] as? String)
        guard dictionary["HostPrivateKey"] != nil || dictionary["HostCertificate"] != nil else {
            throw PairingError.missingKeys
        }
        guard let udid else { throw PairingError.missingIdentifier }
        return PairingRecord(plist: data, udid: udid)
    }
}

public enum PairingError: LocalizedError, Sendable {
    case notAPropertyList
    case missingKeys
    case missingIdentifier
    case notStored
    case rejectedByDevice
    case keychainFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .notAPropertyList: "That file is not a pairing record."
        case .missingKeys: "That pairing record has no host certificate, so the phone will refuse it."
        case .missingIdentifier: "That pairing record has no device identifier."
        case .notStored: "No pairing record is saved yet."
        case .rejectedByDevice: "The phone rejected the pairing record. Generate a new one."
        case .keychainFailed(let status):
            "The Keychain refused the pairing record (OSStatus \(status))."
        }
    }
}
