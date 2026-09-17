import Testing
import Foundation
@testable import CloakKit

// MARK: - A small world with three roads between two points

/// Everything the fake map services were asked, in order.
private actor Calls {
    var directions: [(from: Coordinate, to: Coordinate, mode: TravelMode, alternatives: Bool)] = []
    var boxes: [BoundingBox] = []

    func asked(_ from: Coordinate, _ to: Coordinate, _ mode: TravelMode, _ alternatives: Bool) {
        directions.append((from, to, mode, alternatives))
    }

    func fetched(_ box: BoundingBox) {
        boxes.append(box)
    }

    var walks: Int { directions.filter { $0.mode == .walk }.count }
}

/// A line through the corners, with a point every `step` metres.
private func road(_ corners: [Coordinate], step: Double = 50) -> [Coordinate] {
    guard let first = corners.first else { return [] }
    var points = [first]
    for (from, to) in zip(corners, corners.dropFirst()) {
        let length = from.distance(to: to)
        let count = max(1, Int((length / step).rounded(.up)))
        for index in 1...count {
            points.append(from.interpolated(to: to, fraction: Double(index) / Double(count)))
        }
    }
    return points
}

private struct FakeRoute: Sendable {
    var from: Coordinate
    var to: Coordinate
    var mode: TravelMode
    var offers: [RouteBuilder.Offer]
}

/// Apple Maps as a table. Anything walked that is not in the table goes
/// straight there at walking pace; anything driven that is not in it fails.
private func directions(_ table: [FakeRoute], calls: Calls) -> RouteBuilder.Directions {
    { from, to, mode, alternatives in
        await calls.asked(from, to, mode, alternatives)
        if let entry = table.first(where: {
            $0.mode == mode && $0.from.distance(to: from) < 1 && $0.to.distance(to: to) < 1
        }) {
            return alternatives ? entry.offers : Array(entry.offers.prefix(1))
        }
        guard mode != .drive else { throw RouteBuilderError.routingFailed("No road.") }
        return [RouteBuilder.Offer(points: road([from, to], step: 20), travelTime: from.distance(to: to) / 1.4)]
    }
}

/// Overpass as a list: every road with a node in the box, every control in it.
private func roadData(_ segments: [RoadSegment], _ controls: [TrafficControl] = [], calls: Calls) -> RouteBuilder.RoadData {
    { box in
        await calls.fetched(box)
        return RoadMetadata(
            segments: segments.filter { $0.nodes.contains(where: box.contains) },
            controls: controls.filter { box.contains($0.coordinate) },
            wasFallback: false
        )
    }
}

private let home = Coordinate(latitude: 37.0, longitude: -122.0)
private let away = home.moved(bearing: 90, distance: 10_000)

/// Straight along the interstate, a detour north on a slower road, and a
/// longer detour south on a toll road.
private let straight = road([home, away])
private let north = road([home, home.moved(bearing: 0, distance: 2_000), away.moved(bearing: 0, distance: 2_000), away])
private let south = road([home, home.moved(bearing: 180, distance: 1_500), away.moved(bearing: 180, distance: 1_500), away])
private let northSignal = home.moved(bearing: 0, distance: 2_000).interpolated(to: away.moved(bearing: 0, distance: 2_000), fraction: 0.5)

/// The detours as Overpass has them: the long stretch is its own way, and
/// the short roads joining it to either end are others. So the first route's
/// box, which reaches only 120 m either side of the interstate, holds the
/// joining roads but not the detours themselves.
private func ways(_ corners: [Coordinate], limit: Double, roadClass: RoadClass) -> [RoadSegment] {
    [
        RoadSegment(roadClass: .residential, limit: Speed.mph(20), nodes: road([corners[0], corners[1]])),
        RoadSegment(roadClass: roadClass, limit: limit, nodes: road([corners[1], corners[2]])),
        RoadSegment(roadClass: .residential, limit: Speed.mph(20), nodes: road([corners[2], corners[3]]))
    ]
}

private let world = [RoadSegment(roadClass: .motorway, limit: Speed.mph(65), nodes: straight)]
    + ways([home, home.moved(bearing: 0, distance: 2_000), away.moved(bearing: 0, distance: 2_000), away], limit: Speed.mph(30), roadClass: .secondary)
    + ways([home, home.moved(bearing: 180, distance: 1_500), away.moved(bearing: 180, distance: 1_500), away], limit: Speed.mph(45), roadClass: .primary)

