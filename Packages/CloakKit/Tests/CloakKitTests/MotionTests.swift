import Testing
import Foundation
@testable import CloakKit

@Suite("Geometry")
struct GeometryTests {
    @Test func distanceIsRoughlyCorrect() {
        let a = Coordinate(latitude: 37.33182, longitude: -122.03118)
        let b = Coordinate(latitude: 37.34182, longitude: -122.03118)
        let distance = a.distance(to: b)
        #expect(distance > 1100 && distance < 1120)
    }

    @Test func densifyProducesRegularSpacing() {
        let line = Polyline(points: [
            Coordinate(latitude: 37.0, longitude: -122.0),
            Coordinate(latitude: 37.01, longitude: -122.0)
        ])
        let dense = line.densified(spacing: 5)
        #expect(dense.points.count > 200)
        let gap = dense.points[0].distance(to: dense.points[1])
        #expect(gap > 4.5 && gap < 5.5)
    }

    @Test func cornerSpeedFallsWithRadius() {
        let tight = Curvature.cornerSpeed(radius: 10, lateralAcceleration: 3)
        let wide = Curvature.cornerSpeed(radius: 200, lateralAcceleration: 3)
        #expect(tight < wide)
        #expect(tight > 5 && tight < 6)
    }
}

@Suite("Motion")
struct MotionTests {
    private func straightRoute(meters: Double) -> Polyline {
        let start = Coordinate(latitude: 37.0, longitude: -122.0)
        let end = start.moved(bearing: 0, distance: meters)
        return Polyline(points: [start, end]).densified(spacing: 5)
    }

    @Test func carAcceleratesAndStops() {
        let line = straightRoute(meters: 800)
        let limits = Array(repeating: Speed.mph(35), count: line.points.count)
        let profile = SpeedProfileBuilder.build(
            polyline: line,
            postedLimits: limits,
            controls: [],
            persona: .normal,
            mode: .drive,
            seed: 42
        )
        var engine = MotionEngine(profile: profile, persona: .normal, mode: .drive, seed: 42)

        var peak = 0.0
        var steps = 0
        while !engine.state.finished && steps < 600 {
            let fix = engine.step(deltaTime: 1)
            peak = max(peak, fix.speed)
            steps += 1
        }

        #expect(engine.state.finished)
        #expect(peak > Speed.mph(30))
        #expect(peak < Speed.mph(45))
    }

    @Test func trafficSignalCreatesADwell() {
        let line = straightRoute(meters: 1200)
        let limits = Array(repeating: Speed.mph(35), count: line.points.count)
        let signal = TrafficControl(kind: .stop, coordinate: line.coordinate(at: 600), alongTrack: 600)
        let profile = SpeedProfileBuilder.build(
            polyline: line,
            postedLimits: limits,
            controls: [signal],
            persona: .normal,
            mode: .drive,
            seed: 7
        )
        #expect(profile.stops.count == 1)

        var engine = MotionEngine(profile: profile, persona: .normal, mode: .drive, seed: 7)
        var steps = 0
        while !engine.state.finished && steps < 900 {
            _ = engine.step(deltaTime: 1)
            steps += 1
        }
        #expect(engine.state.finished)
        #expect(engine.state.stopsMade == 1)
    }

    @Test func brakingStaysComfortable() {
        let line = straightRoute(meters: 1200)
        let limits = Array(repeating: Speed.mph(35), count: line.points.count)
        let signal = TrafficControl(kind: .stop, coordinate: line.coordinate(at: 600), alongTrack: 600)
        let profile = SpeedProfileBuilder.build(
            polyline: line, postedLimits: limits, controls: [signal], persona: .normal, mode: .drive, seed: 11
        )
        var engine = MotionEngine(profile: profile, persona: .normal, mode: .drive, seed: 11)
        var previous = 0.0
        var worst = 0.0
        var steps = 0
        while !engine.state.finished && steps < 900 {
            let fix = engine.step(deltaTime: 1)
            worst = max(worst, abs(fix.speed - previous))
            previous = fix.speed
            steps += 1
        }
        #expect(worst < 4.0)
    }

