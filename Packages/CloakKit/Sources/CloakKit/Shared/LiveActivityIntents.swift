import AppIntents

/// The buttons on the Live Activity.
///
/// These live in CloakKit rather than in the app or the widget because both
/// targets need them and each target that compiles a copy produces a separate
/// type with the same identifier. iOS then binds the widget's copy, which runs
/// inside the widget process where nothing is registered, and the button does
/// nothing at all. One type, in a package both link, is the fix.
///
/// `LiveActivityIntent` is what makes iOS run these inside Cloak's own process
/// instead of the widget's, which is the other half of the same problem.
public struct StopSimulationIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Stop simulating"
    public static let description = IntentDescription("Return to the real location.")
    public static var openAppWhenRun: Bool { false }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        if let problem = await LiveControl.stop() {
            return .result(dialog: .init(stringLiteral: problem))
        }
        return .result(dialog: "Back to your real location.")
    }
}

public struct TogglePauseIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Pause or resume"
    public static let description = IntentDescription("Hold the simulation where it is, or let it carry on.")
    public static var openAppWhenRun: Bool { false }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        _ = await LiveControl.togglePause()
        return .result()
    }
}

/// Also shared, because the widget offers it as a control and a widget-side
/// copy would run in the widget's process and do nothing.
public struct PanicRestoreIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Panic restore"
    public static let description = IntentDescription("Stop everything and go back to the real location.")
    public static var openAppWhenRun: Bool { false }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        if let problem = await LiveControl.panic() {
            return .result(dialog: .init(stringLiteral: problem))
        }
        return .result(dialog: "Simulation stopped.")
    }
}
