import Foundation

public struct MotionEngineState: Sendable {
    public var distance: Double = 0
    public var speed: Double = 0
    public var acceleration: Double = 0
    public var dwellRemaining: TimeInterval = 0
    public var elapsed: TimeInterval = 0
    public var finished: Bool = false
    public var pendingStopIndex: Int = 0
    public var stopsMade: Int = 0
}

public struct MotionEngine: Sendable {
    public static let subStep: TimeInterval = 0.2
    public static let arrivalWindow: Double = 4
    public static let arrivalSpeed: Double = 1.5
    public static let creepSpeed: Double = 0.8
    public static let brakingMargin: Double = 0.7

    public let profile: SpeedProfile
    public let persona: DriverPersona
    public let mode: TravelMode
    public let playbackRate: Double
    public private(set) var state = MotionEngineState()
    private var generator: SeededGenerator
    private var noise: Double = 0

    public init(profile: SpeedProfile, persona: DriverPersona, mode: TravelMode, playbackRate: Double = 1, seed: UInt64) {
        self.profile = profile
        self.persona = persona
        self.mode = mode
        self.playbackRate = max(0.1, playbackRate)
        self.generator = SeededGenerator(seed: seed &* 31 &+ 7)
    }

    public var progress: Double {
        guard profile.polyline.length > 0 else { return 1 }
        return min(1, state.distance / profile.polyline.length)
    }

    public var remainingTime: TimeInterval? {
        guard !state.finished else { return 0 }
        let remaining = profile.polyline.length - state.distance
        guard remaining > 0 else { return 0 }
        let assumed = max(profile.minimumSpeed(from: state.distance, to: profile.polyline.length), Speed.mph(8))
        return remaining / assumed / playbackRate
    }

    public mutating func step(deltaTime: TimeInterval, now: Date = .now) -> SimulatedFix {
        let total = deltaTime * playbackRate
        var consumed: TimeInterval = 0
        while consumed < total && !state.finished {
            let slice = min(Self.subStep, total - consumed)
            advance(slice)
            consumed += slice
        }
        state.elapsed += total

        noise = noise * 0.85 + generator.gaussian(mean: 0, deviation: persona.speedNoise) * 0.15
        let reported = state.speed > 1 ? max(0, state.speed + noise) : state.speed
        return makeFix(speed: reported, now: now)
    }

    private mutating func advance(_ dt: TimeInterval) {
        if state.dwellRemaining > 0 {
            state.dwellRemaining -= dt
            state.speed = 0
            state.acceleration = 0
            return
        }

        let length = profile.polyline.length

        if let stop = pendingStop(), stop.alongTrack - state.distance <= Self.arrivalWindow, state.speed < Self.arrivalSpeed {
            state.distance = stop.alongTrack
            state.dwellRemaining = stop.dwell
            state.pendingStopIndex += 1
            state.stopsMade += 1
            state.speed = 0
            state.acceleration = 0
            return
        }

        if length - state.distance <= Self.arrivalWindow, state.speed < Self.arrivalSpeed {
            state.distance = length
            state.speed = 0
            state.acceleration = 0
            state.finished = true
            return
        }

        let brakingDistance = (state.speed * state.speed) / (2 * persona.braking)
        let lookAhead = state.distance + max(6, state.speed * dt + brakingDistance)
        var target = profile.minimumSpeed(from: state.distance, to: lookAhead)

        var gate = length - state.distance
        if let stop = pendingStop() { gate = min(gate, stop.alongTrack - state.distance) }
        gate = max(0, gate - state.speed * dt)
        target = min(target, sqrt(2 * persona.braking * Self.brakingMargin * gate))

        if target < Self.creepSpeed && gate > 0.1 { target = Self.creepSpeed }

        let desired = target > state.speed
            ? min(persona.acceleration, (target - state.speed) / dt)
            : max(-persona.braking, (target - state.speed) / dt)

        let maxChange = persona.jerkLimit * dt
        state.acceleration = min(max(desired, state.acceleration - maxChange), state.acceleration + maxChange)
        state.speed = max(0, state.speed + state.acceleration * dt)
        state.distance = min(length, state.distance + state.speed * dt)

        while let stop = pendingStop(), stop.alongTrack <= state.distance {
            state.distance = stop.alongTrack
            state.dwellRemaining = stop.dwell
            state.pendingStopIndex += 1
            state.stopsMade += 1
            state.speed = 0
            state.acceleration = 0
            return
        }

        if state.distance >= length { state.finished = true }
    }

    private func pendingStop() -> StopEvent? {
        guard state.pendingStopIndex < profile.stops.count else { return nil }
        return profile.stops[state.pendingStopIndex]
    }

    private mutating func makeFix(speed: Double, now: Date) -> SimulatedFix {
        let coordinate = profile.polyline.coordinate(at: state.distance)
        let course = speed > 0.5 ? profile.polyline.bearing(at: state.distance) : -1
        let accuracy = 4 + generator.double(in: 0...3)
        return SimulatedFix(
            coordinate: coordinate,
            speed: speed,
            course: course,
            altitude: 0,
            horizontalAccuracy: accuracy,
            timestamp: now
        )
    }
}
