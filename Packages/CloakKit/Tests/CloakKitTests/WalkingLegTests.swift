import Testing
import Foundation
@testable import CloakKit

/// A straight line running north, densified the way the engine gets it.
private func straightLine(meters: Double, spacing: Double = 4) -> Polyline {
    let start = Coordinate(latitude: 37.0, longitude: -122.0)
    let end = start.moved(bearing: 0, distance: meters)
    return Polyline(points: [start, end]).densified(spacing: spacing)
}

/// Driving limits everywhere except the named stretch, which is a footway.
private func limits(
    on line: Polyline,
    road: Double = Speed.mph(35),
    footwayFrom: Double,
    to end: Double = .greatestFiniteMagnitude
) -> [Double] {
    line.points.indices.map { index in
        let along = line.cumulative[index]
        return (along >= footwayFrom && along <= end) ? RoadClass.footway.defaultLimit : road
    }
}

@Suite("Walking legs")
struct WalkingLegTests {
    @Test func aFootwayAtTheEndOfADriveBecomesAWalk() {
        let line = straightLine(meters: 2500)
        let modes = WalkingLegs.modes(
            polyline: line,
            postedLimits: limits(on: line, footwayFrom: 2200),
            requested: .drive
        )
        #expect(modes.first == .drive)
        #expect(modes.last == .walk)

        let spans = WalkingLegs.spans(polyline: line, modes: modes)
        #expect(spans.count == 2)
        #expect(spans[0].mode == .drive)
        #expect(spans[1].mode == .walk)
        #expect(abs(spans[1].start - 2200) < 10)
        #expect(abs(WalkingLegs.walkingDistance(polyline: line, modes: modes) - 300) < 15)
    }

    /// A route that clips the corner of a plaza picks up a handful of footway
    /// points. Changing mode for eight metres would read as a stutter, not a
    /// walk.
    @Test func aFewMetresOfFootwayIsMapNoiseNotAWalk() {
        let line = straightLine(meters: 2000)
        let modes = WalkingLegs.modes(
            polyline: line,
            postedLimits: limits(on: line, footwayFrom: 900, to: 908),
            requested: .drive
        )
        #expect(modes.allSatisfy { $0 == .drive })
    }

    /// The map losing the footway for twenty metres in the middle of a walk is
    /// a hole in the data, not twenty metres of driving.
    @Test func aHoleInTheFootwayDoesNotSplitTheWalkInTwo() {
        let line = straightLine(meters: 1500)
        var posted = limits(on: line, footwayFrom: 1100, to: 1200)
        for index in line.points.indices where line.cumulative[index] > 1220 && line.cumulative[index] <= 1400 {
            posted[index] = RoadClass.footway.defaultLimit
        }
        let modes = WalkingLegs.modes(polyline: line, postedLimits: posted, requested: .drive)
        let spans = WalkingLegs.spans(polyline: line, modes: modes)
        #expect(spans.filter { $0.mode == .walk }.count == 1)
        #expect(spans.map(\.mode) == [.drive, .walk, .drive])
        #expect(abs((spans.first { $0.mode == .walk }?.length ?? 0) - 300) < 20)
    }

    /// A pavement mapped alongside the road can measure nearer to the route
    /// line than the carriageway does, and then the road data says footway in
    /// the middle of a perfectly ordinary drive. Parking the car for a
    /// hundred metres of that would be worse than ignoring it.
    @Test func aPavementsWorthOfFootwayInTheMiddleOfADriveIsIgnored() {
        let line = straightLine(meters: 3000)
        let modes = WalkingLegs.modes(
            polyline: line,
            postedLimits: limits(on: line, footwayFrom: 1400, to: 1480),
            requested: .drive
        )
        #expect(modes.allSatisfy { $0 == .drive })

        // A genuine errand in the middle is still a walk.
        let longer = WalkingLegs.modes(
            polyline: line,
            postedLimits: limits(on: line, footwayFrom: 1400, to: 1700),
            requested: .drive
        )
        #expect(longer.contains(.walk))
        #expect(WalkingLegs.spans(polyline: line, modes: longer).map(\.mode) == [.drive, .walk, .drive])
    }

