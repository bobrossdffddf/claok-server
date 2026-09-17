import Foundation
import SwiftData
import UserNotifications
import CloakKit

/// Starts scheduled runs.
///
/// While Cloak is alive — foreground, or in the background with location
/// updates running — this checks every twenty seconds and starts anything
/// that has come due. iOS will not wake a sideloaded app from nothing, so
/// every schedule also gets a notification a minute beforehand: if Cloak did
/// get shut down, the run is still one tap away rather than silently missed.
@MainActor
@Observable
final class RunScheduler {
    private(set) var nextUp: (name: String, at: Date)?

    /// What the running routine thinks the phone should be doing right now.
    private(set) var routineNow: String?
    private(set) var routineNext: (name: String, at: Date)?
    private var activeSegment: String?

    private var container: ModelContainer?
    private weak var model: AppModel?
    private var ticker: Task<Void, Never>?

    func attach(container: ModelContainer, model: AppModel) {
        self.container = container
        self.model = model
        // Not here. Asking for notifications the moment the app opens, before
        // anyone has scheduled anything, is the permission prompt Apple's
        // guidelines say not to show. It is asked the first time a run is
        // actually scheduled, which is when a notification would mean something.
        rebuildNotifications()
        // A trip lives in memory and nowhere else, so nothing that was in the
        // air when Cloak was last killed is in the air now. Any switch
        // reminder still pending at launch belongs to a flight that is not
        // happening, and left alone it would go off telling somebody to move
        // a VPN exit for it.
        if !JourneyController.shared.isRunning {
            Self.disarmTripCues()
        }
        start()
    }