    @Test func everyRouteReachesTheEnd() {
        for stopCount in 0...6 {
            let line = straightRoute(meters: 1500)
            let limits = Array(repeating: Speed.mph(35), count: line.points.count)
            let controls = (0..<stopCount).map { index in
                let along = 150.0 + Double(index) * 200
                return TrafficControl(kind: .stop, coordinate: line.coordinate(at: along), alongTrack: along)
            }
            let profile = SpeedProfileBuilder.build(
                polyline: line, postedLimits: limits, controls: controls, persona: .cautious, mode: .drive, seed: UInt64(stopCount + 1)
            )
            var engine = MotionEngine(profile: profile, persona: .cautious, mode: .drive, seed: UInt64(stopCount + 1))
            var steps = 0
            while !engine.state.finished && steps < 2000 {
                _ = engine.step(deltaTime: 1)
                steps += 1
            }
            #expect(engine.state.finished)
        }
    }

    @Test func seedsAreRepeatable() {
        let line = straightRoute(meters: 500)
        let limits = Array(repeating: Speed.mph(30), count: line.points.count)
        func run() -> [Double] {
            let profile = SpeedProfileBuilder.build(
                polyline: line, postedLimits: limits, controls: [], persona: .assertive, mode: .drive, seed: 99
            )
            var engine = MotionEngine(profile: profile, persona: .assertive, mode: .drive, seed: 99)
            var speeds: [Double] = []
            for _ in 0..<80 { speeds.append(engine.step(deltaTime: 1).speed) }
            return speeds
        }
        #expect(run() == run())
    }

    /// A car waits on the approach to a junction, not in it. The stop used to
    /// be placed on the control node itself and the engine then snapped the
    /// car up onto it, so the wait happened past the light.
    @Test func theCarWaitsOnTheApproachSideOfAJunction() {
        let start = Coordinate(latitude: 37.0, longitude: -122.0)
        let line = Polyline(points: [start, start.moved(bearing: 90, distance: 2000)]).densified(spacing: 4)
        let junction = 1400.0
        let metadata = RoadMetadata(segments: [], controls: [
            TrafficControl(kind: .stop, coordinate: line.coordinate(at: junction), alongTrack: 0)
        ])
        let controls = metadata.snappedControls(to: line)
        #expect(controls.count == 1)

        let profile = SpeedProfileBuilder.build(
            polyline: line,
            postedLimits: Array(repeating: Speed.mph(35), count: line.points.count),
            controls: controls,
            persona: .normal,
            mode: .drive,
            seed: 21
        )
        #expect(profile.stops.count == 1)

        var engine = MotionEngine(profile: profile, persona: .normal, mode: .drive, seed: 21)
        var restingAt: Double?
        var steps = 0
        while !engine.state.finished && steps < 2000 {
            _ = engine.step(deltaTime: 1)
            if engine.state.stopsMade == 1, restingAt == nil, engine.state.speed == 0 {
                restingAt = engine.state.distance
            }
            steps += 1
        }
        guard let restingAt else { Issue.record("the car never stopped"); return }
        #expect(restingAt < junction)
        // Short of the junction, but at it rather than a block back from it.
        #expect(restingAt > junction - 15)
    }

    @Test func idleJitterStaysNearAnchorWithoutRunningAway() {
        // The idle model is a mean-reverting GPS walk: it mostly sits within
        // the radius, breaches it briefly on multipath, and never wanders off.
        let anchor = Coordinate(latitude: 37.0, longitude: -122.0)
        var jitter = IdleJitter(anchor: anchor, radius: 8, seed: 3)
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        var withinRadius = 0
        let total = 2000
        for _ in 0..<total {
            now = now.addingTimeInterval(1)
            let fix = jitter.next(now: now)
            let d = anchor.distance(to: fix.coordinate)
            #expect(d < 60)
            if d <= 8 { withinRadius += 1 }
        }
        // Most of the time it is inside the radius, as a resting phone is.
        #expect(Double(withinRadius) / Double(total) > 0.7)
    }
}

