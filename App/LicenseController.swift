import Foundation
import SwiftUI
import UIKit
import CloakKit

/// Holds the licence and keeps it fresh.
///
/// The rule the server enforces is one device per licence. The rule this side
/// enforces is softer on purpose: a signed token is good for a fortnight
/// offline, so a server outage, a flight, or a phone with no signal is an
/// inconvenience rather than a locked app.
@MainActor
@Observable
final class LicenseController {
    enum State: Equatable {
        case checking
        case unlocked
        case needsKey
        case refused(String)
    }

    private(set) var state: State = .checking
    private(set) var token: LicenseToken?
    private(set) var update: LicenseUpdate?
    var isWorking = false
    var problem: String?

    private let client = LicenseClient()

    var isUnlocked: Bool { state == .unlocked }

    /// Builds with no licensing configured run unlocked, which is what
    /// development and anyone building this themselves wants.
    var isEnforced: Bool { Licensing.isConfigured }

    func start() async {
        guard isEnforced else {
            state = .unlocked
            await checkForUpdate()
            return
        }

        guard let saved = LicenseStore.savedToken, let key = LicenseStore.savedKey else {
            state = .needsKey
            await checkForUpdate()
            return
        }

        // A token that still verifies is enough to open the app. Whether the
        // server agrees can be settled in the background.
        if !saved.isExpired, saved.device == DeviceIdentity.id {
            token = saved
            state = .unlocked
        } else {
            state = .checking
        }

        if saved.isExpired || saved.wantsRefresh {
            await refresh(key: key, silent: !saved.isExpired)
        }

        await checkForUpdate()
    }

    func activate(key: String) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return }

        isWorking = true
        problem = nil
        defer { isWorking = false }

        do {
            let fresh = try await client.activate(license: trimmed, deviceName: UIDevice.current.name)
            LicenseStore.save(fresh, key: trimmed)
            token = fresh
            state = .unlocked
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Hands the licence back so it can be used on another phone.
    func release() async {
        guard let key = LicenseStore.savedKey else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            try await client.release(license: key)
            LicenseStore.forget()
            token = nil
            state = .needsKey
        } catch {
            problem = error.localizedDescription
        }
    }

    private func refresh(key: String, silent: Bool) async {
        do {
            let fresh = try await client.validate(license: key)
            LicenseStore.save(fresh, key: key)
            token = fresh
            state = .unlocked
        } catch LicenseError.offline {
            // Offline is not a refusal. If the token is still good, nothing
            // happens; if it has run out, say so plainly rather than blaming
            // the licence.
            if state == .checking {
                state = .refused("Cloak has not been able to reach the licence server, and the last check has run out. Connect to the internet and open Cloak again.")
            }
        } catch {
            if silent, state == .unlocked { return }
            LicenseStore.forget()
            state = .refused(error.localizedDescription)
        }
    }

    // MARK: - Updates

    func checkForUpdate() async {
        let build = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
        update = try? await client.update(build: build)
        if update?.available != true { update = nil }
    }

    func openUpdate() {
        guard let url = update?.url else { return }
        UIApplication.shared.open(url)
    }

    func dismissUpdate() {
        update = nil
    }
}
