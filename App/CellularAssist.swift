import Foundation
import Observation
import os
import UIKit
import UserNotifications
import CloakKit

@MainActor
@Observable
final class CellularAssist {
    enum Strategy: String, CaseIterable, Identifiable, Codable {
        case direct
        case wifiRadio
        case dataFlip

        var id: String { rawValue }

        var title: String {
            switch self {
            case .direct: "Straight through"
            case .wifiRadio: "Wi-Fi radio on"
            case .dataFlip: "Cellular data flip"
            }
        }

        var detail: String {
            switch self {
            case .direct: "Link over the remembered port with nothing toggled."
            case .wifiRadio: "Turns the Wi-Fi radio on for a moment. It does not join anything."
            case .dataFlip: "Turns cellular data off for about two seconds while the link comes up, then back on."
            }
        }

        var input: String {
            switch self {
            case .direct: ""
            case .wifiRadio: "wifi"
            case .dataFlip: "dataoff"
            }
        }
    }

    struct Trial: Identifiable, Equatable {
        let id = UUID()
        var strategy: Strategy
        var worked: Bool
        var detail: String
        var at: Date
    }

    static let shared = CellularAssist()

    var enabled: Bool {
        didSet { AppGroup.defaults.set(enabled, forKey: Self.enabledKey) }
    }
    var shortcutName: String {
        didSet { AppGroup.defaults.set(shortcutName, forKey: Self.nameKey) }
    }
    var shortcutLink: String {
        didSet { AppGroup.defaults.set(shortcutLink, forKey: Self.linkKey) }
    }
    private(set) var learned: Strategy?

    /// Whether the relink shortcut has ever actually run.
    ///
    /// An app cannot create a Shortcut, and it cannot ask Shortcuts whether one
    /// exists either. Only iOS can toggle the radios and only a Shortcut can
    /// ask it to, so the one honest signal is whether ours has ever answered.
    var shortcutIsProven: Bool {
        didSet { AppGroup.defaults.set(shortcutIsProven, forKey: Self.provenKey) }
    }

    /// True when the phone has no Wi-Fi or wired address, so the pairing
    /// service has nothing to bind to and the relink shortcut is the only way
    /// back. This is the moment to be loud about setup.
    var needsShortcutNow: Bool {
        enabled && !shortcutIsProven && !RemotePairingDiscovery.hasLocalNetworkInterface
    }
    private(set) var trials: [Trial] = []
    private(set) var isTesting = false
    private(set) var lastRun: String?

    private var waiter: CheckedContinuation<Bool, Never>?
    private var lastNotified: Date?
    private var pendingRestore: Strategy?
    private var lastPrepared: Strategy?
    private let log = Logger(subsystem: "app.cloak.ios", category: "cellular")

    private static let enabledKey = "cellularAssistEnabled"
    private static let nameKey = "cellularShortcutName"
    private static let linkKey = "cellularShortcutLink"
    private static let learnedKey = "cellularLearnedStrategy"
    private static let provenKey = "cellularShortcutProven"

    init() {
        let defaults = AppGroup.defaults
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        shortcutName = defaults.string(forKey: Self.nameKey) ?? "Cloak Link"
        shortcutLink = defaults.string(forKey: Self.linkKey) ?? ""
        shortcutIsProven = defaults.bool(forKey: Self.provenKey)
        learned = defaults.string(forKey: Self.learnedKey).flatMap(Strategy.init(rawValue:))
    }

    func install() {
        CellularHook.prepare = { @Sendable in
            await CellularAssist.shared.prepareForLink()
        }
        CellularHook.finished = { @Sendable worked in
            await CellularAssist.shared.linkFinished(worked: worked)
        }
    }

    var onCellularOnly: Bool {
        !RemotePairingDiscovery.hasLocalNetworkInterface
    }

    func remember(_ strategy: Strategy) {
        learned = strategy
        AppGroup.defaults.set(strategy.rawValue, forKey: Self.learnedKey)
    }

