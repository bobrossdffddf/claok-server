import Testing
import Foundation
@testable import CloakKit

@Suite("Rehearsal")
struct RehearsalTests {
    /// A straight-ish drive of a few km built from real-ish coordinates.
    func straightRoute(pointCount: Int = 200, spacingMeters: Double = 20) -> Polyline {
        var points: [Coordinate] = []
        let start = Coordinate(latitude: 40.0, longitude: -74.0)
        let dLat = spacingMeters / 111_320.0
        for i in 0..<pointCount {
            points.append(Coordinate(latitude: start.latitude + dLat * Double(i), longitude: start.longitude))
        }
        return Polyline(points: points)
    }

    func profile(_ line: Polyline, limitMph: Double = 35) -> SpeedProfile {
        let limits = [Double](repeating: Speed.mph(limitMph), count: line.points.count)
        return SpeedProfileBuilder.build(
            polyline: line,
            postedLimits: limits,
            controls: [],
            persona: .normal,
            mode: .drive,
            seed: 99
        )
    }

    @Test func aCleanDriveGradesWell() {
        let line = straightRoute()
        let rehearsal = Rehearsal.run(profile: profile(line), persona: .normal, mode: .drive, seed: 99)
        #expect(rehearsal.score > 70)
        #expect(rehearsal.duration > 0)
        #expect(rehearsal.distance > 3000)
        #expect(rehearsal.topSpeed > Speed.mph(20))
        #expect(!rehearsal.samples.isEmpty)
    }

    @Test func itActuallyReachesTheEnd() {
        let line = straightRoute()
        let rehearsal = Rehearsal.run(profile: profile(line), persona: .normal, mode: .drive, seed: 1)
        // Last sample should be near the end of the line.
        let end = line.points.last!
        #expect(rehearsal.samples.last!.coordinate.distance(to: end) < 50)
    }

    @Test func samplesAreCappedForLongDrives() {
        var points: [Coordinate] = []
        let start = Coordinate(latitude: 40.0, longitude: -74.0)
        let dLat = 20.0 / 111_320.0
        for i in 0..<4000 {
            points.append(Coordinate(latitude: start.latitude + dLat * Double(i), longitude: start.longitude))
        }
        let line = Polyline(points: points)
        let rehearsal = Rehearsal.run(profile: profile(line, limitMph: 65), persona: .normal, mode: .drive, seed: 5)
        #expect(rehearsal.samples.count <= Rehearsal.maxSamples + 1)
        #expect(rehearsal.distance > 70_000)
    }

    @Test func emptyRouteIsHandled() {
        let line = Polyline(points: [Coordinate(latitude: 40, longitude: -74)])
        let rehearsal = Rehearsal.run(profile: profile(line), persona: .normal, mode: .drive, seed: 1)
        #expect(rehearsal.score == 100)
        #expect(rehearsal.samples.isEmpty)
        #expect(rehearsal.weakest == nil)
    }

    @Test func headlineMatchesScore() {
        let good = Rehearsal(trace: Believability(score: 95, tells: []), weakest: nil, duration: 1, distance: 1, topSpeed: 1, stops: 0, samples: [])
        let bad = Rehearsal(trace: Believability(score: 20, tells: []), weakest: nil, duration: 1, distance: 1, topSpeed: 1, stops: 0, samples: [])
        #expect(good.headline == "This drive looks real")
        #expect(bad.headline == "This drive would stand out")
    }

    @Test func angleDifferenceWrapsCorrectly() {
        #expect(Rehearsal.angleDifference(350, 10) == 20)
        #expect(Rehearsal.angleDifference(10, 350) == 20)
        #expect(Rehearsal.angleDifference(0, 180) == 180)
        #expect(Rehearsal.angleDifference(90, 90) == 0)
    }

    @Test func aTeleportInTheMiddleIsFoundAsWeakest() {
        // Hand-built fixes: steady, then a single impossible jump, then steady.
        var fixes: [SimulatedFix] = []
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var lat = 40.0
        for i in 0..<20 {
            if i == 10 { lat += 0.01 } else { lat += 0.0002 }
            let speed = i == 10 ? 60.0 : 12.0
            fixes.append(SimulatedFix(
                coordinate: Coordinate(latitude: lat, longitude: -74.0),
                speed: speed, course: 0, altitude: 0, horizontalAccuracy: 5,
                timestamp: base.addingTimeInterval(Double(i))
            ))
        }
        let weakest = Rehearsal.findWeakest(in: fixes, profile: profile(straightRoute()))
        #expect(weakest != nil)
        #expect(abs(weakest!.at - 10) <= 1)
    }
}