    /// The walk at the end of a leg is the one the builder put there, and it
    /// is allowed to be short.
    @Test func aShortWalkAtTheEndOfTheRouteIsKept() {
        let line = straightLine(meters: 3000)
        let modes = WalkingLegs.modes(
            polyline: line,
            postedLimits: limits(on: line, footwayFrom: 2940),
            requested: .drive
        )
        #expect(modes.last == .walk)
        #expect(modes.first == .drive)
    }

    @Test func aTripAskedForOnFootStaysOnFootThroughout() {
        let line = straightLine(meters: 3000)
        let posted = Array(repeating: Speed.mph(35), count: line.points.count)
        let modes = WalkingLegs.modes(polyline: line, postedLimits: posted, requested: .walk)
        #expect(modes.allSatisfy { $0 == .walk })
    }

    /// Nobody drives a hundred metres, whatever the line says it is.
    @Test func aLineTooShortToDriveIsWalked() {
        let line = straightLine(meters: 120)
        let posted = Array(repeating: Speed.mph(35), count: line.points.count)
        let modes = WalkingLegs.modes(polyline: line, postedLimits: posted, requested: .drive)
        #expect(modes.allSatisfy { $0 == .walk })
    }

    /// The divider between a way with a car on it and one without. Nothing
    /// drivable is posted in the gap.
    @Test func theNotDrivableCeilingSitsBetweenTheTwoKinds() {
        #expect(RoadClass.footway.defaultLimit <= WalkingLegs.notDrivableCeiling)
        #expect(MaxSpeedParser.parse("walk")! <= WalkingLegs.notDrivableCeiling)
        for slow in [RoadClass.service, .living, .residential, .tertiary] {
            #expect(slow.defaultLimit > WalkingLegs.notDrivableCeiling)
        }
    }
}

@Suite("Walking motion")
struct WalkingMotionTests {
    private func walkProfile(meters: Double, controls: [TrafficControl] = [], seed: UInt64 = 5) -> SpeedProfile {
        let line = straightLine(meters: meters)
        return SpeedProfileBuilder.build(
            polyline: line,
            postedLimits: Array(repeating: RoadClass.footway.defaultLimit, count: line.points.count),
            controls: controls,
            persona: .normal,
            mode: .drive,
            seed: seed
        )
    }

    private func mixedProfile(seed: UInt64 = 42, controls: [TrafficControl] = []) -> SpeedProfile {
        let line = straightLine(meters: 2500)
        return SpeedProfileBuilder.build(
            polyline: line,
            postedLimits: limits(on: line, footwayFrom: 2200),
            controls: controls,
            persona: .normal,
            mode: .drive,
            seed: seed
        )
    }

    private func run(_ profile: SpeedProfile, persona: DriverPersona = .normal, seed: UInt64 = 42, limit: Int = 4000)
        -> [(distance: Double, fix: SimulatedFix)] {
        var engine = MotionEngine(profile: profile, persona: persona, mode: .drive, seed: seed)
        var output: [(Double, SimulatedFix)] = []
        var steps = 0
        while !engine.state.finished, steps < limit {
            let fix = engine.step(deltaTime: 1)
            output.append((engine.state.distance, fix))
            steps += 1
        }
        return output.map { (distance: $0.0, fix: $0.1) }
    }

    /// The complaint, as a test. A walking stretch must never report or cover
    /// ground at anything a person would call driving.
    @Test func aWalkNeverReadsAsDriving() {
        let profile = walkProfile(meters: 600)
        #expect(profile.mode(at: 300) == .walk)

        let trace = run(profile)
        #expect(trace.count > 300)

        let cruising = trace.filter { $0.distance > 20 && $0.distance < 560 }
        #expect(!cruising.isEmpty)
        for sample in cruising {
            #expect(sample.fix.speed > 1.0)
            #expect(sample.fix.speed < 1.6)
        }

        // iOS throws the speed field away for a simulated fix, so the only
        // thing anything else can read is how far the position moved. That is
        // the number that has to be a walk.
        let ground = zip(trace, trace.dropFirst()).map { $0.fix.coordinate.distance(to: $1.fix.coordinate) }
        #expect(ground.max()! < 1.7)
        let mean = ground.reduce(0, +) / Double(ground.count)
        #expect(mean > 1.05 && mean < 1.5)
    }

