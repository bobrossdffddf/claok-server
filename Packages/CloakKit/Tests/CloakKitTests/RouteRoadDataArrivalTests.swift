import Testing
import Foundation
@testable import CloakKit

// MARK: - A small world

private let start = Coordinate(latitude: 34.0, longitude: -118.0)
private let finish = start.moved(bearing: 90, distance: 6_000)

private func points(_ from: Coordinate, _ to: Coordinate, step: Double = 50) -> [Coordinate] {
    var output = [from]
    let count = max(1, Int((from.distance(to: to) / step).rounded(.up)))
    for index in 1...count {
        output.append(from.interpolated(to: to, fraction: Double(index) / Double(count)))
    }
    return output
}

private let mainRoad = points(start, finish)

/// One road along the whole line, posted at 45, with a stop sign halfway.
private let mapped = RoadMetadata(
    segments: [RoadSegment(roadClass: .primary, limit: Speed.mph(45), nodes: mainRoad)],
    controls: [TrafficControl(kind: .stop, coordinate: start.moved(bearing: 90, distance: 3_000), alongTrack: 0)],
    wasFallback: false
)

private func directions() -> RouteBuilder.Directions {
    { from, to, mode, _ in
        _ = (from, to, mode)
        return [RouteBuilder.Offer(points: mainRoad, travelTime: 420, name: "Main St")]
    }
}

private func stop(_ coordinate: Coordinate, _ title: String) -> RouteWaypoint {
    RouteWaypoint(coordinate: coordinate, title: title)
}

private let trip = [stop(start, "Home"), stop(finish, "Work")]

private actor Tally {
    private(set) var calls = 0
    private(set) var failuresLeft: Int
    init(failuresLeft: Int = 0) { self.failuresLeft = failuresLeft }
    func next() -> Bool {
        calls += 1
        if failuresLeft > 0 { failuresLeft -= 1; return false }
        return true
    }
}

private func middleLimit(of plan: RoutePlan) -> Double {
    let densified = plan.polyline.densified(spacing: 5)
    let limits = plan.metadata.limits(along: densified, fallback: .residential)
    return limits[limits.count / 2]
}

// MARK: -

@Suite("Road data arriving late")
struct RouteRoadDataArrivalTests {
    @Test func theLineIsReadyBeforeItsRoadDataIs() async throws {
        let builder = RouteBuilder(directions: directions(), roadData: { _ in
            try? await Task.sleep(for: .milliseconds(400))
            return mapped
        })

        let began = ContinuousClock.now
        let build = try await builder.beginRoutes(waypoints: trip, mode: .drive)
        let waited = ContinuousClock.now - began

        // The route is on screen long before Overpass has said anything.
        #expect(waited < .milliseconds(200))
        #expect(build.primary.polyline.points.count > 1)
        // And it says so rather than pretending the roads are residential.
        #expect(build.primary.metadata.wasFallback)
        #expect(abs(middleLimit(of: build.primary) - RoadClass.residential.defaultLimit) < 0.01)

        let settled = await build.settled()
        #expect(!settled.metadata.wasFallback)
        #expect(abs(middleLimit(of: settled) - Speed.mph(45)) < 0.01)
    }

    @Test func theUpgradeIsTheSameRouteAndTheSameLine() async throws {
        let builder = RouteBuilder(directions: directions(), roadData: { _ in mapped })
        let build = try await builder.beginRoutes(waypoints: trip, mode: .drive)
        let settled = await build.settled()

        // Same identity, so it is swapped in place rather than added beside
        // the route already on screen.
        #expect(settled.id == build.primary.id)
        #expect(settled.polyline.points == build.primary.polyline.points)
        #expect(settled.expectedTravelTime == build.primary.expectedTravelTime)
        #expect(settled.legs == build.primary.legs)
        #expect(settled.waypoints == build.primary.waypoints)
    }

    /// The point of all of it: once the data is there the drive obeys the
    /// posted limit and halts at the stop sign. Speed was never the thing to
    /// trade away.
    @Test func theProfileGainsThePostedLimitAndTheStopWhenTheDataLands() async throws {
        let builder = RouteBuilder(directions: directions(), roadData: { _ in mapped })
        let build = try await builder.beginRoutes(waypoints: trip, mode: .drive)

        let before = build.primary.speedProfile(persona: .normal, seed: 7)
        #expect(before.stops.isEmpty)

        let after = await build.settled().speedProfile(persona: .normal, seed: 7)
        #expect(after.stops.count == 1)
        let halted = try #require(after.stops.first)
        #expect(abs(halted.alongTrack - 3_000) < 40)
        // The posted limit, give or take whatever this driver does over it,
        // rather than the residential default the line started on.
        #expect(after.speed(at: 1_500) > before.speed(at: 1_500))
        #expect(abs(after.speed(at: 1_500) - Speed.mph(45)) < Speed.mph(8))
    }

