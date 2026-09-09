import Foundation

/// A way for App Intents to reach the running simulation.
///
/// Intents fired from a Live Activity button or from Shortcuts run inside the
/// app's own process, so the app registers handlers here at launch and the
/// intents call through. The same file is compiled into the widget extension,
/// where nothing registers — there, `isAvailable` is false and the intent says
/// so rather than pretending to work.
@MainActor
public enum LiveControl {
    public struct Handlers {
        public var start: (TunnelStartPayload) async -> String?
        public var stop: () async -> Void
        public var togglePause: () async -> Void
        public var panic: () async -> Void
        public var setRate: (Double) async -> Void
        public var snapshot: () -> SimulationSnapshot

        public init(
            start: @escaping (TunnelStartPayload) async -> String?,
            stop: @escaping () async -> Void,
            togglePause: @escaping () async -> Void,
            panic: @escaping () async -> Void,
            setRate: @escaping (Double) async -> Void,
            snapshot: @escaping () -> SimulationSnapshot
        ) {
            self.start = start
            self.stop = stop
            self.togglePause = togglePause
            self.panic = panic
            self.setRate = setRate
            self.snapshot = snapshot
        }
    }

    private static var handlers: Handlers?

    public static var isAvailable: Bool { handlers != nil }

    public static func register(_ handlers: Handlers) {
        self.handlers = handlers
    }

    public static let unavailable = "Cloak is not running, so there is nothing to control. Open it and try again."

    public static func start(_ payload: TunnelStartPayload) async -> String? {
        guard let handlers else { return unavailable }
        return await handlers.start(payload)
    }

    public static func stop() async -> String? {
        guard let handlers else { return unavailable }
        await handlers.stop()
        return nil
    }

    public static func togglePause() async -> String? {
        guard let handlers else { return unavailable }
        await handlers.togglePause()
        return nil
    }

    public static func panic() async -> String? {
        guard let handlers else { return unavailable }
        await handlers.panic()
        return nil
    }

    public static func setRate(_ rate: Double) async -> String? {
        guard let handlers else { return unavailable }
        await handlers.setRate(rate)
        return nil
    }

    public static var snapshot: SimulationSnapshot {
        handlers?.snapshot() ?? .stopped
    }
}