private let threeRoutes = [
    RouteBuilder.Offer(points: straight, travelTime: 600, name: "I-35 N"),
    RouteBuilder.Offer(points: north, travelTime: 720, name: "US-183 N"),
    RouteBuilder.Offer(points: south, travelTime: 900, name: "TX-71", advisories: ["Tolls required."])
]

private func stop(_ coordinate: Coordinate, _ title: String, arrival: ArrivalStyle = .automatic) -> RouteWaypoint {
    RouteWaypoint(coordinate: coordinate, title: title, arrival: arrival)
}

private func middleLimit(of plan: RoutePlan) -> Double {
    let dense = plan.polyline.densified(spacing: 5)
    let limits = plan.metadata.limits(along: dense, fallback: .residential)
    return limits[limits.count / 2]
}

// MARK: - Building

@Suite("Route alternatives")
struct RouteAlternativesTests {
    @Test func theFirstRouteIsReadyBeforeTheOthersCostAnything() async throws {
        let calls = Calls()
        let builder = RouteBuilder(
            directions: directions([FakeRoute(from: home, to: away, mode: .drive, offers: threeRoutes)], calls: calls),
            roadData: roadData(world, calls: calls)
        )
        let build = try await builder.buildRoutes(waypoints: [stop(home, "Home"), stop(away, "Away")], mode: .drive)

        #expect(build.hasAlternatives)
        #expect(build.primary.label == RoutePlan.defaultLabel)
        #expect(build.primary.routeName == "I-35 N")
        // One request for the line and one for its road data, exactly as a
        // single route costs.
        #expect(await calls.boxes.count == 1)
        #expect(await calls.directions.count == 1)
        #expect(await calls.directions.first?.alternatives == true)
    }

    @Test func everyOfferedRouteCarriesItsOwnRoadDataAndTime() async throws {
        let calls = Calls()
        let signal = TrafficControl(kind: .signal, coordinate: northSignal, alongTrack: 0)
        let builder = RouteBuilder(
            directions: directions([FakeRoute(from: home, to: away, mode: .drive, offers: threeRoutes)], calls: calls),
            roadData: roadData(world, [signal], calls: calls)
        )
        let build = try await builder.buildRoutes(waypoints: [stop(home, "Home"), stop(away, "Away")], mode: .drive)
        let plans = await build.alternatives()

        #expect(plans.count == 3)
        #expect(plans[0].id == build.primary.id)
        #expect(plans.map(\.expectedTravelTime) == [600, 720, 900])

        // Each line has its own limits: the interstate, the slow road north
        // and the road south. Borrowing the first route's road data would put
        // the north detour on a default limit.
        #expect(abs(middleLimit(of: plans[0]) - Speed.mph(65)) < 0.01)
        #expect(abs(middleLimit(of: plans[1]) - Speed.mph(30)) < 0.01)
        #expect(abs(middleLimit(of: plans[2]) - Speed.mph(45)) < 0.01)

        // And its own controls: the light is on the north road only.
        let controls = plans.map { $0.metadata.snappedControls(to: $0.polyline.densified(spacing: 5)).count }
        #expect(controls == [0, 1, 0])

        // Both detours leave the first route's box, so each asked for its own.
        #expect(await calls.boxes.count == 3)
        // Apple Maps was not asked again.
        #expect(await calls.directions.count == 1)

        #expect(plans.map(\.label) == ["Fastest, via I-35 N", "2 min longer, via US-183 N", "5 min longer, via TX-71, Tolls required"])
    }