    @Test func aRouteWhoseDataDidNotArriveAsksAgain() async throws {
        let tally = Tally(failuresLeft: 1)
        let builder = RouteBuilder(directions: directions(), roadData: { _ in
            await tally.next() ? mapped : .empty
        })
        let build = try await builder.beginRoutes(waypoints: trip, mode: .drive)
        let first = await build.settled()
        #expect(first.metadata.wasFallback)

        let again = await build.retryingRoadData(times: 2, delay: .zero)
        #expect(!again.metadata.wasFallback)
        #expect(again.id == build.primary.id)
        #expect(abs(middleLimit(of: again) - Speed.mph(45)) < 0.01)
        #expect(await tally.calls == 2)
    }

    @Test func givingUpIsSaidPlainlyRatherThanDrivenOnQuietly() async throws {
        let tally = Tally(failuresLeft: 99)
        let builder = RouteBuilder(directions: directions(), roadData: { _ in
            _ = await tally.next()
            return .empty
        })
        let build = try await builder.beginRoutes(waypoints: trip, mode: .drive)
        let plan = await build.retryingRoadData(times: 2, delay: .zero)
        #expect(plan.metadata.wasFallback)
        // One pass and two retries, and then it stops asking.
        #expect(await tally.calls == 3)
        // The drive still works, on the road class defaults.
        let profile = plan.speedProfile(persona: .normal, seed: 3)
        #expect(profile.speed(at: 3_000) > 0)
        #expect(abs(profile.speed(at: 3_000) - RoadClass.residential.defaultLimit) < Speed.mph(8))
    }

    @Test func theStartButtonWaitsOnlyForAMoment() async throws {
        let builder = RouteBuilder(directions: directions(), roadData: { _ in
            try? await Task.sleep(for: .seconds(5))
            return mapped
        })
        let build = try await builder.beginRoutes(waypoints: trip, mode: .drive)

        let began = ContinuousClock.now
        let plan = await build.settled(waitingUpTo: 0.15)
        #expect(ContinuousClock.now - began < .milliseconds(900))
        // It goes anyway, on defaults, rather than holding the Start button.
        #expect(plan.metadata.wasFallback)
        #expect(plan.id == build.primary.id)
    }

    @Test func oneRunMeansOneSetOfRequestsHoweverManyAsk() async throws {
        let tally = Tally()
        let builder = RouteBuilder(directions: directions(), roadData: { _ in
            _ = await tally.next()
            try? await Task.sleep(for: .milliseconds(50))
            return mapped
        })
        let build = try await builder.beginRoutes(waypoints: trip, mode: .drive)
        async let a = build.settled()
        async let b = build.settled()
        async let c = build.alternatives()
        _ = await (a, b, c)
        #expect(await tally.calls == 1)
    }
}

// MARK: - Swapping it in

@Suite("Refreshing a route in place")
struct RouteRefreshTests {
    private func plan(_ id: UUID, limit: Double, label: String) -> RoutePlan {
        RoutePlan(
            waypoints: trip,
            polyline: Polyline(points: mainRoad),
            metadata: RoadMetadata(
                segments: [RoadSegment(roadClass: .primary, limit: limit, nodes: mainRoad)],
                controls: [],
                wasFallback: false
            ),
            mode: .drive,
            expectedTravelTime: 420,
            label: label,
            id: id
        )
    }

    @Test func theRouteIsReplacedWithoutMovingTheChoice() {
        let firstID = UUID()
        let secondID = UUID()
        var choice = RouteChoice(
            plans: [plan(firstID, limit: Speed.mph(25), label: "Fastest"),
                    plan(secondID, limit: Speed.mph(25), label: "2 min longer")],
            selectedIndex: 1
        )
        let swapped = choice.refresh(with: plan(firstID, limit: Speed.mph(45), label: ""))
        #expect(swapped)
        #expect(choice.selectedIndex == 1)
        #expect(choice.plans.count == 2)
        #expect(abs((choice.plans[0].metadata.segments.first?.effectiveLimit ?? 0) - Speed.mph(45)) < 0.01)
        // The label says how this route compares with the others, which the
        // road data did not change.
        #expect(choice.plans.map(\.label) == ["Fastest", "2 min longer"])
    }

    @Test func aLateAnswerForARouteNobodyIsOfferingChangesNothing() {
        var choice = RouteChoice(plans: [plan(UUID(), limit: Speed.mph(25), label: "Fastest")])
        let swapped = choice.refresh(with: plan(UUID(), limit: Speed.mph(45), label: "Fastest"))
        #expect(!swapped)
        #expect(abs((choice.plans[0].metadata.segments.first?.effectiveLimit ?? 0) - Speed.mph(25)) < 0.01)
    }
}