    /// One route, two modes, each at its own pace.
    @Test func theDrivenPartDrivesAndTheWalkedPartWalks() {
        let profile = mixedProfile()
        #expect(profile.mode(at: 500) == .drive)
        #expect(profile.mode(at: 2400) == .walk)
        #expect(abs(profile.walkingDistance - 300) < 15)

        let trace = run(profile)
        let driving = trace.filter { $0.distance > 400 && $0.distance < 1800 }
        let walking = trace.filter { $0.distance > 2260 && $0.distance < 2460 }
        #expect(!driving.isEmpty)
        #expect(!walking.isEmpty)
        #expect(driving.map(\.fix.speed).min()! > Speed.mph(25))
        #expect(walking.map(\.fix.speed).max()! < 1.6)
    }

    /// Nothing steps from driving speed to walking speed, and nothing jumps
    /// across the ground to get there.
    @Test func theChangeOfModeIsContinuous() {
        for seed in UInt64(1)...6 {
            let profile = mixedProfile(seed: seed)
            let trace = run(profile, seed: seed)
            let speeds = trace.map(\.fix.speed)
            let steps = zip(speeds, speeds.dropFirst()).map { abs($1 - $0) }
            #expect(steps.max()! < 4.0)

            let ground = zip(trace, trace.dropFirst()).map { $0.fix.coordinate.distance(to: $1.fix.coordinate) }
            // A second of the fastest thing on this route, with room for noise.
            #expect(ground.max()! < 25)
        }
    }

    /// A drive does not become a walk while still rolling. The car parks.
    @Test func theCarStopsWhereTheWalkBegins() {
        let profile = mixedProfile()
        let seam = profile.spans.first { $0.mode == .walk }?.start ?? 0
        #expect(seam > 0)
        let handover = profile.stops.first { abs($0.alongTrack - seam) < 12 }
        #expect(handover != nil)
        #expect(handover?.kind == .stop)
        #expect((handover?.dwell ?? 0) >= SpeedProfileBuilder.parkingDwell.lowerBound)
    }

    /// On foot there are no lights to obey, and the one thing that does stop a
    /// person stops them for a fraction of a phase.
    @Test func aWalkObeysNoLightsAndWaitsBriefly() {
        let line = straightLine(meters: 600)
        let controls = [
            TrafficControl(kind: .signal, coordinate: line.coordinate(at: 200), alongTrack: 200, isSignalled: true),
            TrafficControl(kind: .stop, coordinate: line.coordinate(at: 300), alongTrack: 300),
            TrafficControl(kind: .crossing, coordinate: line.coordinate(at: 400), alongTrack: 400, isSignalled: true)
        ]
        var sawACrossing = false
        for seed in UInt64(1)...25 {
            let profile = SpeedProfileBuilder.build(
                polyline: line,
                postedLimits: Array(repeating: RoadClass.footway.defaultLimit, count: line.points.count),
                controls: controls,
                persona: .normal,
                mode: .drive,
                seed: seed
            )
            #expect(profile.stops.allSatisfy { $0.kind == .crossing })
            for stop in profile.stops {
                sawACrossing = true
                #expect(stop.dwell <= TravelMode.walk.stopDwellRange.upperBound)
                #expect(stop.dwell < DriverPersona.normal.signalDwellRange.upperBound)
            }
        }
        #expect(sawACrossing)
    }