    @Test func eachRouteWalksInFromWhereItParks() async throws {
        let calls = Calls()
        let builder = RouteBuilder(
            directions: directions([FakeRoute(from: home, to: away, mode: .drive, offers: threeRoutes)], calls: calls),
            roadData: roadData(world, calls: calls)
        )
        let waypoints = [stop(home, "Home"), stop(away, "Terminal", arrival: .onFoot(metres: 300))]
        let build = try await builder.buildRoutes(waypoints: waypoints, mode: .drive)
        let plans = await build.alternatives()
        #expect(plans.count == 3)

        for (plan, offer) in zip(plans, threeRoutes) {
            let walk = try #require(plan.legs.last)
            #expect(walk.mode == .walk)
            #expect(walk.reason == .askedFor)
            #expect(abs(walk.length - 300) < 5)

            // The time is this route's drive, cut where it parks, plus this
            // route's walk.
            let line = Polyline(points: offer.points)
            let expected = offer.travelTime * (line.length - 300) / line.length + 300 / 1.4
            #expect(abs(plan.expectedTravelTime - expected) < 2)

            // The walk is written into this route's road data, along this line,
            // and it is the only walk there.
            let footways = plan.metadata.segments.filter { $0.roadClass == .footway }
            #expect(footways.count == 1)
            let handover = line.coordinate(at: line.length - 300)
            #expect(try #require(footways.first?.nodes.first).distance(to: handover) < 5)
        }

        // The routes park in different places: west, north and south of the door.
        let handovers = plans.map { $0.polyline.coordinate(at: $0.legs.last!.start) }
        #expect(handovers[0].distance(to: handovers[1]) > 300)
        #expect(handovers[1].distance(to: handovers[2]) > 300)
        // So three different walks were asked for.
        #expect(await calls.walks == 3)
    }

    @Test func routesThatParkInTheSamePlaceShareOneWalk() async throws {
        let calls = Calls()
        // Every route ends on the road 200 m short of the door.
        let kerb = away.moved(bearing: 270, distance: 200)
        let offers = [
            RouteBuilder.Offer(points: road([home, kerb]), travelTime: 600, name: "I-35 N"),
            RouteBuilder.Offer(points: road([home, home.moved(bearing: 0, distance: 2_000), kerb.moved(bearing: 0, distance: 2_000), kerb]), travelTime: 720, name: "US-183 N")
        ]
        let builder = RouteBuilder(
            directions: directions([FakeRoute(from: home, to: away, mode: .drive, offers: offers)], calls: calls),
            roadData: roadData(world, calls: calls)
        )
        let build = try await builder.buildRoutes(waypoints: [stop(home, "Home"), stop(away, "Door")], mode: .drive)
        let plans = await build.alternatives()

        #expect(plans.count == 2)
        #expect(plans.allSatisfy { $0.legs.last?.reason == .noRoadToTheDoor })
        #expect(await calls.walks == 1)
    }

    @Test func aRouteInsideTheFirstRoutesBoxNeedsNoRequestOfItsOwn() async throws {
        let calls = Calls()
        let corner = home.moved(bearing: 0, distance: 5_000)
        let far = corner.moved(bearing: 90, distance: 5_000)
        let bend = home.moved(bearing: 45, distance: 3_000)
        let first = road([home, corner, far])
        let second = road([home, bend, far])
        let builder = RouteBuilder(
            directions: directions([FakeRoute(from: home, to: far, mode: .drive, offers: [
                RouteBuilder.Offer(points: first, travelTime: 700, name: "Main St"),
                RouteBuilder.Offer(points: second, travelTime: 650, name: "Diagonal Ave")
            ])], calls: calls),
            roadData: roadData([
                RoadSegment(roadClass: .primary, limit: Speed.mph(40), nodes: first),
                RoadSegment(roadClass: .tertiary, limit: Speed.mph(25), nodes: second)
            ], calls: calls)
        )
        let build = try await builder.buildRoutes(waypoints: [stop(home, "Home"), stop(far, "Far")], mode: .drive)
        let plans = await build.alternatives()

        #expect(plans.count == 2)
        #expect(await calls.boxes.count == 1)
        // Still resolved along its own line.
        #expect(abs(middleLimit(of: plans[0]) - Speed.mph(40)) < 0.01)
        #expect(abs(middleLimit(of: plans[1]) - Speed.mph(25)) < 0.01)
        #expect(plans.map(\.label) == ["1 min longer, via Main St", "Fastest, via Diagonal Ave"])
    }

    @Test func whenOverpassDidNotAnswerTheOthersDoNotAskAgain() async throws {
        let calls = Calls()
        let builder = RouteBuilder(
            directions: directions([FakeRoute(from: home, to: away, mode: .drive, offers: threeRoutes)], calls: calls),
            roadData: { box in
                await calls.fetched(box)
                return .empty
            }
        )
        let build = try await builder.buildRoutes(waypoints: [stop(home, "Home"), stop(away, "Away")], mode: .drive)
        let plans = await build.alternatives()
        #expect(plans.count == 3)
        #expect(plans.allSatisfy { $0.metadata.wasFallback })
        #expect(await calls.boxes.count == 1)
    }

