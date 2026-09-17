import Foundation
import Observation
import os
import UserNotifications
import CloakKit

@MainActor
@Observable
final class TrialController {
    static let shared = TrialController()
    static let allowance: TimeInterval = 10 * 60

    private(set) var remaining: TimeInterval = allowance
    private(set) var resetsAt: Date?
    private(set) var running = false
    private(set) var token: LicenseToken?
    var problem: String?
    var showsPaywall = false
    var paywallReason: String?

    var onExpired: (@MainActor () async -> Void)?

    private var runningSince: Date?
    private var remainingAtStart: TimeInterval = allowance
    private var ticker: Task<Void, Never>?
    private let log = Logger(subsystem: "app.cloak.ios", category: "trial")

    private static let chosenKey = "trialChosen"
    private static let tokenKey = "trialToken"

    var isChosen: Bool {
        get { AppGroup.defaults.bool(forKey: Self.chosenKey) }
        set { AppGroup.defaults.set(newValue, forKey: Self.chosenKey) }
    }

    var isActive: Bool { !Licensing.verifiedNow && isChosen }

    var liveRemaining: TimeInterval {
        guard running, let runningSince else { return remaining }
        return max(0, remainingAtStart - Date.now.timeIntervalSince(runningSince))
    }

    var isUsedUp: Bool { liveRemaining <= 0 }

    init() {
        if let raw = AppGroup.defaults.string(forKey: Self.tokenKey), let parsed = LicenseToken.parse(raw), !parsed.isExpired {
            token = parsed
        }
    }

    static func lockedReason(for feature: String) -> String {
        "\(feature) is part of the full version. The free 10 minutes a day covers changing your location."
    }

    func requirePaid(_ feature: String) -> Bool {
        guard isActive else { return false }
        paywallReason = Self.lockedReason(for: feature)
        showsPaywall = true
        return true
    }

    private struct Answer: Decodable {
        var token: String
        var remaining: Double
        var running: Bool
        var resets_at: Double
    }

    private func call(_ path: String) async throws -> Answer {
        var request = URLRequest(url: Licensing.serverBase.appendingPathComponent("v1/trial/\(path)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 12
        let offset = TimeZone.current.secondsFromGMT() / 60
        request.httpBody = try JSONSerialization.data(withJSONObject: ["device_id": DeviceIdentity.id, "tz_minutes": offset])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw LicenseError.refused(object?["error"] as? String ?? "The free trial is not available right now (\(status)).")
        }
        return try JSONDecoder().decode(Answer.self, from: data)
    }

    private func absorb(_ answer: Answer) {
        remaining = max(0, answer.remaining)
        resetsAt = Date(timeIntervalSince1970: answer.resets_at)
        if let parsed = LicenseToken.parse(answer.token) {
            token = parsed
            AppGroup.defaults.set(answer.token, forKey: Self.tokenKey)
        }
    }

    func refresh() async {
        guard isChosen else { return }
        do {
            absorb(try await call("status"))
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    func begin() async -> Bool {
        guard isActive else { return true }
        if running { return liveRemaining > 0 }
        do {
            let answer = try await call("start")
            absorb(answer)
        } catch {
            problem = error.localizedDescription
            paywallReason = error.localizedDescription
            showsPaywall = true
            TrialGate.closesAt = nil
            return false
        }
        guard remaining > 0 else {
            paywallReason = "Today's 30 free minutes are used up."
            showsPaywall = true
            return false
        }
        running = true
        runningSince = .now
        remainingAtStart = remaining
        TrialGate.closesAt = Date.now.addingTimeInterval(remaining)
        scheduleWarning()
        startTicker()
        return true
    }

    func end() async {
        guard running else { return }
        running = false
        ticker?.cancel()
        ticker = nil
        TrialGate.closesAt = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["cloak.trial.warning", "cloak.trial.over"])
        remaining = liveRemaining
        runningSince = nil
        if let answer = try? await call("stop") {
            absorb(answer)
        }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            var seconds = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                seconds += 1
                if self.liveRemaining <= 0 {
                    await self.expire()
                    return
                }
                if seconds % 45 == 0, let answer = try? await self.call("tick") {
                    self.absorb(answer)
                    self.runningSince = .now
                    self.remainingAtStart = self.remaining
                    TrialGate.closesAt = Date.now.addingTimeInterval(self.remaining)
                    if self.remaining <= 0 {
                        await self.expire()
                        return
                    }
                }
            }
        }
    }

    private func expire() async {
        log.notice("trial time used up")
        running = false
        TrialGate.closesAt = nil
        remaining = 0
        runningSince = nil
        await onExpired?()
        _ = try? await call("stop")
        paywallReason = "That was today's 30 free minutes. Your real location is back. They reset at midnight."
        showsPaywall = true
        let content = UNMutableNotificationContent()
        content.title = "Free minutes used up"
        content.body = "Cloak switched you back to your real location. Get a licence for unlimited use, or come back tomorrow."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "cloak.trial.over", content: content, trigger: nil), withCompletionHandler: nil)
    }

    private func scheduleWarning() {
        let lead = liveRemaining - 5 * 60
        guard lead > 30 else { return }
        let content = UNMutableNotificationContent()
        content.title = "5 free minutes left today"
        content.body = "Cloak goes back to your real location when they run out."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: lead, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "cloak.trial.warning", content: content, trigger: trigger), withCompletionHandler: nil)
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