    /// Feet turn on the spot. A path bending round a building used to drop the
    /// walk to a crawl because it was being held to a car's cornering limit.
    @Test func aBendInTheFootpathDoesNotSlowTheWalk() {
        var points: [Coordinate] = []
        var cursor = Coordinate(latitude: 37.0, longitude: -122.0)
        var heading = 90.0
        for step in 0..<150 {
            points.append(cursor)
            cursor = cursor.moved(bearing: heading, distance: 2)
            if step > 60 && step < 80 { heading -= 4 }
        }
        let line = Polyline(points: points)
        let profile = SpeedProfileBuilder.build(
            polyline: line,
            postedLimits: Array(repeating: RoadClass.footway.defaultLimit, count: line.points.count),
            controls: [],
            persona: .normal,
            mode: .drive,
            seed: 3
        )
        let throughTheBend = line.points.indices
            .filter { line.cumulative[$0] > 130 && line.cumulative[$0] < 155 }
            .map { profile.ceiling[$0] }
        #expect(throughTheBend.min()! > 1.1)
    }

    @Test func everyMixedRouteStillReachesTheEnd() {
        for seed in UInt64(1)...8 {
            let profile = mixedProfile(seed: seed)
            var engine = MotionEngine(profile: profile, persona: .cautious, mode: .drive, seed: seed)
            var steps = 0
            while !engine.state.finished, steps < 6000 {
                _ = engine.step(deltaTime: 1)
                steps += 1
            }
            #expect(engine.state.finished)
        }
    }

    /// A walk that is not driving must not be timed as one either.
    @Test func theTimeLeftOnAWalkIsTimedAtWalkingPace() {
        let profile = walkProfile(meters: 600)
        var engine = MotionEngine(profile: profile, persona: .normal, mode: .drive, seed: 9)
        for _ in 0..<10 { _ = engine.step(deltaTime: 1) }
        let remaining = engine.remainingTime ?? 0
        // Roughly 590 m at about 1.3 m/s. A drive's floor of 8 mph would have
        // said three minutes.
        #expect(remaining > 330)
        #expect(remaining < 700)
    }

    @Test func mixedRoutesAreStillRepeatable() {
        func trace() -> [Double] {
            let profile = mixedProfile(seed: 77)
            return run(profile, seed: 77).map(\.fix.speed)
        }
        #expect(trace() == trace())
    }
}

@Suite("Last mile")
struct LastMileTests {
    @Test func aCarStoppingShortOfTheDoorHandsOverToFeet() {
        #expect(!LastMile.walksIn(gap: 10))
        #expect(!LastMile.walksIn(gap: LastMile.drivableGap))
        #expect(LastMile.walksIn(gap: 250))
        #expect(LastMile.walksIn(gap: LastMile.longestWalkIn))
        // Past that it is not the walk to the door, it is another trip.
        #expect(!LastMile.walksIn(gap: 4_000))
    }

    @Test func aWalkThatGoesTheLongWayRoundIsNotTheWalkToTheDoor() {
        #expect(LastMile.accepts(walkLength: 260, gap: 250))
        #expect(LastMile.accepts(walkLength: 120, gap: 60))
        #expect(!LastMile.accepts(walkLength: 2_000, gap: 200))
        #expect(!LastMile.accepts(walkLength: 0, gap: 200))
    }

    @Test func aShortHopIsWalked() {
        #expect(LastMile.isShortHop(120))
        #expect(LastMile.isShortHop(LastMile.shortHop))
        #expect(!LastMile.isShortHop(LastMile.shortHop + 1))
        #expect(!LastMile.isShortHop(0))
    }