    @Test func whereTheRoadDataComesFrom() {
        let box = BoundingBox(minLatitude: 37, minLongitude: -122, maxLatitude: 37.1, maxLongitude: -121.9)
        let inside = BoundingBox(minLatitude: 37.01, minLongitude: -121.99, maxLatitude: 37.09, maxLongitude: -121.91)
        let across = BoundingBox(minLatitude: 36.99, minLongitude: -121.99, maxLatitude: 37.09, maxLongitude: -121.91)
        let fetched = RoadMetadata(segments: [], controls: [], wasFallback: false)

        #expect(RouteBuilder.roadDataSource(for: inside, primaryBox: box, primaryRoadData: fetched) == .primaryBox)
        #expect(RouteBuilder.roadDataSource(for: box, primaryBox: box, primaryRoadData: fetched) == .primaryBox)
        #expect(RouteBuilder.roadDataSource(for: across, primaryBox: box, primaryRoadData: fetched) == .fetch)
        #expect(RouteBuilder.roadDataSource(for: inside, primaryBox: box, primaryRoadData: .empty) == .unavailable)
    }

    @Test func aSingleRouteBuildAsksForNoAlternatives() async throws {
        let calls = Calls()
        let builder = RouteBuilder(
            directions: directions([FakeRoute(from: home, to: away, mode: .drive, offers: threeRoutes)], calls: calls),
            roadData: roadData(world, calls: calls)
        )
        let plan = try await builder.build(waypoints: [stop(home, "Home"), stop(away, "Away")], mode: .drive)
        #expect(plan.expectedTravelTime == 600)
        #expect(plan.label == RoutePlan.defaultLabel)
        #expect(await calls.directions.map(\.alternatives) == [false])
    }

    @Test func aWalkIsOfferedItsOtherRoutesToo() async throws {
        let calls = Calls()
        let builder = RouteBuilder(
            directions: directions([FakeRoute(from: home, to: away, mode: .walk, offers: [
                RouteBuilder.Offer(points: straight, travelTime: 7_000),
                RouteBuilder.Offer(points: north, travelTime: 9_900)
            ])], calls: calls),
            roadData: roadData(world, calls: calls)
        )
        let build = try await builder.buildRoutes(waypoints: [stop(home, "Home"), stop(away, "Away")], mode: .walk)
        let plans = await build.alternatives()
        #expect(plans.count == 2)
        #expect(plans.allSatisfy { $0.mode == .walk && $0.legs.isEmpty })
        #expect(plans.map(\.label) == ["Fastest", "48 min longer"])
    }

    // MARK: Several stops

    /// Three legs with three routes each would be 27 combinations. The rule is
    /// that only the longest leg varies, so it is still three routes, and every
    /// other leg is its first route in all of them.
    @Test func aTripWithSeveralStopsVariesOnlyItsLongestLeg() async throws {
        let calls = Calls()
        let first = home.moved(bearing: 90, distance: 3_000)
        let second = first.moved(bearing: 90, distance: 10_000)
        let third = second.moved(bearing: 90, distance: 4_000)
        func three(_ from: Coordinate, _ to: Coordinate, _ names: [String]) -> [RouteBuilder.Offer] {
            [0.0, 800, -800].enumerated().map { index, offset in
                let bend = from.interpolated(to: to, fraction: 0.5).moved(bearing: 0, distance: offset)
                return RouteBuilder.Offer(points: road([from, bend, to]), travelTime: 300 + Double(index) * 120, name: names[index])
            }
        }
        let builder = RouteBuilder(
            directions: directions([
                FakeRoute(from: home, to: first, mode: .drive, offers: three(home, first, ["A1", "A2", "A3"])),
                FakeRoute(from: first, to: second, mode: .drive, offers: three(first, second, ["B1", "B2", "B3"])),
                FakeRoute(from: second, to: third, mode: .drive, offers: three(second, third, ["C1", "C2", "C3"]))
            ], calls: calls),
            roadData: roadData(world, calls: calls)
        )
        let waypoints = [stop(home, "Home"), stop(first, "One"), stop(second, "Two"), stop(third, "Three")]
        let build = try await builder.buildRoutes(waypoints: waypoints, mode: .drive)
        #expect(build.variedLeg == 1)

        let plans = await build.alternatives()
        #expect(plans.count == 3)
        #expect(plans.map(\.routeName) == ["B1", "B2", "B3"])
        #expect(plans.map(\.expectedTravelTime) == [900, 1_020, 1_140])

        // The first and last legs are the same line in every route.
        let firstLeg = three(home, first, ["A1", "A2", "A3"])[0].points
        let lastLeg = three(second, third, ["C1", "C2", "C3"])[0].points
        for plan in plans {
            #expect(plan.polyline.coordinate(at: 1_500).distance(to: Polyline(points: firstLeg).coordinate(at: 1_500)) < 1)
            let fromEnd = plan.polyline.coordinate(at: plan.polyline.length - 1_000)
            let expected = Polyline(points: lastLeg).coordinate(at: Polyline(points: lastLeg).length - 1_000)
            #expect(fromEnd.distance(to: expected) < 1)
        }
        // And the middle leg is not.
        let middles = plans.map { $0.polyline.coordinate(at: 8_000) }
        #expect(middles[0].distance(to: middles[1]) > 500)
        #expect(middles[0].distance(to: middles[2]) > 500)
        #expect(await calls.directions.count == 3)
    }

