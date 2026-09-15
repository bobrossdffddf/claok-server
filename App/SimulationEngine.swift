import Foundation
import os
import CloakKit
#if canImport(UIKit)
import UIKit
#endif

actor SimulationEngine {
    private static let log = Logger(subsystem: "app.cloak.ios", category: "drive")
    private let link: DeviceLink
    private var ticker: Task<Void, Never>?
    private var engine: MotionEngine?
    private var jitter: IdleJitter?
    private var joystick: JoystickState?
    private var shield: ShieldEngine?
    private var shieldRoads: RoadMetadata?
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

    var isShielding: Bool { shield != nil }

    // MARK: - SHIELD

    /// Starts reporting the real drive at or near the limit. The first
    /// reported position is wherever the phone really is right now.
    func startShield(_ settings: ShieldSettings, from real: RealFix) async -> TunnelReply {
        if let message = await ensureLink() {
            snapshot.linkMessage = message
            persist()
            return .failed(message)
        }
        ticker?.cancel()
        ticker = nil
        engine = nil
        jitter = nil
        joystick = nil
        payload = nil
        paused = false
        var fresh = ShieldEngine(settings: settings)
        fresh.observe(real)
        shield = fresh
        snapshot = SimulationSnapshot(
            isRunning: true,
            mode: .shield(settings.mode),
            fix: SimulatedFix(coordinate: real.coordinate),
            startedAt: .now,
            reconnectCount: snapshot.reconnectCount
        )
        persist()
        startTicker()
        return .acknowledged
    }

    /// Every real fix while SHIELD runs.
    func observeReal(_ fix: RealFix) {
        shield?.observe(fix)
    }

    /// The roads around the drive, so the cap can follow the posted limits.
    func updateShieldRoads(_ metadata: RoadMetadata) {
        shieldRoads = metadata
    }

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
            shield = nil
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
        shield = nil
        paused = false
        self.payload = payload

        if let message = await ensureLink() {
            snapshot.linkMessage = message
            persist()
            return .failed(message)
        }
        snapshot.linkMessage = nil

        let persona = DriverPersona.named(payload.personaID)

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
                speedHelp: SpeedHelp.load(),
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
                mode: payload.shieldMode.map { SimulationMode.shield($0) } ?? .route(name: payload.label, mode: payload.mode),
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

    /// When the previous tick happened, so the engine advances by the time
    /// that actually passed. It used to advance by exactly one second per
    /// tick while the tick itself waited on the round trip to the phone, so a
    /// slow push stretched simulated time: the car crept, then jumped.
    private var lastTick: ContinuousClock.Instant?

    private func startTicker() {
        lastTick = nil
        ticker = Task { [weak self] in
            let clock = ContinuousClock()
            var deadline = clock.now
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                // Fixed cadence regardless of how long the push took. One fix a
                // second is what a real GPS delivers and what apps expect.
                deadline += .seconds(1)
                if deadline < clock.now { deadline = clock.now }
                try? await Task.sleep(until: deadline, clock: clock)
            }
        }
    }

    /// Seconds since the previous tick, bounded so a suspended app does not
    /// teleport the car when it wakes.
    private func elapsedSinceLastTick() -> Double {
        let now = ContinuousClock.now
        defer { lastTick = now }
        guard let lastTick else { return 1 }
        let seconds = Double((now - lastTick).components.seconds)
            + Double((now - lastTick).components.attoseconds) / 1e18
        return min(max(seconds, 0.25), 3)
    }

    /// Timestamps of recent ticks, gaps between them and how long each push
    /// took, so Diagnostics can say whether the drive is actually going out
    /// smoothly rather than everyone guessing.
    private var tickTimes: [(at: Date, gap: Double, push: Double)] = []

    private func recordTick(gap: Double, push: Double) async {
        let now = Date.now
        tickTimes.append((now, gap, push))
        tickTimes.removeAll { now.timeIntervalSince($0.at) > 60 }
        snapshot.fixesLastMinute = tickTimes.count
        snapshot.longestGapLastMinute = tickTimes.map(\.gap).max() ?? 0
        snapshot.slowestPushLastMinute = tickTimes.map(\.push).max() ?? 0
        if gap > 1.6 || push > 0.8 {
            let state = await Self.appStateName()
            Self.log.notice("uneven tick: \(gap, format: .fixed(precision: 2))s since last, push took \(push, format: .fixed(precision: 2))s, app \(state)")
        }
    }

    @MainActor
    private static func appStateName() -> String {
        #if canImport(UIKit)
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
        #else
        return "unknown"
        #endif
    }

    private func tick() async {
        if paused {
            lastTick = nil
            persist()
            return
        }

        var fix: SimulatedFix?
        let rawGap: Double = {
            guard let lastTick else { return 1 }
            let d = ContinuousClock.now - lastTick
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }()
        let dt = elapsedSinceLastTick()

        if var joystick {
            let target = joystick.throttle * Speed.mph(35)
            let accel = 2.5 * dt
            if joystick.speed < target {
                joystick.speed = min(target, joystick.speed + accel)
            } else {
                joystick.speed = max(target, joystick.speed - accel * 1.4)
            }
            if joystick.speed > 0.05 {
                joystick.position = joystick.position.moved(bearing: joystick.bearing, distance: joystick.speed * dt)
            }
            self.joystick = joystick
            fix = SimulatedFix(
                coordinate: joystick.position,
                speed: joystick.speed,
                course: joystick.speed > 0.3 ? joystick.bearing : -1,
                horizontalAccuracy: 5
            )
        } else if var shield {
            let roads = shieldRoads
            let heading = snapshot.fix?.course ?? 0
            let produced = shield.step(deltaTime: dt) { point in
                roads?.limit(at: point, heading: heading)
            }
            self.shield = shield
            fix = produced
            let here = produced?.coordinate ?? shield.trail.last
            snapshot.speedLimit = here.flatMap { roads?.limit(at: $0, heading: heading) } ?? shield.fallbackLimit
            snapshot.shieldHoldingBack = shield.holdingBack
            snapshot.shieldRealSpeed = shield.lastRealSpeed
        } else if var engine {
            let produced = engine.step(deltaTime: dt)
            self.engine = engine
            fix = produced
            snapshot.progress = engine.progress
            if engine.state.stopsMade != snapshot.stopsMade {
                Self.log.notice("stopped at \(Int(engine.state.distance))m (\(produced.coordinate.latitude),\(produced.coordinate.longitude)) for \(Int(engine.state.dwellRemaining))s, limit here \(Int(Speed.toMph(engine.profile.speed(at: engine.state.distance)))) mph")
            }
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
        let pushStarted = ContinuousClock.now
        await link.push(fix)
        let pushTook = ContinuousClock.now - pushStarted
        await recordTick(gap: rawGap, push: Double(pushTook.components.seconds) + Double(pushTook.components.attoseconds) / 1e18)
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
        shield = nil
        shieldRoads = nil
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
