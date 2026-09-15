import Foundation
import Security
import CloakKit

/// Small string values that must survive a reinstall.
///
/// UserDefaults in the app group container are wiped when iOS regenerates the
/// container, which it does on every reinstall. The pairing the phone earned
/// by pairing with itself was kept there and vanished each time the installer
/// ran again, so the six digit code had to be typed all over again. The
/// keychain survives reinstalls. UserDefaults stays as the fallback for builds
/// whose signature the keychain refuses, and as the migration source.
public enum SecureDefaults {
    private static let service = "app.cloak.secure-defaults"

    private static func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    public static func string(forKey key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
           let data = out as? Data,
           let text = String(data: data, encoding: .utf8),
           !text.isEmpty {
            return text
        }
        // Migrate anything an older build left in defaults.
        if let legacy = AppGroup.defaults.string(forKey: key), !legacy.isEmpty {
            set(legacy, forKey: key)
            return legacy
        }
        return nil
    }

    public static func set(_ value: String, forKey key: String) {
        let data = Data(value.utf8)
        var attributes = query(key)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemDelete(query(key) as CFDictionary)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            AppGroup.defaults.set(value, forKey: key)
        } else {
            AppGroup.defaults.removeObject(forKey: key)
        }
    }

    public static func remove(forKey key: String) {
        SecItemDelete(query(key) as CFDictionary)
        AppGroup.defaults.removeObject(forKey: key)
    }
}