@Suite("Road data")
struct RoadDataTests {
    /// A dead straight road drawn the way map data really is: a few tens of
    /// centimetres of wobble along the line, sampled every four metres, which
    /// is what the speed profile is handed.
    private func wobblyStraightRoad() -> Polyline {
        var generator = SeededGenerator(seed: 0xB0A7)
        let start = Coordinate(latitude: 37.0, longitude: -122.0)
        var points: [Coordinate] = []
        for step in 0...400 {
            let along = start.moved(bearing: 90, distance: Double(step) * 4)
            points.append(along.moved(bearing: 0, distance: generator.gaussian(mean: 0, deviation: 0.35)))
        }
        return Polyline(points: points)
    }

    @Test func maxSpeedParsing() {
        #expect(MaxSpeedParser.parse("30 mph").map { Int(Speed.toMph($0).rounded()) } == 30)
        #expect(MaxSpeedParser.parse("50").map { Int(Speed.toKph($0).rounded()) } == 50)
        #expect(MaxSpeedParser.parse("banana") == nil)
    }

    /// The shapes an OSM `maxspeed` tag actually turns up in. A form this
    /// cannot read has to come back nil so the caller uses the road class,
    /// rather than reading the number under some other unit.
    @Test func maxSpeedTagFormsAreRead() {
        func mph(_ raw: String) -> Int? { MaxSpeedParser.parse(raw).map { Int(Speed.toMph($0).rounded()) } }
        func kph(_ raw: String) -> Int? { MaxSpeedParser.parse(raw).map { Int(Speed.toKph($0).rounded()) } }

        #expect(mph("45 mph") == 45)
        // Written without the space often enough to matter. This used to fail
        // the number parse and silently fall back to the road class default.
        #expect(mph("45mph") == 45)
        #expect(mph("45 MPH") == 45)
        // A bare number is km/h, and so is every spelling of it.
        #expect(kph("70") == 70)
        #expect(kph("70 km/h") == 70)
        #expect(kph("70kph") == 70)
        #expect(kph("70 kmh") == 70)
        // A list is per-lane or seasonal; the first entry applies to the way.
        #expect(mph("45 mph;25 mph") == 45)
        #expect(mph("none") == 80)
        #expect(mph("walk") == 4)
        #expect(MaxSpeedParser.parse("5 knots").map { Int(($0 / 0.514444).rounded()) } == 5)
        // Not speeds: a sign reference, a country profile, junk, nothing.
        #expect(MaxSpeedParser.parse("signals") == nil)
        #expect(MaxSpeedParser.parse("DE:urban") == nil)
        #expect(MaxSpeedParser.parse("30 zone") == nil)
        #expect(MaxSpeedParser.parse("banana") == nil)
        #expect(MaxSpeedParser.parse("") == nil)
        #expect(MaxSpeedParser.parse("0") == nil)
    }

    /// A straight 45 mph road keeps its limit. The corner cap used to be
    /// measured between neighbouring points four metres apart, where the
    /// wobble in the line is a hairpin, and it held the drive at about 39 mph.
    @Test func aStraightRoadKeepsItsPostedLimit() {
        let line = wobblyStraightRoad()
        let profile = SpeedProfileBuilder.build(
            polyline: line,
            postedLimits: Array(repeating: Speed.mph(45), count: line.points.count),
            controls: [],
            persona: .normal,
            mode: .drive,
            seed: 5
        )
        // Away from the tail, where the profile is braking for the finish.
        let cruising = line.points.indices
            .filter { line.cumulative[$0] < line.length - 200 }
            .map { profile.ceiling[$0] }
        #expect(Speed.toMph(cruising.min() ?? 0) > 44)
    }

