import Foundation
import SwiftUI
import UIKit
import CloakKit

/// Brings a loopback reflector up, whichever app happens to provide it.
///
/// Builds signed by a paid developer account carry their own tunnel extension
/// and use it. A sideloaded build signed with a free Apple ID cannot carry one
/// — network extensions are unavailable to free accounts — so it hands off to
/// LocalDevVPN, a free App Store app that reflects packets the same way.
@MainActor
@Observable
final class ReflectorGate {
    enum Provider: Equatable {
        case builtIn
        case localDevVPN
    }

    enum Trouble: Equatable {
        /// LocalDevVPN is needed and is not installed.
        case needsLocalDevVPN
        /// LocalDevVPN is installed but did not come up.
        case localDevVPNDidNotStart
        /// Cloak's own tunnel refused to start.
        case builtInFailed(String)
    }

    private(set) var trouble: Trouble?
    private(set) var isUp = false

    private let tunnel = TunnelController()

    /// Scanning the interface list is not free and its answer flickers while a
    /// tunnel is coming up, so it is sampled on a timer and the published
    /// value only changes after two agreeing samples. Reading it straight from
    /// a view body meant the status flipped several times a second.
    private var watcher: Task<Void, Never>?
    private var disagreements = 0

    /// Opening LocalDevVPN throws the user into another app and back. Doing
    /// that whenever something asks for the tunnel produced exactly what it
    /// sounds like: the two apps trading the screen back and forth. One
    /// attempt, then a wait, is the fix.
    private var lastLaunch: Date = .distantPast
    private var launching = false
    private static let launchCooldown: TimeInterval = 25

    /// Which app is responsible for the reflector in this build.
    var provider: Provider {
        Reflector.hasBuiltInTunnel ? .builtIn : .localDevVPN
    }

    var localDevVPNInstalled: Bool {
        UIApplication.shared.canOpenURL(URL(string: "\(Reflector.LocalDevVPN.scheme)://")!)
    }

    /// Samples the interface list on a slow timer rather than on every draw.
    func watch() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func sample() {
        let live = Reflector.isUp
        if live == isUp {
            disagreements = 0
            return
        }
        disagreements += 1
        // Coming up counts immediately; going away has to say so twice, so a
        // momentary gap does not read as the tunnel dropping.
        if live || disagreements >= 2 {
            isUp = live
            disagreements = 0
            if live { trouble = nil }
        }
    }

    /// Wire this into `TunnelGate` so shared code can ask for the reflector
    /// without knowing which app provides it.
    func install() {
        watch()
        TunnelGate.install { [weak self] target in
            guard let self else { return false }
            return await self.ensureUp(target: target)
        }
    }

    @discardableResult
    func ensureUp(target: String? = nil) async -> Bool {
        if Reflector.isUp {
            trouble = nil
            isUp = true
            return true
        }

        // Two callers arriving at once must not each open another app.
        guard !launching else { return await settled(seconds: 10) }

        switch provider {
        case .builtIn:
            return await startBuiltIn(target: target)
        case .localDevVPN:
            return await startLocalDevVPN()
        }
    }

    func stop() async {
        if provider == .builtIn { await tunnel.stop() }
        isUp = Reflector.isUp
    }

    // MARK: - Cloak's own tunnel

    private func startBuiltIn(target: String?) async -> Bool {
        do {
            try await tunnel.start(target: target)
            let up = await settled()
            trouble = up ? nil : .builtInFailed("The tunnel started but no interface appeared.")
            isUp = up
            return up
        } catch {
            trouble = .builtInFailed(error.localizedDescription)
            isUp = false
            return false
        }
    }

    // MARK: - LocalDevVPN

    /// Opens LocalDevVPN, asks it to turn its tunnel on, and lets it bounce
    /// straight back here. The user sees a flash of another app and nothing
    /// else — no VPN sheet, because they approved it once when they installed
    /// LocalDevVPN.
    private func startLocalDevVPN() async -> Bool {
        guard localDevVPNInstalled else {
            trouble = .needsLocalDevVPN
            isUp = false
            return false
        }

        // If we sent the user over there a moment ago, give it time to come
        // up rather than bouncing them across again.
        let since = Date.now.timeIntervalSince(lastLaunch)
        if since < Self.launchCooldown {
            let up = await settled(seconds: 6)
            if up { return true }
            trouble = .localDevVPNDidNotStart
            return false
        }

        launching = true
        lastLaunch = .now
        defer { launching = false }

        let url = Reflector.LocalDevVPN.enableURL(returningTo: AppLinks.scheme)
        let opened = await UIApplication.shared.open(url)
        guard opened else {
            trouble = .needsLocalDevVPN
            isUp = false
            return false
        }

        // LocalDevVPN brings the tunnel up, waits a second, then reopens
        // Cloak. Watching the interface list is more reliable than watching
        // for the foreground notification, and it works either way.
        let up = await settled(seconds: 14)
        trouble = up ? nil : .localDevVPNDidNotStart
        isUp = up
        return up
    }

    func openAppStoreForLocalDevVPN() {
        UIApplication.shared.open(Reflector.LocalDevVPN.appStoreURL)
    }

    // MARK: - Waiting

    /// The interface appears a beat after the tunnel reports itself connected,
    /// and a connection attempt inside that window comes back refused rather
    /// than retried.
    private func settled(seconds: Int = 8) async -> Bool {
        for _ in 0..<(seconds * 2) {
            if Reflector.isUp {
                isUp = true
                trouble = nil
                return true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }
}

enum AppLinks {
    static let scheme = "cloak"
}
