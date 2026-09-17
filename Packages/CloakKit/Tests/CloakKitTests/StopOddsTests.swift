import Testing
import Foundation
@testable import CloakKit

/// The route preview draws a stop as certain or as a maybe by reading the same
/// odds the drive rolls against. If those two ever hold separate copies of the
/// numbers, the picture starts lying about the drive it is a picture of.
@Suite("Stop odds")
struct StopOddsTests {
    private func control(_ kind: TrafficControlKind, signalled: Bool = false) -> TrafficControl {
        TrafficControl(
            kind: kind,
            coordinate: Coordinate(latitude: 40, longitude: -75),
            alongTrack: 100,
            isSignalled: signalled
        )
    }

    @Test func aStopSignAlwaysStopsYou() {
        #expect(StopOdds.chance(of: control(.stop), persona: .normal, onFoot: false) == 1)
    }

    @Test func aSignalIsTheDriversOwnHabit() {
        for persona in DriverPersona.all {
            #expect(
                StopOdds.chance(of: control(.signal), persona: persona, onFoot: false)
                    == persona.redLightProbability
            )
        }
    }

    @Test func aSignalledCrossingStopsYouMoreOftenThanAPlainOne() {
        let signalled = StopOdds.chance(of: control(.crossing, signalled: true), persona: .normal, onFoot: false)
        let plain = StopOdds.chance(of: control(.crossing), persona: .normal, onFoot: false)
        #expect(signalled > plain)
        #expect(plain < 0.1)
    }

    @Test func aRoundaboutIsACeilingNotAHalt() {
        // The builder handles a roundabout by capping the speed through it. It
        // never appends a stop, so anything drawing stops must not claim one.
        #expect(StopOdds.chance(of: control(.roundabout), persona: .normal, onFoot: false) == 0)
    }

    @Test func onFootOnlyTheCrossingMatters() {
        for kind in [TrafficControlKind.signal, .stop, .giveWay, .roundabout] {
            #expect(StopOdds.chance(of: control(kind), persona: .normal, onFoot: true) == 0)
        }
        #expect(
            StopOdds.chance(of: control(.crossing), persona: .normal, onFoot: true)
                == StopOdds.crossingOnFoot
        )
    }

    @Test func theOddsMatchWhatTheBuilderActuallyDoes() {
        // Not a restatement of the constants: this runs the builder many times
        // over the same give way and counts how often it really halts. If
        // somebody changes the roll in `SpeedProfileBuilder` without changing
        // `StopOdds`, the preview would go on drawing the old number and this
        // is what catches it.
        // Past `cleanStartDistance`, deliberately. The builder drops every
        // non stop sign halt inside the first 1200 m of driving, so a control
        // placed earlier than that never fires and this would measure zero.
        let line = Polyline(points: (0..<600).map {
            Coordinate(latitude: 40, longitude: -75).offset(metersNorth: Double($0) * 5, metersEast: 0)
        })
        let limits = [Double](repeating: Speed.mph(30), count: line.points.count)
        let at = 400
        #expect(line.cumulative[at] > SpeedProfile.cleanStartDistance)
        let giveWay = TrafficControl(
            kind: .giveWay,
            coordinate: line.points[at],
            alongTrack: line.cumulative[at]
        )

        var halts = 0
        let runs = 600
        for seed in 0..<runs {
            let profile = SpeedProfileBuilder.build(
                polyline: line,
                postedLimits: limits,
                controls: [giveWay],
                persona: .normal,
                mode: .drive,
                seed: UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 &+ 1
            )
            if profile.stops.contains(where: { $0.kind == .giveWay }) { halts += 1 }
        }

        let observed = Double(halts) / Double(runs)
        // Three standard errors of a Bernoulli trial at this rate over 600
        // draws is about 0.06, so this is wide enough never to flake and tight
        // enough to catch a changed constant.
        #expect(abs(observed - StopOdds.giveWay) < 0.07, "observed \(observed), halts \(halts) of \(runs)")
    }
}