    /// The decision has to survive the trip across to the simulation, which
    /// rebuilds the profile from the points and their posted limits and
    /// nothing else. Writing the walked stretch into the road data as the
    /// footway it is carries it.
    @Test func aWalkedStretchReadsBackAsAWalkFromTheRoadDataAlone() {
        let line = straightLine(meters: 2000, spacing: 4)
        let road = RoadSegment(
            roadClass: .secondary,
            limit: Speed.mph(35),
            nodes: [line.points.first!, line.points.last!]
        )
        let metadata = LastMile.describing(
            RoadMetadata(segments: [road], controls: []),
            walked: [1_750...line.length],
            along: line
        )

        let posted = metadata.limits(along: line, fallback: .residential)
        let modes = WalkingLegs.modes(polyline: line, postedLimits: posted, requested: .drive)
        #expect(modes.last == .walk)
        #expect(modes.first == .drive)
        let walked = WalkingLegs.walkingDistance(polyline: line, modes: modes)
        // The stretch itself, give or take the forty metre reach of the limit
        // lookup either side of it.
        #expect(walked > 240 && walked < 340)
    }

    @Test func footwaysAreLaidAlongTheLineTheyDescribe() {
        let line = straightLine(meters: 500)
        let ways = LastMile.footways(along: line, spans: [200...300], spacing: 8)
        #expect(ways.count == 1)
        #expect(ways[0].roadClass == .footway)
        #expect(ways[0].effectiveLimit == RoadClass.footway.defaultLimit)
        let laid = Polyline(points: ways[0].nodes)
        #expect(abs(laid.length - 100) < 2)
        for node in ways[0].nodes {
            #expect(line.nearestDistance(to: node).offset < 1)
        }
    }
}

@Suite("Route shaping")
struct RouteShapingTests {
    private func line(from start: Coordinate, bearing: Double, metres: Double, step: Double = 10) -> [Coordinate] {
        var points: [Coordinate] = []
        var along = 0.0
        while along <= metres {
            points.append(start.moved(bearing: bearing, distance: along))
            along += step
        }
        return points
    }

    /// The trip to a terminal: the car gets as far as the road goes, then the
    /// rest is on foot. The two pieces must come out as one unbroken line with
    /// the walk recorded at the end of it.
    @Test func aRouteEndingAtATerminalArrivesOnFoot() {
        let kerb = Coordinate(latitude: 37.0, longitude: -122.0)
        let drive = line(from: kerb.moved(bearing: 180, distance: 3_000), bearing: 0, metres: 3_000)
        let walk = line(from: drive.last!, bearing: 0, metres: 260)

        let (polyline, legs, _) = RouteBuilder.stitch([
            RouteBuilder.Piece(mode: .drive, points: drive, travelTime: 300, reason: .requested),
            RouteBuilder.Piece(mode: .walk, points: walk, travelTime: 200, reason: .noRoadToTheDoor)
        ])

        // One line, no doubled point where the pieces meet.
        #expect(abs(polyline.length - 3_260) < 5)
        #expect(legs.count == 2)
        #expect(legs[1].mode == .walk)
        #expect(legs[1].reason == .noRoadToTheDoor)
        #expect(abs(legs[1].length - 260) < 5)
        #expect(!legs[1].note.contains("\u{2014}"))

        // And the decision survives into the profile the simulation rebuilds.
        let metadata = LastMile.describing(
            RoadMetadata(segments: [
                RoadSegment(roadClass: .secondary, limit: Speed.mph(40), nodes: [drive.first!, drive.last!])
            ], controls: []),
            walked: legs.filter(\.mode.isOnFoot).map { $0.start...$0.end },
            along: polyline
        )

        let dense = polyline.densified(spacing: 4)
        let profile = SpeedProfileBuilder.build(
            polyline: dense,
            postedLimits: metadata.limits(along: dense, fallback: .residential),
            controls: metadata.snappedControls(to: dense),
            persona: .normal,
            mode: .drive,
            seed: 31
        )
        #expect(profile.mode(at: dense.length - 50) == .walk)
        #expect(profile.walkingDistance > 200)

        var engine = MotionEngine(profile: profile, persona: .normal, mode: .drive, seed: 31)
        var arrivalSpeeds: [Double] = []
        var steps = 0
        while !engine.state.finished, steps < 6_000 {
            let fix = engine.step(deltaTime: 1)
            if engine.state.distance > dense.length - 150 { arrivalSpeeds.append(fix.speed) }
            steps += 1
        }
        #expect(engine.state.finished)
        #expect(!arrivalSpeeds.isEmpty)
        // It arrives at the terminal on foot, not at 25 m/s.
        #expect(arrivalSpeeds.max()! < 1.6)
    }