    func forget() {
        learned = nil
        AppGroup.defaults.removeObject(forKey: Self.learnedKey)
    }

    func prepareForLink() async -> Bool {
        guard enabled else { return false }
        let strategy = learned ?? .wifiRadio
        guard strategy != .direct else { return false }
        guard UIApplication.shared.applicationState == .active else {
            notifyRelink()
            return false
        }
        let ran = await runShortcut(strategy.input)
        lastPrepared = ran ? strategy : nil
        if ran {
            pendingRestore = strategy == .dataFlip ? .dataFlip : nil
            try? await Task.sleep(for: .milliseconds(strategy == .wifiRadio ? 2500 : 1500))
        }
        lastRun = "\(strategy.title): \(ran ? "ran" : "did not run") at \(Date.now.formatted(date: .omitted, time: .standard))"
        log.notice("prepare \(strategy.rawValue, privacy: .public) ran=\(ran)")
        return ran
    }

    func linkFinished(worked: Bool) async {
        if pendingRestore == .dataFlip {
            pendingRestore = nil
            _ = await runShortcut("dataon")
        }
        if worked, let lastPrepared {
            remember(lastPrepared)
        }
        lastPrepared = nil
    }

    func runShortcut(_ input: String) async -> Bool {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: shortcutName),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: input),
            URLQueryItem(name: "x-success", value: "cloak://cellular/done"),
            URLQueryItem(name: "x-error", value: "cloak://cellular/error"),
            URLQueryItem(name: "x-cancel", value: "cloak://cellular/error")
        ]
        guard let url = components.url else { return false }
        waiter?.resume(returning: false)
        waiter = nil
        let opened = await UIApplication.shared.open(url)
        guard opened else { return false }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            waiter = continuation
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(25))
                if let pending = self.waiter {
                    self.waiter = nil
                    pending.resume(returning: false)
                }
            }
        }
        return result
    }

    func handleCallback(_ url: URL) {
        let worked = url.path.contains("done")
        if worked, !shortcutIsProven { shortcutIsProven = true }
        waiter?.resume(returning: worked)
        waiter = nil
    }

    func openShortcutLink() {
        if let url = URL(string: shortcutLink), !shortcutLink.isEmpty {
            UIApplication.shared.open(url)
        } else if let url = URL(string: "shortcuts://create-shortcut") {
            UIApplication.shared.open(url)
        }
    }

    private func notifyRelink() {
        if let lastNotified, Date.now.timeIntervalSince(lastNotified) < 600 { return }
        lastNotified = .now
        let content = UNMutableNotificationContent()
        content.title = "Cloak needs a tap to relink"
        content.body = "You are on cellular and the link dropped. Open Cloak and it reconnects by itself."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: "cloak.cellular.relink", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    func runLab(model: AppModel) async {
        guard !isTesting else { return }
        isTesting = true
        trials = []
        defer { isTesting = false }

        let savedEnabled = enabled
        enabled = false
        defer { enabled = savedEnabled }

        let interfaces = RemotePairingDiscovery.interfaceReport()
        log.notice("lab start interfaces: \(interfaces, privacy: .public)")

        for strategy in Strategy.allCases {
            await model.dropLinkForTest()
            if strategy != .direct {
                let ran = await runShortcut(strategy.input)
                if !ran {
                    trials.append(Trial(strategy: strategy, worked: false, detail: "The \"\(shortcutName)\" shortcut did not run. Build it first.", at: .now))
                    continue
                }
                try? await Task.sleep(for: .milliseconds(strategy == .wifiRadio ? 2500 : 1500))
            }
            let problem = await model.linkProblemForTest()
            if strategy == .dataFlip {
                _ = await runShortcut("dataon")
            }
            let worked = problem == nil
            trials.append(Trial(strategy: strategy, worked: worked, detail: problem ?? "Linked", at: .now))
            log.notice("lab \(strategy.rawValue, privacy: .public) worked=\(worked) detail=\(problem ?? "linked", privacy: .public)")
            if worked {
                remember(strategy)
                break
            }
        }
    }
}
