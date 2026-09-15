import Foundation
import Observation
import os
import CloakKit
#if canImport(CloakBridge)
import CloakBridge
#endif

/// Re-signs Cloak from the phone, driving the bridge that does the work.
///
/// A free Apple ID signs an app for seven days. The desktop installer sets up
/// a background job on the computer that renews it, but a phone is not always
/// near that computer, so this does the same thing on the phone: signs in as
/// the user, asks Apple for a fresh certificate, re-signs the copy of Cloak
/// that shipped inside the app, and installs it back over the loopback.
@MainActor
@Observable
final class RenewController {
    enum Phase: Equatable {
        case idle
        case working(String, Double)
        case needsCode(sms: Bool)
        case done
        case failed(String)
    }

    var phase: Phase = .idle
    var signature: SignatureInfo?
    var appleID: String = ""
    var hasStoredPassword: Bool = false
    var autoRenew: Bool = false

    private var poll: Task<Void, Never>?
    private let log = Logger(subsystem: "app.cloak.ios", category: "renew")

    private static let idKey = "renewAppleID"
    private static let passwordKey = "renewPassword"
    private static let autoKey = "renewAutomatically"

    init() {
        signature = SignatureInfo.fromBundle()
        appleID = SecureDefaults.string(forKey: Self.idKey) ?? ""
        hasStoredPassword = SecureDefaults.string(forKey: Self.passwordKey) != nil
        autoRenew = AppGroup.defaults.bool(forKey: Self.autoKey)
    }

    var isBusy: Bool {
        if case .working = phase { return true }
        if case .needsCode = phase { return true }
        return false
    }

    func refreshSignature() {
        signature = SignatureInfo.fromBundle()
    }

    func setAuto(_ on: Bool) {
        autoRenew = on
        AppGroup.defaults.set(on, forKey: Self.autoKey)
        if !on { SecureDefaults.remove(forKey: Self.passwordKey); hasStoredPassword = false }
    }

    func signIn(password: String) {
        SecureDefaults.set(appleID, forKey: Self.idKey)
        if autoRenew, !password.isEmpty {
            SecureDefaults.set(password, forKey: Self.passwordKey)
            hasStoredPassword = true
        }
    }

    func signOut() {
        SecureDefaults.remove(forKey: Self.idKey)
        SecureDefaults.remove(forKey: Self.passwordKey)
        appleID = ""
        hasStoredPassword = false
    }

    #if canImport(CloakBridge)
    func renew(password: String?, pairing: PairingRecord?) {
        guard !isBusy else { return }
        let pass = password?.isEmpty == false ? password! : (SecureDefaults.string(forKey: Self.passwordKey) ?? "")
        guard !appleID.isEmpty, !pass.isEmpty else {
            phase = .failed("Sign in with your Apple ID first.")
            return
        }
        // Below iOS 27 the pairing record the installer left behind is the
        // route in. On 27 there is none; the phone's own tunnel (from pairing
        // without a computer) carries the install, and the UDID comes from it.
        let record = pairing.flatMap { $0.plist.isEmpty || $0.udid.isEmpty ? nil : $0 }
        let udid = record?.udid ?? RemotePairingBackend.storedUdid ?? ""
        guard !udid.isEmpty else {
            phase = .failed("Cloak has not learned this phone's identity yet. Pair without a computer once (Settings, Pairing), then try again.")
            return
        }
        signIn(password: password ?? "")

        // The phone re-signs a copy of the app it is running, the way AltStore
        // does. Nothing has to be left behind by a computer, and it works on
        // every iOS version the installer cannot write into the container on.
        guard let container = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            phase = .failed("Could not find a place to work in.")
            return
        }
        let work = caches.appendingPathComponent("renew", isDirectory: true)
        let ipa = work.appendingPathComponent("Cloak.app", isDirectory: true)
        do {
            try? FileManager.default.removeItem(at: work)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: Bundle.main.bundleURL, to: ipa)
        } catch {
            phase = .failed("Could not make a working copy of Cloak: \(error.localizedDescription)")
            return
        }
        let stateDir = container.appendingPathComponent("renew-state")
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        let name = LockdownPairing.hostName
        phase = .working("Starting", 0.02)

        let plist = record?.plist ?? Data()
        let started = plist.withUnsafeBytes { buffer -> Bool in
            let base = buffer.bindMemory(to: UInt8.self).baseAddress
            return appleID.withCString { id in
                pass.withCString { pw in
                    ipa.path.withCString { ipaPath in
                        stateDir.path.withCString { state in
                            LocalAddresses.reflector.withCString { addr in
                                name.withCString { nm in
                                    udid.withCString { ud in
                                        cloak_renew_start(id, pw, ipaPath, state, base, buffer.count, addr, nm, ud) == 0
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        guard started else {
            phase = .failed("A refresh is already running.")
            return
        }
        startPolling()
    }

    func submitCode(_ code: String) {
        _ = code.withCString { cloak_renew_submit_code($0) }
        phase = .working("Checking the code", 0.5)
    }

    func cancel() {
        _ = cloak_renew_cancel()
        poll?.cancel()
        phase = .idle
    }

    private func startPolling() {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                var scratch = [CChar](repeating: 0, count: 4096)
                let code = cloak_renew_state(&scratch, scratch.count)
                if code == 0, let json = String(validatingUTF8: scratch)?.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] {
                    self.apply(object)
                    if case .done = self.phase { return }
                    if case .failed = self.phase { return }
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func apply(_ object: [String: Any]) {
        let state = object["state"] as? String ?? ""
        switch state {
        case "working":
            let label = object["phase"] as? String ?? "Working"
            let progress = object["progress"] as? Double ?? 0
            phase = .working(label, progress)
        case "needs-code":
            phase = .needsCode(sms: object["sms"] as? Bool ?? false)
        case "done":
            phase = .done
            refreshSignature()
        case "failed":
            phase = .failed(object["reason"] as? String ?? "The refresh did not finish.")
        default:
            break
        }
    }
    #else
    func renew(password: String?, pairing: PairingRecord?) { phase = .failed("Refreshing is not available in this build.") }
    func submitCode(_ code: String) {}
    func cancel() {}
    #endif
}
