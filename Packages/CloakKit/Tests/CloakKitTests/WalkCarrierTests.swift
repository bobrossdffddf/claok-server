import Testing
import Foundation
@testable import CloakKit

/// The walk decision has to survive the trip from the route builder to the
/// running simulation. It used to be inferred twice, once by the builder and
/// again at simulation time from the posted speed limits, and the second
/// inference could disagree with the first.
@Suite("Walk carrier")
struct WalkCarrierTests {
    private func line(metres: Double, points: Int = 41) -> Polyline {
        let step = metres / Double(points - 1)
        return Polyline(points: (0..<points).map {
            Coordinate(latitude: 40, longitude: -75).offset(metersNorth: Double($0) * step, metersEast: 0)
        })
    }

    @Test func spansSurviveDensification() {
        let coarse = line(metres: 1_000, points: 5)
        let spans = [
            WalkingLegs.Span(mode: .drive, start: 0, end: 800),
            WalkingLegs.Span(mode: .walk, start: 800, end: 1_000)
        ]
        // The simulation densifies to 4 m before it runs. A modes-per-point
        // array computed on the coarse line would have to be resampled and
        // would drift; a distance range does not care about sampling.
        let dense = coarse.densified(spacing: 4)
        let modes = WalkingLegs.modes(polyline: dense, spans: spans, fallback: .drive)

        #expect(modes.count == dense.points.count)
        #expect(modes.first == .drive)
        #expect(modes.last == .walk)

        let cumulative = dense.cumulative
        for (index, distance) in cumulative.enumerated() {
            if distance < 780 { #expect(modes[index] == .drive) }
            if distance > 820 { #expect(modes[index] == .walk) }
        }
    }

    @Test func noSpansMeansTheRequestedModeThroughout() {
        let dense = line(metres: 400).densified(spacing: 4)
        let modes = WalkingLegs.modes(polyline: dense, spans: [], fallback: .drive)
        #expect(modes.allSatisfy { $0 == .drive })
    }

    @Test func explicitSpansBeatTheRoadData() {
        // A mapped pavement running beside the carriageway reads as a footway,
        // and if the route line measures nearer to it than to the road, the
        // limits say walking pace for a stretch of an ordinary drive. When the
        // builder has already decided, the road data does not get a vote.
        let dense = line(metres: 600).densified(spacing: 4)
        let sidewalkLimits = [Double](repeating: Speed.mph(3), count: dense.points.count)

        let inferred = SpeedProfileBuilder.build(
            polyline: dense,
            postedLimits: sidewalkLimits,
            controls: [],
            persona: .normal,
            mode: .drive,
            seed: 7
        )
        let told = SpeedProfileBuilder.build(
            polyline: dense,
            postedLimits: sidewalkLimits,
            controls: [],
            persona: .normal,
            mode: .drive,
            walkingSpans: [WalkingLegs.Span(mode: .drive, start: 0, end: dense.length)],
            seed: 7
        )

        #expect(inferred.mode(at: 300) == .walk)
        #expect(told.mode(at: 300) == .drive)
    }

    @Test func aPayloadWrittenBeforeSpansExistedStillDecodes() throws {
        // `walkingSpans` is optional so a synthesised decoder reaches for it
        // with `decodeIfPresent`. A non optional array would throw here and
        // every saved run from an older build would fail to start.
        let old = """
        {"points":[{"latitude":40,"longitude":-75}],"postedLimits":[],"controls":[],
        "personaID":"normal","mode":"drive","playbackRate":1,"loop":false,
        "seed":9,"label":"Route","dwellRadius":4}
        """
        let payload = try JSONDecoder().decode(TunnelStartPayload.self, from: Data(old.utf8))
        #expect(payload.walkingSpans == nil)
        #expect(payload.label == "Route")
    }

    @Test func spansRoundTripThroughThePayload() throws {
        var payload = TunnelStartPayload.fixed(Coordinate(latitude: 40, longitude: -75), label: "Gate")
        payload.walkingSpans = [WalkingLegs.Span(mode: .walk, start: 0, end: 220)]
        let data = try JSONEncoder().encode(payload)
        let back = try JSONDecoder().decode(TunnelStartPayload.self, from: data)
        #expect(back.walkingSpans?.count == 1)
        #expect(back.walkingSpans?.first?.mode == .walk)
        #expect(back.walkingSpans?.first?.end == 220)
    }

    @Test func aPlanWithNoLegsCarriesNoOpinion() {
        // Nobody looked, so the simulation should work it out rather than be
        // told there is no walking.
        let plan = RoutePlan(
            waypoints: [],
            polyline: line(metres: 500),
            metadata: RoadMetadata(segments: []),
            mode: .drive,
            expectedTravelTime: 60
        )
        #expect(plan.walkingSpans == nil)
    }
}