    @Test func stitchingKeepsOnePointWhereThePiecesMeet() {
        let start = Coordinate(latitude: 37.0, longitude: -122.0)
        let first = line(from: start, bearing: 90, metres: 200)
        let second = line(from: first.last!, bearing: 90, metres: 200)
        let (polyline, _, time) = RouteBuilder.stitch([
            RouteBuilder.Piece(mode: .drive, points: first, travelTime: 30, reason: .requested),
            RouteBuilder.Piece(mode: .drive, points: second, travelTime: 40, reason: .requested)
        ])
        #expect(polyline.points.count == first.count + second.count - 1)
        #expect(abs(polyline.length - 400) < 2)
        #expect(time == 70)
    }

    /// One stretch in the mode that was asked for needs no explaining.
    @Test func aPlainDriveHasNoLegsToDescribe() {
        let start = Coordinate(latitude: 37.0, longitude: -122.0)
        let (_, legs, _) = RouteBuilder.stitch([
            RouteBuilder.Piece(mode: .drive, points: line(from: start, bearing: 0, metres: 900), travelTime: 90, reason: .requested)
        ])
        #expect(legs.isEmpty)
    }

    @Test func parkingTheStatedDistanceOutCutsTheDriveThere() {
        let start = Coordinate(latitude: 37.0, longitude: -122.0)
        let points = line(from: start, bearing: 0, metres: 1_000)
        let cut = RouteBuilder.prefix(of: points, upTo: 750)
        #expect(abs(Polyline(points: cut).length - 750) < 1)
        #expect(cut.count < points.count)
        #expect(RouteBuilder.prefix(of: points, upTo: 5_000).count == points.count)
    }

    /// Waypoints saved before arrival styles existed still load.
    @Test func anOlderSavedWaypointStillDecodes() throws {
        let json = """
        {"id":"7B1F1B0E-6F0E-4B1B-9F0E-6F0E4B1B9F0E",
         "coordinate":{"latitude":37.0,"longitude":-122.0},
         "title":"Home"}
        """
        let waypoint = try JSONDecoder().decode(RouteWaypoint.self, from: Data(json.utf8))
        #expect(waypoint.title == "Home")
        #expect(waypoint.arrival == .automatic)

        let round = try JSONDecoder().decode(
            RouteWaypoint.self,
            from: try JSONEncoder().encode(RouteWaypoint(coordinate: .init(latitude: 1, longitude: 2), title: "Gate", arrival: .onFoot(metres: 240)))
        )
        #expect(round.arrival == .onFoot(metres: 240))
    }
}

@Suite("On foot")
struct OnFootTests {
    /// The pace a person actually walks. The band used to top out at a march.
    @Test func theWalkingBandIsAWalk() {
        #expect(TravelMode.walk.speedBand.lowerBound >= 1.05)
        #expect(TravelMode.walk.speedBand.upperBound <= 1.5)
        #expect(TravelMode.walk.cruisingSpeed > 1.1)
        #expect(TravelMode.walk.cruisingSpeed < 1.5)
        #expect(TravelMode.walk.isOnFoot)
        #expect(TravelMode.run.isOnFoot)
        #expect(!TravelMode.drive.isOnFoot)
        #expect(TravelMode.walk.cutsCorners)
        #expect(!TravelMode.drive.cutsCorners)
        #expect(!TravelMode.walk.obeysTrafficControl)
    }

    /// Feet are not a car with the numbers turned down a little.
    @Test func feetStartAndStopInAboutAMetre() {
        let walker = DriverPersona.normal.moving(as: .walk)
        #expect(walker.acceleration < 1.0)
        #expect(walker.braking < 1.5)
        #expect(walker.speedNoise < DriverPersona.normal.speedNoise)
        #expect(walker.redLightProbability == 0)
        // A drive is still the persona that was picked for it.
        #expect(DriverPersona.assertive.moving(as: .drive) == .assertive)
        // And the walker is not something the picker can land on by accident.
        #expect(!DriverPersona.all.contains(DriverPersona.onFoot))
        #expect(DriverPersona.named("on-foot") == .normal)
    }
}

