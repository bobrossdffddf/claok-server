import AppIntents
import SwiftUI
import CloakKit

/// Everything a Live Activity button or a Shortcut can do.
///
/// These conform to `LiveActivityIntent` where they are meant to be tapped
/// from the lock screen, which is what makes iOS run them inside Cloak's own
/// process rather than the widget's — the difference between a button that
/// actually stops the simulation and one that quietly does nothing.
struct TeleportIntent: AppIntent {
    static let title: LocalizedStringResource = "Set location"
    static let description = IntentDescription("Move the location this device reports to every app.")
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Latitude")
    var latitude: Double

    @Parameter(title: "Longitude")
    var longitude: Double

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let coordinate = Coordinate(latitude: latitude, longitude: longitude)
        guard coordinate.isValid else {
            return .result(dialog: "Those coordinates are out of range.")
        }
        if let problem = await LiveControl.start(.fixed(coordinate, label: "Shortcut")) {
            return .result(dialog: .init(stringLiteral: problem))
        }
        return .result(dialog: "Now appearing at \(String(format: "%.4f", latitude)), \(String(format: "%.4f", longitude)).")
    }
}

struct SetPlaybackRateIntent: AppIntent {
    static let title: LocalizedStringResource = "Set playback speed"
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Speed", default: 1.0, inclusiveRange: (0.25, 8.0))
    var rate: Double

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = await LiveControl.setRate(rate)
        return .result()
    }
}

struct CloakShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TeleportIntent(),
            phrases: ["Set my location in \(.applicationName)"],
            shortTitle: "Set location",
            systemImageName: "location.fill"
        )
        AppShortcut(
            intent: StopSimulationIntent(),
            phrases: ["Stop \(.applicationName)"],
            shortTitle: "Stop",
            systemImageName: "stop.fill"
        )
        AppShortcut(
            intent: PanicRestoreIntent(),
            phrases: ["Panic restore in \(.applicationName)"],
            shortTitle: "Panic restore",
            systemImageName: "exclamationmark.octagon.fill"
        )
    }
}