    @Test func theLongestLegWithAChoiceIsTheOneThatVaries() {
        func leg(_ distance: Double, others: Int, walked: Bool = false) -> RouteBuilder.Leg {
            let offer = RouteBuilder.Offer(points: [home, home.moved(bearing: 90, distance: distance)], travelTime: distance / 20)
            return RouteBuilder.Leg(
                origin: stop(home, "From"),
                destination: stop(home, "To"),
                pieces: [],
                first: walked ? nil : offer,
                others: Array(repeating: offer, count: others)
            )
        }
        #expect(RouteBuilder.variedLeg([leg(2_000, others: 2), leg(9_000, others: 2)]) == 1)
        // The longest leg had only the one route, so the next longest varies.
        #expect(RouteBuilder.variedLeg([leg(2_000, others: 1), leg(9_000, others: 0), leg(1_000, others: 2)]) == 0)
        // A short hop is walked and never varies.
        #expect(RouteBuilder.variedLeg([leg(300, others: 0, walked: true), leg(900, others: 0)]) == nil)
        #expect(RouteBuilder.variedLeg([]) == nil)
    }

    // MARK: - The choice

    private func plan(_ time: TimeInterval, metres: Double = 10_000, name: String = "", advisories: [String] = [], waypoints: [RouteWaypoint] = []) -> RoutePlan {
        RoutePlan(
            waypoints: waypoints,
            polyline: Polyline(points: [home, home.moved(bearing: 90, distance: metres)]),
            metadata: RoadMetadata(),
            mode: .drive,
            expectedTravelTime: time,
            routeName: name,
            advisories: advisories
        )
    }

    @Test func pickingARouteAndChangingTheTrip() {
        let stops = [stop(home, "Home"), stop(away, "Away")]
        let first = plan(600, waypoints: stops)
        var choice = RouteChoice()
        #expect(choice.active == nil)

        choice.begin(with: first)
        #expect(choice.plans.count == 1)
        #expect(choice.active?.id == first.id)

        let all = RouteChoice.labelled([first, plan(700, waypoints: stops), plan(800, waypoints: stops)])
        let filled = choice.complete(with: all)
        #expect(filled)
        #expect(choice.plans.count == 3)
        #expect(choice.selectedIndex == 0)
        #expect(choice.active?.id == first.id)
        #expect(choice.active?.label == "Fastest")

        let pickedThird = choice.select(2, waypoints: stops, mode: .drive)
        #expect(pickedThird)
        #expect(choice.active?.id == all[2].id)
        let pickedAgain = choice.select(2, waypoints: stops, mode: .drive)
        #expect(!pickedAgain)
        let pickedMissing = choice.select(3, waypoints: stops, mode: .drive)
        #expect(!pickedMissing)

        // A regrade keeps every route and the one picked.
        choice.inputsChanged(needsNewRoute: false)
        #expect(choice.plans.count == 3)
        #expect(choice.selectedIndex == 2)
        #expect(choice.active?.id == all[2].id)

        // A new line keeps nothing.
        choice.inputsChanged(needsNewRoute: true)
        #expect(choice.plans.isEmpty)
        #expect(choice.selectedIndex == 0)
        #expect(choice.active == nil)
    }

    @Test func clearingTheStopsClearsTheChoice() {
        let stops = [stop(home, "Home"), stop(away, "Away")]
        var choice = RouteChoice(plans: [plan(600, waypoints: stops), plan(700, waypoints: stops)], selectedIndex: 1)
        #expect(choice.selectedIndex == 1)
        choice.clear()
        #expect(choice.plans.isEmpty)
        #expect(choice.selectedIndex == 0)
    }