@Suite("Road data under a walk")
struct WalkCorridorTests {
    private func line(meters: Double) -> Polyline {
        let start = Coordinate(latitude: 37.0, longitude: -122.0)
        return Polyline(points: [start, start.moved(bearing: 0, distance: meters)]).densified(spacing: 4)
    }

    /// A drivable road drawn along the same ground as the walk would otherwise
    /// win the limit lookup by a rounding error. A stretch the car route
    /// refused to use is not a drivable road for this trip.
    @Test func aRoadRunningAlongTheWalkIsTakenOutOfIt() {
        let route = line(meters: 2000)
        let road = RoadSegment(
            roadClass: .secondary,
            limit: Speed.mph(40),
            nodes: [route.points.first!, route.points.last!]
        )
        let cleared = LastMile.clearing([road], along: route, spans: [1_700...route.length])
        #expect(!cleared.isEmpty)
        for segment in cleared {
            for node in segment.nodes {
                #expect(route.nearestDistance(to: node).alongTrack < 1_700 + 5)
            }
        }
        // The rest of the road is still there to give the drive its limit.
        #expect(cleared.contains { Polyline(points: $0.nodes).length > 1_000 })
    }

    /// A road that merely crosses the walk keeps everything beyond the strip
    /// the walk is on, so a later drive along it still knows its limit.
    @Test func aRoadThatOnlyCrossesTheWalkKeepsItsFarEnds() {
        let route = line(meters: 1000)
        let crossing = route.coordinate(at: 900)
        let side = RoadSegment(roadClass: .residential, limit: Speed.mph(25), nodes: [
            crossing.moved(bearing: 270, distance: 300),
            crossing,
            crossing.moved(bearing: 90, distance: 300)
        ])
        let cleared = LastMile.clearing([side], along: route, spans: [850...route.length])
        #expect(cleared.count == 2)
        for segment in cleared {
            #expect(Polyline(points: segment.nodes).length > 250)
            #expect(segment.limit == Speed.mph(25))
        }
    }

    @Test func aRouteWithNoWalkIsLeftAlone() {
        let route = line(meters: 800)
        let metadata = RoadMetadata(segments: [
            RoadSegment(roadClass: .primary, limit: Speed.mph(45), nodes: route.points)
        ], controls: [])
        let described = LastMile.describing(metadata, walked: [], along: route)
        #expect(described.segments.count == 1)
        #expect(described.segments[0].roadClass == .primary)
    }
}

@Suite("Mixed route behaviour")
struct MixedRouteTests {
    private func straight(_ meters: Double) -> Polyline {
        let start = Coordinate(latitude: 37.0, longitude: -122.0)
        return Polyline(points: [start, start.moved(bearing: 0, distance: meters)]).densified(spacing: 4)
    }

    /// Nothing about a plain drive changes. No walking, no extra halts.
    @Test func aPlainDriveIsStillAPlainDrive() {
        let line = straight(2000)
        let stopSign = TrafficControl(kind: .stop, coordinate: line.coordinate(at: 900), alongTrack: 900)
        let profile = SpeedProfileBuilder.build(
            polyline: line,
            postedLimits: Array(repeating: Speed.mph(35), count: line.points.count),
            controls: [stopSign],
            persona: .normal,
            mode: .drive,
            seed: 13
        )
        #expect(profile.modes.allSatisfy { $0 == .drive })
        #expect(profile.walkingDistance == 0)
        #expect(profile.stops.count == 1)
        #expect(abs(profile.stops[0].alongTrack - 900) < 1)
        #expect(profile.stops[0].dwell <= DriverPersona.normal.stopSignDwellRange.upperBound)
        #expect(Speed.toMph(profile.ceiling[100]) > 35)
    }