    /// The measurement the span is there for, kept so the reason stays on the
    /// record. Across a single densified step that same straight road reads as
    /// a string of tight corners; across the span a car actually turns on, it
    /// reads as straight.
    @Test func aShortSpanMistakesMapWobbleForCorners() {
        let line = wobblyStraightRoad()
        let perStep = Curvature.profile(for: line, lateralAcceleration: 3, baseline: 4)
        let perCorner = Curvature.profile(for: line, lateralAcceleration: 3, baseline: Curvature.baseline)
        #expect(Speed.toMph(perStep.min() ?? 0) < 25)
        #expect(Speed.toMph(perCorner.min() ?? 0) > 55)
    }

    /// And the cap has not simply been switched off: a genuine 25 m corner
    /// still slows the car right down, while the straight leading into it
    /// keeps the limit.
    @Test func aRealCornerStillSlowsTheCarDown() {
        var points: [Coordinate] = []
        var cursor = Coordinate(latitude: 37.0, longitude: -122.0)
        var heading = 90.0
        for _ in 0..<30 {
            points.append(cursor)
            cursor = cursor.moved(bearing: heading, distance: 4)
        }
        let cornerRadius = 25.0
        let cornerSteps = Int((Double.pi / 2 * cornerRadius) / 4)
        for _ in 0..<cornerSteps {
            points.append(cursor)
            cursor = cursor.moved(bearing: heading, distance: 4)
            heading -= (4.0 / cornerRadius) * 180 / .pi
        }
        for _ in 0..<40 {
            points.append(cursor)
            cursor = cursor.moved(bearing: heading, distance: 4)
        }
        points.append(cursor)

        let line = Polyline(points: points)
        let profile = SpeedProfileBuilder.build(
            polyline: line,
            postedLimits: Array(repeating: Speed.mph(45), count: line.points.count),
            controls: [],
            persona: .normal,
            mode: .drive,
            seed: 5
        )
        let throughTheCorner = line.points.indices
            .filter { line.cumulative[$0] > 120 && line.cumulative[$0] < 160 }
            .map { profile.ceiling[$0] }
        #expect(Speed.toMph(throughTheCorner.min() ?? 100) < 25)
        // The approach, a hundred metres back, is still the posted limit.
        #expect(Speed.toMph(profile.ceiling[0]) > 44)
    }

    /// A control snaps to where a car stops for it, which is short of the
    /// junction node. A roundabout is a stretch of slow road rather than a
    /// line to halt at, so it keeps the node's own position.
    @Test func controlsLandOnTheApproachNotInTheJunction() {
        let start = Coordinate(latitude: 37.0, longitude: -122.0)
        let line = Polyline(points: [start, start.moved(bearing: 90, distance: 400)]).densified(spacing: 5)
        let node = line.coordinate(at: 200)

        let signals = RoadMetadata(segments: [], controls: [
            TrafficControl(kind: .signal, coordinate: node, alongTrack: 0)
        ]).snappedControls(to: line)
        #expect(signals.count == 1)
        #expect(abs(signals[0].alongTrack - (200 - RoadMetadata.stopLineSetback)) < 1)

        let roundabout = RoadMetadata(segments: [], controls: [
            TrafficControl(kind: .roundabout, coordinate: node, alongTrack: 0)
        ]).snappedControls(to: line)
        #expect(abs(roundabout[0].alongTrack - 200) < 1)
    }

    @Test func roadClassDefaults() {
        #expect(RoadClass(osmHighway: "motorway_link") == .motorway)
        #expect(RoadClass(osmHighway: "residential").defaultLimit == Speed.mph(25))
    }

    /// A point on a 45 mph road, right at a junction with a 25 mph side
    /// street, must read 45. The old nearest-vertex lookup read 25 there.
    @Test func limitsFollowTheRoadBeingDriven() {
        let start = Coordinate(latitude: 37.0, longitude: -122.0)
        let main = Polyline(points: [start, start.moved(bearing: 90, distance: 600)]).densified(spacing: 10)
        let junction = main.coordinate(at: 300)
        let side = [junction.moved(bearing: 0, distance: 120), junction, junction.moved(bearing: 180, distance: 120)]
        let metadata = RoadMetadata(segments: [
            RoadSegment(roadClass: .primary, limit: Speed.mph(45), nodes: [start, start.moved(bearing: 90, distance: 600)]),
            RoadSegment(roadClass: .residential, limit: Speed.mph(25), nodes: side),
        ], controls: [])
        let limits = metadata.limits(along: main)
        let atJunction = limits[main.points.indices.min(by: { abs(main.cumulative[$0] - 300) < abs(main.cumulative[$1] - 300) })!]
        #expect(Int(Speed.toMph(atJunction).rounded()) == 45)
        #expect(limits.allSatisfy { Int(Speed.toMph($0).rounded()) == 45 })
    }