    @Test func aRouteForOtherStopsCannotBePicked() {
        let stops = [stop(home, "Home"), stop(away, "Away")]
        var choice = RouteChoice(plans: [plan(600, waypoints: stops), plan(700, waypoints: stops)])

        var moved = stops
        moved[1].coordinate = away.moved(bearing: 0, distance: 500)
        let pickedMoved = choice.select(1, waypoints: moved, mode: .drive)
        #expect(!pickedMoved)
        let pickedWalk = choice.select(1, waypoints: stops, mode: .walk)
        #expect(!pickedWalk)
        let pickedOtherStops = choice.select(1, waypoints: [stop(home, "Home"), stop(away, "Away")], mode: .drive)
        #expect(!pickedOtherStops)

        // Renaming a stop does not move the line.
        var renamed = stops
        renamed[1].title = "Work"
        let pickedRenamed = choice.select(1, waypoints: renamed, mode: .drive)
        #expect(pickedRenamed)
    }

    @Test func aLateAnswerDoesNotOverwriteANewerBuild() {
        let older = plan(600)
        let newer = plan(650)
        var choice = RouteChoice()
        choice.begin(with: newer)
        let tookOlder = choice.complete(with: [older, plan(700)])
        #expect(!tookOlder)
        #expect(choice.plans.count == 1)
        #expect(choice.active?.id == newer.id)

        // Nor does a second answer for the same build once the first is in.
        let tookNewer = choice.complete(with: [newer, plan(700)])
        #expect(tookNewer)
        let tookTwice = choice.complete(with: [newer, plan(710), plan(720)])
        #expect(!tookTwice)
        #expect(choice.plans.count == 2)

        // Out of range selections fall back to the first route.
        #expect(RouteChoice(plans: [older], selectedIndex: 4).selectedIndex == 0)
    }

    // MARK: Labels

    @Test func labelsSayWhichIsFastestAndHowTheOthersDiffer() {
        #expect(RouteChoice.labels(for: [plan(600, name: "I-35 N"), plan(740, name: "US-183 N")])
            == ["Fastest, via I-35 N", "2 min longer, via US-183 N"])

        // The same name on every route tells none of them apart.
        #expect(RouteChoice.labels(for: [plan(600, name: "I-35 N"), plan(900, name: "I-35 N")])
            == ["Fastest", "5 min longer"])

        // Apple Maps' first choice is not always the fastest.
        #expect(RouteChoice.labels(for: [plan(780), plan(600)]) == ["3 min longer", "Fastest"])

        // Within a minute, the distance says how they differ.
        #expect(RouteChoice.labels(for: [plan(600, metres: 10_000), plan(620, metres: 9_000)])
            == ["Fastest", "About the same time, 0.6 mi shorter"])
        #expect(RouteChoice.labels(for: [plan(600, metres: 10_000), plan(610, metres: 10_050)])
            == ["Fastest", "About the same time"])

        #expect(RouteChoice.labels(for: [plan(600), plan(600 + 75 * 60)]) == ["Fastest", "1h 15m longer"])
        #expect(RouteChoice.labels(for: [plan(600), plan(600 + 120 * 60)]) == ["Fastest", "2h longer"])

        // One route on its own is not "fastest" of anything.
        #expect(RouteChoice.labels(for: [plan(600, name: "I-35 N")]) == [RoutePlan.defaultLabel])
        #expect(RouteChoice.labels(for: []).isEmpty)
    }

    @Test func aNoticeIsShownOnlyWhereItTellsRoutesApart() {
        let labels = RouteChoice.labels(for: [
            plan(600, name: "SR-130", advisories: ["Tolls required.", "Restricted usage road"]),
            plan(700, name: "I-35 N", advisories: ["Restricted usage road"]),
            plan(710, name: "FM 973 \u{2014} Loop", advisories: ["Restricted usage road", "  Seasonal closure \u{2014} check  "])
        ])
        #expect(labels == [
            "Fastest, via SR-130, Tolls required",
            "2 min longer, via I-35 N",
            "2 min longer, via FM 973 - Loop, Seasonal closure - check"
        ])
        #expect(labels.allSatisfy { !$0.contains("\u{2014}") && !$0.contains("\u{2013}") })
    }
}
