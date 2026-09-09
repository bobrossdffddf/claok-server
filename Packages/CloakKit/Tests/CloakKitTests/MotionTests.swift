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

    @Test func idleJitterStaysInsideRadius() {
        let anchor = Coordinate(latitude: 37.0, longitude: -122.0)
        var jitter = IdleJitter(anchor: anchor, radius: 8, seed: 3)
        for _ in 0..<500 {
            let fix = jitter.next()
            #expect(anchor.distance(to: fix.coordinate) <= 8.5)
        }
    }
}

@Suite("Road data")
struct RoadDataTests {
    @Test func maxSpeedParsing() {
        #expect(MaxSpeedParser.parse("30 mph").map { Int(Speed.toMph($0).rounded()) } == 30)
        #expect(MaxSpeedParser.parse("50").map { Int(Speed.toKph($0).rounded()) } == 50)
        #expect(MaxSpeedParser.parse("banana") == nil)
    }

    @Test func roadClassDefaults() {
        #expect(RoadClass(osmHighway: "motorway_link") == .motorway)
        #expect(RoadClass(osmHighway: "residential").defaultLimit == Speed.mph(25))
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
