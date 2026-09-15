import Foundation
import os
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

    private static let log = Logger(subsystem: "app.cloak.ios", category: "pairing-handoff")

    /// The copy that came inside the app.
    ///
    /// The installer puts it here before signing, so it arrives with the app on
    /// every iOS version. This is the one that matters below iOS 27, where the
    /// phone cannot pair with itself and there is no other way for it to have a
    /// pairing record at all.
    static var bundledURL: URL? {
        guard let url = Bundle.main.url(forResource: "cloak-pairing", withExtension: "plist") else {
            return nil
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A copy dropped into Documents. The older route, kept because a file put
    /// there by hand still works and costs nothing to look for.
    static var incomingURL: URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = documents.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The remote pairing record the installer made from the computer, the
    /// one that works from iOS 26.4 on where the lockdown record does not.
    /// Taken on once, into the same keychain slot the phone fills when it
    /// pairs by itself, so everything downstream is identical either way.
    @discardableResult
    static func adoptRemoteRecord() -> Bool {
        guard RemotePairingBackend.storedRecord == nil,
              let url = Bundle.main.url(forResource: "cloak-rppairing", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }
        let record = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !record.isEmpty else { return false }
        SecureDefaults.set(record, forKey: RemotePairingBackend.recordKey)
        log.notice("adopted the remote pairing record that came inside the app")
        return true
    }

    /// Imports the record if one is waiting. Returns true if something new was
    /// taken on.
    @discardableResult
    static func adopt(into store: PairingStore) -> Bool {
        // Documents first: a file put there deliberately is newer than whatever
        // shipped inside the app, and is deleted once taken.
        if let url = incomingURL,
           let data = try? Data(contentsOf: url),
           let record = try? PairingRecord.parse(data),
           (try? store.save(record)) != nil {
            try? FileManager.default.removeItem(at: url)
            log.notice("adopted the pairing record left in Documents")
            return true
        }

        // The bundled copy is read-only and stays where it is, so it is only
        // taken when there is nothing already stored.
        guard !store.hasRecord else {
            log.notice("already had a pairing record, nothing to adopt")
            return false
        }
        guard let url = bundledURL else {
            log.notice("no pairing record came with this build")
            return false
        }
        guard let data = try? Data(contentsOf: url) else {
            log.error("the bundled pairing record could not be read")
            return false
        }
        guard let record = try? PairingRecord.parse(data) else {
            log.error("the bundled pairing record did not parse")
            return false
        }
        do {
            try store.save(record)
        } catch {
            log.error("the bundled pairing record could not be stored: \(String(describing: error), privacy: .public)")
            return false
        }
        log.notice("adopted the pairing record that came inside the app")
        return true
    }
}