    /// Out of the terminal on foot, then into the car.
    @Test func aWalkAtTheStartHandsOverToTheCar() {
        let line = straight(2500)
        let posted = line.points.indices.map { index in
            line.cumulative[index] < 300 ? RoadClass.footway.defaultLimit : Speed.mph(35)
        }
        let profile = SpeedProfileBuilder.build(
            polyline: line,
            postedLimits: posted,
            controls: [],
            persona: .normal,
            mode: .drive,
            seed: 17
        )
        #expect(profile.mode(at: 100) == .walk)
        #expect(profile.mode(at: 1_000) == .drive)

        let seam = profile.spans.first { $0.mode == .drive }?.start ?? 0
        #expect(abs(seam - 300) < 12)
        let handover = profile.stops.first { abs($0.alongTrack - seam) < 12 }
        #expect(handover != nil)
        #expect((handover?.dwell ?? 0) <= SpeedProfileBuilder.boardingDwell.upperBound)

        var engine = MotionEngine(profile: profile, persona: .normal, mode: .drive, seed: 17)
        var onFoot: [Double] = []
        var driving: [Double] = []
        var steps = 0
        while !engine.state.finished, steps < 6_000 {
            let fix = engine.step(deltaTime: 1)
            if engine.state.distance > 30, engine.state.distance < 270 { onFoot.append(fix.speed) }
            if engine.state.distance > 700, engine.state.distance < 2_000 { driving.append(fix.speed) }
            steps += 1
        }
        #expect(engine.state.finished)
        #expect(onFoot.max()! < 1.6)
        #expect(driving.min()! > Speed.mph(25))
    }

    /// The seam is an actual halt in the trace, not just a number in the plan.
    @Test func theEngineComesToRestWhereTheModeChanges() {
        let line = straight(2500)
        let posted = line.points.indices.map { index in
            line.cumulative[index] > 2_200 ? RoadClass.footway.defaultLimit : Speed.mph(35)
        }
        let profile = SpeedProfileBuilder.build(
            polyline: line, postedLimits: posted, controls: [], persona: .normal, mode: .drive, seed: 23
        )
        let seam = profile.spans.first { $0.mode == .walk }?.start ?? 0

        var engine = MotionEngine(profile: profile, persona: .normal, mode: .drive, seed: 23)
        var restedAt: Double?
        var steps = 0
        while !engine.state.finished, steps < 6_000 {
            _ = engine.step(deltaTime: 1)
            if engine.state.stopsMade == 1, restedAt == nil, engine.state.speed == 0 {
                restedAt = engine.state.distance
            }
            steps += 1
        }
        #expect(engine.state.finished)
        #expect(engine.state.stopsMade == 1)
        guard let restedAt else { Issue.record("the car never parked"); return }
        #expect(abs(restedAt - seam) < 15)
    }

    /// A drive with a walk at the end still starts cleanly, which is what the
    /// family apps measure before they will call it a drive at all.
    @Test func theCleanStartIsMeasuredFromWhereTheDriveBegins() {
        let line = straight(4_000)
        let posted = line.points.indices.map { index in
            line.cumulative[index] < 300 ? RoadClass.footway.defaultLimit : Speed.mph(35)
        }
        let controls = stride(from: 400.0, to: 3_800, by: 200).map { along in
            TrafficControl(kind: .signal, coordinate: line.coordinate(at: along), alongTrack: along, isSignalled: true)
        }
        let profile = SpeedProfileBuilder.build(
            polyline: line, postedLimits: posted, controls: controls, persona: .normal, mode: .drive, seed: 29
        )
        let driveStarts = profile.spans.first { $0.mode == .drive }?.start ?? 0
        let signals = profile.stops.filter { $0.kind == .signal }
        #expect(!signals.isEmpty)
        #expect(signals.allSatisfy { $0.alongTrack >= driveStarts + SpeedProfile.cleanStartDistance })
    }
}
