import Foundation
import Observation
import os
import UIKit
import UserNotifications
import BackgroundTasks
import CloakKit
#if canImport(CloakBridge)
import CloakBridge
#endif

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

    enum Trigger {
        case manual
        case automatic
    }

    static let shared = RenewController()
    static let taskIdentifier = "app.cloak.renew"

    var phase: Phase = .idle
    var signature: SignatureInfo?
    var appleID: String = ""
    var hasStoredPassword: Bool = false
    var autoRenew: Bool = false
    var lastAttempt: Date?
    /// Apple refused the password Cloak had saved, so it was discarded.
    /// Remembered so the next refresh can say that, instead of behaving as
    /// though the user had never signed in.
    var passwordRejected: Bool = false

    var ensureLink: (@MainActor () async -> String?)?

    private var poll: Task<Void, Never>?
    private var trigger: Trigger = .manual
    private var installAnnounced = false
    private let log = Logger(subsystem: "app.cloak.ios", category: "renew")

    private static let idKey = "renewAppleID"
    private static let passwordKey = "renewPassword"
    private static let autoKey = "renewAutomatically"
    private static let pendingKey = "renewPending"
    private static let attemptKey = "renewLastAttempt"
    private static let rejectedKey = "renewPasswordRejected"
    private static let successID = "renew.success"
    private static let failureID = "renew.failure"
    private static let codeID = "renew.code"
    private static let reminderID = "renew.reminder"

    init() {
        signature = SignatureInfo.fromBundle()
        appleID = SecureDefaults.string(forKey: Self.idKey) ?? ""
        hasStoredPassword = SecureDefaults.string(forKey: Self.passwordKey) != nil
        autoRenew = AppGroup.defaults.bool(forKey: Self.autoKey)
        lastAttempt = AppGroup.defaults.object(forKey: Self.attemptKey) as? Date
        passwordRejected = AppGroup.defaults.bool(forKey: Self.rejectedKey)
    }

    private func markRejected() {
        passwordRejected = true
        AppGroup.defaults.set(true, forKey: Self.rejectedKey)
    }

    private func clearRejection() {
        guard passwordRejected else { return }
        passwordRejected = false
        AppGroup.defaults.removeObject(forKey: Self.rejectedKey)
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
        if on {
            Task { await Self.requestNotifications() }
            scheduleBackgroundRefresh()
        } else {
            SecureDefaults.remove(forKey: Self.passwordKey)
            hasStoredPassword = false
        }
        scheduleExpiryReminder()
    }

    func signIn(password: String) {
        SecureDefaults.set(appleID, forKey: Self.idKey)
        if !password.isEmpty { clearRejection() }
        if autoRenew, !password.isEmpty {
            SecureDefaults.set(password, forKey: Self.passwordKey)
            hasStoredPassword = true
        }
    }

    func signOut() {
        clearRejection()
        SecureDefaults.remove(forKey: Self.idKey)
        SecureDefaults.remove(forKey: Self.passwordKey)
        appleID = ""
        hasStoredPassword = false
    }

    static func requestNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func notify(id: String, title: String, body: String, after seconds: TimeInterval? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "renew"
        let trigger = seconds.map { UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0), repeats: false) }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    static func cancel(_ ids: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    func scheduleExpiryReminder() {
        Self.cancel([Self.reminderID])
        guard let signature, !signature.hasExpired else { return }
        let fire = signature.expires.addingTimeInterval(-24 * 3600).timeIntervalSinceNow
        guard fire > 60 else { return }
        Self.notify(
            id: Self.reminderID,
            title: "Cloak needs a refresh within a day",
            body: autoRenew ? "Open Cloak with LocalDevVPN on and it refreshes itself." : "Open Cloak and tap Refresh now so it keeps working.",
            after: fire
        )
    }

    func scheduleBackgroundRefresh() {
        guard autoRenew else { return }
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        let target = (signature?.expires ?? .now.addingTimeInterval(5 * 86_400)).addingTimeInterval(-2 * 86_400)
        request.earliestBeginDate = max(target, .now.addingTimeInterval(15 * 60))
        try? BGTaskScheduler.shared.submit(request)
    }

    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            Task { @MainActor in
                let controller = RenewController.shared
                controller.scheduleBackgroundRefresh()
                task.expirationHandler = { Task { @MainActor in controller.poll?.cancel() } }
                let started = controller.renewIfDue()
                if !started {
                    task.setTaskCompleted(success: true)
                    return
                }
                while controller.isBusy {
                    try? await Task.sleep(for: .seconds(1))
                }
                task.setTaskCompleted(success: controller.phase == .done)
            }
        }
    }

    var isDue: Bool {
        guard let signature else { return false }
        return signature.secondsLeft < 2.5 * 86_400
    }

    @discardableResult
    func renewIfDue(pairing: PairingRecord? = nil) -> Bool {
        guard autoRenew, hasStoredPassword, !appleID.isEmpty, isDue, !isBusy else { return false }
        if let lastAttempt, Date.now.timeIntervalSince(lastAttempt) < 3 * 3600 { return false }
        renew(password: nil, pairing: pairing ?? (try? PairingStore().load()), trigger: .automatic)
        return true
    }

    func checkPendingOutcome() {
        refreshSignature()
        scheduleExpiryReminder()
        guard let pending = AppGroup.defaults.dictionary(forKey: Self.pendingKey),
              let previous = pending["previous"] as? Double,
              let started = pending["started"] as? Double else { return }
        let current = signature?.expires.timeIntervalSince1970 ?? 0
        if current > previous + 3600 {
            AppGroup.defaults.removeObject(forKey: Self.pendingKey)
            Self.cancel([Self.failureID])
            let successID = Self.successID
            UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
                let already = delivered.contains { $0.request.identifier == successID }
                Task { @MainActor in
                    Self.cancel([Self.successID])
                    if !already, let signature = self.signature {
                        Self.notify(id: Self.successID, title: "Cloak refreshed", body: "Good until \(signature.expires.formatted(date: .abbreviated, time: .shortened)).")
                    }
                    self.phase = .done
                }
            }
        } else if Date.now.timeIntervalSince1970 - started > 180 {
            AppGroup.defaults.removeObject(forKey: Self.pendingKey)
            Self.cancel([Self.successID])
            Self.notify(id: Self.failureID, title: "Cloak refresh did not finish", body: "The new copy never installed. Open Cloak, make sure LocalDevVPN is on, and tap Refresh now.")
            phase = .failed("The last refresh signed Cloak but the install did not complete. Try again with LocalDevVPN on.")
        }
    }

    #if canImport(CloakBridge)
    func renew(password: String?, pairing: PairingRecord?, trigger: Trigger = .manual) {
        guard !isBusy else { return }
        self.trigger = trigger
        installAnnounced = false
        let pass = password?.isEmpty == false ? password! : (SecureDefaults.string(forKey: Self.passwordKey) ?? "")
        guard !appleID.isEmpty else {
            fail("Sign in with your Apple ID first.")
            return
        }
        guard !pass.isEmpty else {
            // Saying "sign in first" here reads as a new fault, when what
            // actually happened is that Apple refused the saved password and
            // Cloak discarded it rather than replay a refused one.
            fail(passwordRejected
                 ? "Apple would not accept the password Cloak had saved, so it was forgotten. Enter your Apple ID password again to refresh."
                 : "Enter your Apple ID password to refresh.")
            return
        }
        lastAttempt = .now
        AppGroup.defaults.set(Date.now, forKey: Self.attemptKey)
        Task { await Self.requestNotifications() }

        let record = pairing.flatMap { $0.plist.isEmpty || $0.udid.isEmpty ? nil : $0 }
        let udid = record?.udid ?? RemotePairingBackend.storedUdid ?? ""
        guard !udid.isEmpty else {
            fail("Cloak has not learned this phone's identity yet. Open Cloak with LocalDevVPN on so it links once, then try again.")
            return
        }
        signIn(password: password ?? "")

        phase = .working("Linking to this iPhone", 0.01)
        Task { @MainActor in
            if let ensureLink, let problem = await ensureLink(), record == nil {
                fail("Cloak could not link to this iPhone to install the refreshed copy: \(problem)")
                return
            }
            start(pass: pass, record: record, udid: udid)
        }
    }

    private func start(pass: String, record: PairingRecord?, udid: String) {
        guard let container = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            fail("Could not find a place to work in.")
            return
        }
        let work = caches.appendingPathComponent("renew", isDirectory: true)
        let app = work.appendingPathComponent("Cloak.app", isDirectory: true)
        do {
            try? FileManager.default.removeItem(at: work)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: Bundle.main.bundleURL, to: app)
        } catch {
            fail("Could not make a working copy of Cloak: \(error.localizedDescription)")
            return
        }
        let stateDir = container.appendingPathComponent("renew-state")
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        let handoff = Bundle.main.url(forResource: "cloak-signing", withExtension: "json")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let name = LockdownPairing.hostName
        phase = .working("Starting", 0.02)

        let plist = record?.plist ?? Data()
        let started = plist.withUnsafeBytes { buffer -> Bool in
            let base = buffer.bindMemory(to: UInt8.self).baseAddress
            return appleID.withCString { id in
                pass.withCString { pw in
                    app.path.withCString { appPath in
                        stateDir.path.withCString { state in
                            LocalAddresses.reflector.withCString { addr in
                                name.withCString { nm in
                                    udid.withCString { ud in
                                        handoff.withCString { hand in
                                            cloak_renew_start(id, pw, appPath, state, base, buffer.count, addr, nm, ud, handoff.isEmpty ? nil : hand) == 0
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        guard started else {
            fail("A refresh is already running.")
            return
        }
        startPolling()
    }

    func submitCode(_ code: String) {
        _ = code.withCString { cloak_renew_submit_code($0) }
        Self.cancel([Self.codeID])
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
                if cloak_renew_state(&scratch, scratch.count) == 0,
                   let json = String(validatingUTF8: scratch)?.data(using: .utf8),
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
            if object["installing"] as? Bool == true, !installAnnounced {
                installAnnounced = true
                announceInstall(expires: object["expires"] as? Double)
            }
        case "needs-code":
            let sms = object["sms"] as? Bool ?? false
            if phase != .needsCode(sms: sms) {
                Self.notify(id: Self.codeID, title: "Apple wants a code to refresh Cloak", body: sms ? "Apple texted you a code. Open Cloak to enter it." : "Check your other Apple devices for a code, then open Cloak to enter it.")
            }
            phase = .needsCode(sms: sms)
        case "done":
            Self.cancel([Self.successID, Self.codeID])
            AppGroup.defaults.removeObject(forKey: Self.pendingKey)
            let expires = (object["expires"] as? Double).map { Date(timeIntervalSince1970: $0) }
            Self.notify(id: Self.successID, title: "Cloak refreshed", body: expires.map { "Good until \($0.formatted(date: .abbreviated, time: .shortened))." } ?? "Good for another seven days.")
            phase = .done
            clearRejection()
            refreshSignature()
        case "failed":
            let reason = object["reason"] as? String ?? "The refresh did not finish."
            // Apple rejected the credentials. Do not keep a saved password Apple
            // refused: automatic renewal would replay it every few hours, and a
            // run of wrong-password attempts is how an Apple ID gets locked.
            if reason.contains("password was not accepted") {
                SecureDefaults.remove(forKey: Self.passwordKey)
                hasStoredPassword = false
                markRejected()
            }
            fail(reason)
        default:
            break
        }
    }

    private func announceInstall(expires: Double?) {
        let previous = signature?.expires.timeIntervalSince1970 ?? 0
        AppGroup.defaults.set(["previous": previous, "started": Date.now.timeIntervalSince1970], forKey: Self.pendingKey)
        let until = expires.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) }
        Self.notify(
            id: Self.successID,
            title: "Cloak refreshed",
            body: until.map { "Good until \($0). Tap to open it again." } ?? "Good for another seven days. Tap to open it again.",
            after: 45
        )
    }
    #else
    func renew(password: String?, pairing: PairingRecord?, trigger: Trigger = .manual) { fail("Refreshing is not available in this build.") }
    func submitCode(_ code: String) {}
    func cancel() {}
    #endif

    private func fail(_ message: String) {
        Self.cancel([Self.successID, Self.codeID])
        AppGroup.defaults.removeObject(forKey: Self.pendingKey)
        phase = .failed(message)
        log.error("renew failed: \(message, privacy: .public)")
        if trigger == .automatic || UIApplication.shared.applicationState != .active {
            Self.notify(id: Self.failureID, title: "Cloak could not refresh itself", body: message)
        }
    }
}