    func start() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
    }

    /// Call after anything changes a schedule.
    func refresh() {
        rebuildNotifications()
        Task { await tick() }
    }

    // MARK: - The tick

    private func tick() async {
        if TrialController.shared.isActive { return }
        guard let container, let model else { return }
        let context = ModelContext(container)

        let runs = (try? context.fetch(FetchDescriptor<ScheduledRun>())) ?? []
        nextUp = runs
            .compactMap { run in run.nextFire().map { (run.name, $0) } }
            .min { $0.1 < $1.1 }

        await followRoutine(in: context, model: model)

        guard let due = runs.first(where: { $0.isDue() }) else { return }

        due.lastFiredAt = .now
        if !due.repeats { due.isEnabled = false }
        try? context.save()

        await start(due, in: context, model: model)
    }

    private func start(_ run: ScheduledRun, in context: ModelContext, model: AppModel) async {
        switch run.kind {
        case .place:
            await model.teleport(to: run.coordinate, label: run.name)

        case .route:
            guard let id = run.targetID,
                  let route = (try? context.fetch(FetchDescriptor<SavedRoute>()))?.first(where: { $0.id == id }) else {
                model.banner = "\(run.name) could not start: that route is gone."
                return
            }
            await model.run(route)

        case .trip:
            guard let id = run.targetID,
                  let trip = (try? context.fetch(FetchDescriptor<RecordedTrip>()))?.first(where: { $0.id == id }) else {
                model.banner = "\(run.name) could not start: that recording is gone."
                return
            }
            await model.replay(trip)
        }

        if run.durationMinutes > 0 {
            model.autoStopMinutes = run.durationMinutes
        }

        model.banner = "Started \(run.name) on schedule."
        rebuildNotifications()
    }

    // MARK: - Routines

    /// Keeps the phone where the routine says it should be.
    ///
    /// This is the part that makes a routine different from a schedule. A
    /// schedule fires once and hands over; a routine has an opinion about
    /// every minute of the day, so every tick asks what should be happening
    /// and corrects the phone if it is not already doing it.
    private func followRoutine(in context: ModelContext, model: AppModel) async {
        let routines = (try? context.fetch(FetchDescriptor<Routine>())) ?? []
        guard let routine = routines.first(where: { $0.isEnabled }) else {
            routineNow = nil
            routineNext = nil
            activeSegment = nil
            return
        }

        let plan = routine.plan()
        let now = Date.now

        guard let segment = plan.segment(at: now) else {
            routineNow = nil
            return
        }

        routineNow = segment.kind.name
        routineNext = plan.next(after: now).map { ($0.kind.name, $0.start) }

        // Only act on a change. Restarting the same drive every twenty seconds
        // would leave the phone stuck at the first corner forever.
        guard activeSegment != segment.id else { return }

        // If the user has taken manual control, the routine stays out of the
        // way rather than yanking the position back.
        if model.snapshot.isRunning, model.manualOverride { return }

        activeSegment = segment.id
        routine.lastRunDay = now
        try? context.save()

        switch segment.kind {
        case .dwell(let coordinate, let name, let drift):
            await model.hold(at: coordinate, label: name, drift: drift)

        case .travel(let from, let to, let name, let mode):
            await model.travel(from: from, to: to, label: name, mode: mode)
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    /// One notification per upcoming run, a minute early, so a schedule still
    /// means something when Cloak is not running.
    private func rebuildNotifications() {
        guard let container else { return }
        let context = ModelContext(container)
        let runs = (try? context.fetch(FetchDescriptor<ScheduledRun>())) ?? []
        if runs.contains(where: { $0.isEnabled }) {
            Task { await requestNotificationPermission() }
        }

        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let ours = requests.map(\.identifier).filter { !$0.hasPrefix("renew.") && !$0.hasPrefix("cloak.") }
            center.removePendingNotificationRequests(withIdentifiers: ours)
        }

        for run in runs where run.isEnabled {
            let content = UNMutableNotificationContent()
            content.title = run.name
            content.body = "Cloak is about to start this. Open it if nothing happens."
            content.sound = .default

            var parts = DateComponents()
            parts.hour = run.hour
            parts.minute = run.minute

            let trigger: UNNotificationTrigger
            if run.repeats {
                // A calendar trigger only repeats on one weekday at a time, so
                // a run on three days needs three requests.
                for weekday in 0..<7 where run.weekdays & (1 << weekday) != 0 {
                    var weekly = parts
                    weekly.weekday = weekday + 1
                    let request = UNNotificationRequest(
                        identifier: "\(run.id.uuidString)-\(weekday)",
                        content: content,
                        trigger: UNCalendarNotificationTrigger(dateMatching: weekly, repeats: true)
                    )
                    center.add(request)
                }
                continue
            } else {
                guard let next = run.nextFire() else { continue }
                let fields = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: next)
                trigger = UNCalendarNotificationTrigger(dateMatching: fields, repeats: false)
            }

            center.add(UNNotificationRequest(
                identifier: run.id.uuidString, content: content, trigger: trigger))
        }
    }

    // MARK: - Trip cues

    /// Reminders for the moments in a journey when a change to the device is
    /// invisible: the VPN exit and the phone's time zone, both switched while
    /// the phone is in the air and reporting nothing.
    ///
    /// These live here rather than in a second notification system of their
    /// own, because there is already exactly one place in the app that owns
    /// the notification centre and it is this one. Every identifier begins
    /// `cloak.journey.`, which is what keeps `rebuildNotifications` above from
    /// sweeping them away the next time a schedule changes: it only clears
    /// requests that are neither `renew.` nor `cloak.`.
    nonisolated static let journeyCuePrefix = "cloak.journey."
    private nonisolated static let remindsKey = "cloak.journey.reminds"

    /// Whether the user has asked to be told. Off until they say otherwise;
    /// nothing is ever scheduled, and no permission is ever asked for, until
    /// this is turned on.
    nonisolated static var remindsAboutTrips: Bool {
        get { UserDefaults.standard.bool(forKey: remindsKey) }
        set { UserDefaults.standard.set(newValue, forKey: remindsKey) }
    }

    /// Asks for notifications at the moment somebody opts in, and says whether
    /// it worked.
    ///
    /// A refusal is an answer, not a failure: the caller turns the switch back
    /// off and the trip runs exactly as it would have. Somebody who said no
    /// once is not asked again by iOS, so `denied` is reported straight back
    /// rather than sent into a prompt that will never appear.
    static func askAboutTripCues() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        default:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }

    /// Replaces whatever trip reminders were pending with these.
    ///
    /// Called again when the flight actually begins, because a drive to the
    /// airport that ran long moves every moment after it and a reminder that
    /// fires while the phone is still on the motorway is worse than none.
    nonisolated static func armTripCues(_ cues: [Journey.Cue]) {
        // Clearing and re-adding have to happen in that order, and both are
        // asynchronous, so they share one task. Two separate ones would race
        // and the clear could take the new reminders out with the old.
        Task.detached {
            let center = UNUserNotificationCenter.current()
            await clearTripCues(on: center)
            for cue in cues {
                let wait = cue.at.timeIntervalSinceNow
                // Anything already due is a moment that has passed. Firing it
                // now would tell somebody to switch their VPN at the wrong end
                // of the silence, which is the thing this exists to avoid.
                guard wait > 5 else { continue }
                let content = UNMutableNotificationContent()
                content.title = cue.title
                content.body = cue.body
                content.sound = .default
                content.threadIdentifier = "cloak.journey"
                try? await center.add(UNNotificationRequest(
                    identifier: journeyCuePrefix + cue.id,
                    content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false)
                ))
            }
        }
    }

    /// Clears them. Stopping a trip has to stop its reminders, or the phone
    /// tells you to change your VPN for a flight that is no longer happening.
    nonisolated static func disarmTripCues() {
        Task.detached { await clearTripCues(on: UNUserNotificationCenter.current()) }
    }

    private nonisolated static func clearTripCues(on center: UNUserNotificationCenter) async {
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(journeyCuePrefix) }
        guard !ours.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ours)
    }
}