    @Test func controlsSnapToTheLine() {
        let start = Coordinate(latitude: 37.0, longitude: -122.0)
        let line = Polyline(points: [start, start.moved(bearing: 90, distance: 400)]).densified(spacing: 5)
        let near = TrafficControl(kind: .signal, coordinate: line.coordinate(at: 200).moved(bearing: 0, distance: 8), alongTrack: 0)
        let far = TrafficControl(kind: .signal, coordinate: line.coordinate(at: 200).moved(bearing: 0, distance: 90), alongTrack: 0)
        let metadata = RoadMetadata(segments: [], controls: [near, far])
        let snapped = metadata.snappedControls(to: line)
        #expect(snapped.count == 1)
        #expect(abs(snapped[0].alongTrack - 200) < 15)
    }
}

@Suite("Pairing")
struct PairingTests {
    @Test func rejectsNonPlist() {
        #expect(throws: PairingError.self) {
            _ = try PairingRecord.parse(Data("not a plist".utf8))
        }
    }

    @Test func acceptsAWellFormedRecord() throws {
        let dictionary: [String: Any] = [
            "UDID": "00008110-000A1B2C3D4E5F6G",
            "HostCertificate": Data([0x01, 0x02]),
            "HostPrivateKey": Data([0x03, 0x04])
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        let record = try PairingRecord.parse(data)
        #expect(record.udid.hasPrefix("00008110"))
    }
}

@Suite("SHIELD")
struct ShieldTests {
    /// The car does 50 on a 30 road for a minute. The shadow must never
    /// report above 30 and must end up behind the car.
    @Test func neverReportsAboveTheCap() {
        var shield = ShieldEngine(settings: ShieldSettings(isEnabled: true, mode: .slow), fallbackLimit: Speed.mph(30))
        let start = Coordinate(latitude: 37.0, longitude: -122.0)
        var position = start
        var maxShown = 0.0
        for second in 0..<60 {
            position = position.moved(bearing: 90, distance: Speed.mph(50))
            shield.observe(RealFix(coordinate: position, speed: Speed.mph(50), timestamp: Date(timeIntervalSince1970: Double(second))))
            if let fix = shield.step(deltaTime: 1, limitAt: { _ in Speed.mph(30) }) {
                maxShown = max(maxShown, fix.speed)
            }
        }
        #expect(maxShown <= Speed.mph(30) + 0.01)
        #expect(shield.holdingBack > 400)
    }

    /// Once the car stops, the shadow catches up at the cap and then stops too.
    @Test func catchesUpWhenTheCarStops() {
        var shield = ShieldEngine(settings: ShieldSettings(isEnabled: true, mode: .fast), fallbackLimit: Speed.mph(30))
        var position = Coordinate(latitude: 37.0, longitude: -122.0)
        for _ in 0..<30 {
            position = position.moved(bearing: 0, distance: Speed.mph(60))
            shield.observe(RealFix(coordinate: position, speed: Speed.mph(60), timestamp: .now))
            _ = shield.step(deltaTime: 1, limitAt: { _ in Speed.mph(30) })
        }
        #expect(shield.holdingBack > 100)
        var lastSpeed = 0.0
        for _ in 0..<120 {
            shield.observe(RealFix(coordinate: position, speed: 0, timestamp: .now))
            lastSpeed = shield.step(deltaTime: 1, limitAt: { _ in Speed.mph(30) })?.speed ?? 0
        }
        #expect(shield.holdingBack < 1)
        #expect(lastSpeed == 0)
    }
}
