import Foundation
import ActivityKit
import CloakKit

/// ActivityKit's content type is not Sendable, and its calls are async, so the
/// pair has to cross an isolation boundary together in a box.
private struct Unchecked<T>: @unchecked Sendable {
    let value: T
}

/// Starts, updates and ends the Live Activity for a running simulation.
@MainActor
final class DriveActivityController {
    private var activity: Activity<DriveActivityAttributes>?
    private var lastPush: Date = .distantPast

    var isSupported: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func sync(with snapshot: SimulationSnapshot) {
        guard isSupported else { return }

        guard snapshot.isRunning else {
            end()
            return
        }

        // One place builds the whole state, so `endsAt` comes from the
        // engine's own estimate and `updatedAt` is genuinely the moment these
        // numbers were true. Both matter: the activity's ETA and its staleness
        // are computed from them.
        let state = DriveActivityAttributes.ContentState(snapshot: snapshot)

        if let running = activity {
            // A Live Activity has a strict update budget, so this is throttled
            // rather than pushed on every one second tick.
            guard Date.now.timeIntervalSince(lastPush) > 2 else { return }
            lastPush = .now
            let box = Unchecked(value: (running, ActivityContent(state: state, staleDate: state.staleDate)))
            Task.detached {
                await box.value.0.update(box.value.1)
            }
            return
        }

        do {
            activity = try Activity.request(
                attributes: DriveActivityAttributes(),
                content: ActivityContent(state: state, staleDate: state.staleDate),
                pushType: nil
            )
            lastPush = .now
        } catch {
            activity = nil
        }
    }

    func end() {
        guard let current = activity else { return }
        activity = nil
        let box = Unchecked(value: current)
        Task.detached {
            await box.value.end(nil, dismissalPolicy: .immediate)
        }
    }
}
