import Foundation
import CloakKit

actor SimulationEngine {
    private let link: DeviceLink
    private var ticker: Task<Void, Never>?
    private var engine: MotionEngine?
    private var jitter: IdleJitter?
    private var joystick: JoystickState?
    private var snapshot = SimulationSnapshot.stopped
    private var payload: TunnelStartPayload?
    private var paused = false

    struct JoystickState {
        var position: Coordinate
        var bearing: Double
        var speed: Double
        var throttle: Double
    }

    init() {
        self.link = DeviceLink(backend: PreferredDeviceBackend())
    }

    var current: SimulationSnapshot { snapshot }

    func handle(_ command: TunnelCommand) async -> TunnelReply {
        switch command {
        case .start(let payload):
            return await start(payload)
        case .stop, .panic:
            await stop()
            return .acknowledged
        case .snapshot:
            return .snapshot(snapshot)

        case .status:
            snapshot.linkMessage = nil
            persist()
            let message = await probe()
            snapshot.linkMessage = message
            persist()
            if let message { return .failed(message) }
            return .snapshot(snapshot)
        case .setPlaybackRate(let rate):
            guard let payload else { return .failed("Nothing is running") }
            var updated = payload
            updated.playbackRate = rate
            return await start(updated)
        case .peekBegin:
            paused = true
            snapshot.isPaused = true
            persist()
            // Pausing alone leaves the last fake fix in place, so the peek
            // would read back our own simulation. Clear it at the source.
            await link.clear()
            return .acknowledged

        case .peekEnd:
            paused = false
            snapshot.isPaused = false
            persist()
            return .acknowledged

        case .pause:
            paused = true
            snapshot.isPaused = true
            persist()
            return .acknowledged
        case .resume:
            paused = false
            snapshot.isPaused = false
            persist()
            return .acknowledged
        case .steer(let bearing, let throttle):
            return await steer(bearing: bearing, throttle: throttle)
        case .releaseSteering:
            joystick?.throttle = 0
            return .acknowledged
        }
    }

    func probe() async -> String? {
        await link.tearDown()
        await link.markDeveloperMode(enabled: true)
        let ready = await link.bringUp()
        if ready { return nil }
        return await link.state.lastError ?? "The link is not up."
    }

    private func ensureLink() async -> String? {
        if await link.state.isReady { return nil }
        return await probe()
    }

    private func steer(bearing: Double, throttle: Double) async -> TunnelReply {
        if let message = await ensureLink() {
            snapshot.linkMessage = message
            persist()
            return .failed(message)
        }

        let anchor = joystick?.position ?? snapshot.fix?.coordinate ?? payload?.points.first
        guard let anchor else { return .failed("Set a location before steering") }

        if joystick == nil {
            engine = nil
            jitter = nil
            paused = false
            joystick = JoystickState(position: anchor, bearing: bearing, speed: 0, throttle: throttle)
            snapshot = SimulationSnapshot(
                isRunning: true,
                mode: .joystick,
                fix: SimulatedFix(coordinate: anchor),
                startedAt: .now,
                reconnectCount: snapshot.reconnectCount
            )
            persist()
            startTicker()
        } else {
            joystick?.bearing = bearing
            joystick?.throttle = throttle
        }
        return .acknowledged
    }

    private func start(_ payload: TunnelStartPayload) async -> TunnelReply {
        ticker?.cancel()
        ticker = nil
        joystick = nil
        paused = false
        self.payload = payload

        if let message = await ensureLink() {
            snapshot.linkMessage = message
            persist()
            return .failed(message)
        }
        snapshot.linkMessage = nil

        let persona = DriverPersona.all.first { $0.id == payload.personaID } ?? .normal

        if payload.points.count < 2 {
            guard let anchor = payload.points.first else { return .failed("No location") }
            engine = nil
            jitter = IdleJitter(anchor: anchor, radius: max(3, payload.dwellRadius), seed: payload.seed)
            snapshot = SimulationSnapshot(
                isRunning: true,
                mode: .fixed(anchor),
                fix: SimulatedFix(coordinate: anchor),
                progress: 1,
                startedAt: .now,
                reconnectCount: snapshot.reconnectCount
            )
        } else {
            let polyline = Polyline(points: payload.points).densified(spacing: 5)
            let limits = payload.postedLimits.count == polyline.points.count
                ? payload.postedLimits
                : Array(repeating: RoadClass.residential.defaultLimit, count: polyline.points.count)
            let profile = SpeedProfileBuilder.build(
                polyline: polyline,
                postedLimits: limits,
                controls: payload.controls,
                persona: persona,
                mode: payload.mode,
                seed: payload.seed
            )
            engine = MotionEngine(
                profile: profile,
                persona: persona,
                mode: payload.mode,
                playbackRate: payload.playbackRate,
                seed: payload.seed
            )
            jitter = nil
            snapshot = SimulationSnapshot(
                isRunning: true,
                mode: .route(name: payload.label, mode: payload.mode),
                progress: 0,
                distanceRemaining: profile.polyline.length,
                startedAt: .now,
                reconnectCount: snapshot.reconnectCount
            )
        }

        persist()
        startTicker()
        return .acknowledged
    }

    private func startTicker() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func tick() async {
        if paused {
            persist()
            return
        }

        var fix: SimulatedFix?

        if var joystick {
            let target = joystick.throttle * Speed.mph(35)
            let accel = 2.5
            if joystick.speed < target {
                joystick.speed = min(target, joystick.speed + accel)
            } else {
                joystick.speed = max(target, joystick.speed - accel * 1.4)
            }
            if joystick.speed > 0.05 {
                joystick.position = joystick.position.moved(bearing: joystick.bearing, distance: joystick.speed)
            }
            self.joystick = joystick
            fix = SimulatedFix(
                coordinate: joystick.position,
                speed: joystick.speed,
                course: joystick.speed > 0.3 ? joystick.bearing : -1,
                horizontalAccuracy: 5
            )
        } else if var engine {
            let produced = engine.step(deltaTime: 1)
            self.engine = engine
            fix = produced
            snapshot.progress = engine.progress
            snapshot.stopsMade = engine.state.stopsMade
            snapshot.remainingTime = engine.remainingTime
            snapshot.distanceRemaining = max(0, engine.profile.polyline.length - engine.state.distance)
            snapshot.speedLimit = engine.profile.speed(at: engine.state.distance)
            if let next = engine.profile.stops.first(where: { $0.alongTrack > engine.state.distance }) {
                snapshot.nextStopDistance = next.alongTrack - engine.state.distance
            } else {
                snapshot.nextStopDistance = nil
            }
            if engine.state.finished {
                if payload?.loop == true, let payload {
                    _ = await start(payload)
                    return
                }
                snapshot.isRunning = false
                ticker?.cancel()
                ticker = nil
            }
        } else if var jitter {
            fix = jitter.next()
            self.jitter = jitter
        }

        guard let fix else { return }
        snapshot.fix = fix
        await link.push(fix)
        let state = await link.state
        snapshot.reconnectCount = state.reconnectCount
        snapshot.linkMessage = state.isReady ? nil : state.lastError
        persist()
    }

    func stop() async {
        ticker?.cancel()
        ticker = nil
        engine = nil
        jitter = nil
        joystick = nil
        payload = nil
        paused = false
        await link.clear()
        let carried = snapshot.reconnectCount
        snapshot = SimulationSnapshot(reconnectCount: carried)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        AppGroup.defaults.set(data, forKey: "snapshot")
    }
}
