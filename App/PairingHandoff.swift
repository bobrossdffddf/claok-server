import Foundation
import CloakKit

/// Picks up a pairing record left in Cloak's Documents folder by the desktop
/// installer.
///
/// The computer that installed Cloak already had a pairing record for this
/// phone — that is how it got the app on there — so it writes a copy in on the
/// way out. Finding it here means the whole pair-with-yourself dance, six digit
/// code and all, never has to happen.
enum PairingHandoff {
    static let fileName = "cloak-pairing.plist"

    static var incomingURL: URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = documents.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Imports the record if one is waiting. Returns true if something new was
    /// taken on.
    @discardableResult
    static func adopt(into store: PairingStore) -> Bool {
        guard let url = incomingURL else { return false }
        defer { try? FileManager.default.removeItem(at: url) }

        guard let data = try? Data(contentsOf: url) else { return false }
        guard let record = try? PairingRecord.parse(data) else { return false }
        guard (try? store.save(record)) != nil else { return false }
        return true
    }
}
