import Testing
import Foundation
@testable import CloakKit

// MARK: - Helpers

private let downtown = Coordinate(latitude: 30.2672, longitude: -97.7431)

/// A straight line of points, `metres` long, heading `bearing`.
private func line(from start: Coordinate, bearing: Double, metres: Double, step: Double = 100) -> Polyline {
    var points = [start]
    var along = step
    while along < metres {
        points.append(start.moved(bearing: bearing, distance: along))
        along += step
    }
    points.append(start.moved(bearing: bearing, distance: metres))
    return Polyline(points: points)
}

/// A line that runs diagonally, which is the shape whose bounding box is
/// mostly ground the route never touches.
private func diagonal(metres: Double, step: Double = 100) -> Polyline {
    line(from: downtown, bearing: 45, metres: metres, step: step)
}

private actor Counter {
    private(set) var boxes: [BoundingBox] = []
    func record(_ box: BoundingBox) { boxes.append(box) }
    var count: Int { boxes.count }
}

private func road(_ from: Coordinate, _ to: Coordinate, limit: Double, step: Double = 25) -> RoadSegment {
    var nodes = [from]
    let length = from.distance(to: to)
    let count = max(1, Int((length / step).rounded(.up)))
    for index in 1...count {
        nodes.append(from.interpolated(to: to, fraction: Double(index) / Double(count)))
    }
    nodes.append(to)
    return RoadSegment(roadClass: .primary, limit: limit, nodes: nodes)
}

// MARK: - Boxes

@Suite("Road data boxes")
struct RoadDataBoxesTests {
    @Test func aShortRouteIsStillOneBox() {
        let boxes = RoadDataBoxes.boxes(for: diagonal(metres: 1_500))
        #expect(boxes.count == 1)
        #expect(boxes[0].areaSquareKilometres < 4)
    }

    @Test func aLongDiagonalIsCutUpAndCostsFarLessGround() {
        let route = diagonal(metres: 27_500)
        let whole = RouteBuilder.roadDataBox(for: route)
        let boxes = RoadDataBoxes.boxes(for: route)

        #expect(boxes.count > 1)
        #expect(boxes.count <= RoadDataBoxes.limit)
        // Every piece is small enough for a mirror to answer.
        #expect(boxes.allSatisfy { $0.areaSquareKilometres <= RoadDataBoxes.maximumArea + 0.01 })
        // And the whole set is a fraction of the one box it replaces, which is
        // the point: Overpass is paid for in ground, not in route length.
        let total = boxes.reduce(0) { $0 + $1.areaSquareKilometres }
        #expect(total < whole.areaSquareKilometres / 2)
    }

    @Test func nothingFallsDownTheSeamBetweenBoxes() {
        let route = diagonal(metres: 40_000, step: 50)
        let boxes = RoadDataBoxes.boxes(for: route)
        // Every metre of the line, and a little either side of it, is inside
        // one of the boxes. A gap here would be a stretch with no speed limit.
        let fine = route.densified(spacing: 20)
        for point in fine.points {
            #expect(boxes.contains { $0.contains(point) })
        }
        for point in fine.points {
            let left = point.moved(bearing: 315, distance: 30)
            #expect(boxes.contains { $0.contains(left) })
        }
    }

    @Test func aVeryLongRouteSpendsCoarserBoxesRatherThanMoreRequests() {
        let boxes = RoadDataBoxes.boxes(for: diagonal(metres: 200_000, step: 250))
        #expect(boxes.count <= RoadDataBoxes.limit)
        #expect(boxes.count > 1)
    }

    @Test func aLineWithTwoPointsIsStillCovered() {
        let start = downtown
        let end = start.moved(bearing: 90, distance: 800)
        let boxes = RoadDataBoxes.boxes(for: Polyline(points: [start, end]))
        #expect(boxes.count == 1)
        #expect(boxes[0].contains(start))
        #expect(boxes[0].contains(end))
    }

    @Test func onlyGroundThatWasActuallyFetchedCounts() {
        let route = diagonal(metres: 27_500)
        let boxes = RoadDataBoxes.boxes(for: route)
        #expect(boxes.count > 2)

        // A box inside one of the pieces is covered.
        let inside = Polyline(points: [route.coordinate(at: 100), route.coordinate(at: 400)])
            .boundingBox().padded(byMeters: RoadDataBoxes.padding)
        #expect(RoadDataBoxes.covers(boxes, [inside]))

        // A box in the corner of the outline, which no piece went near, is not.
        let outline = try! #require(RoadDataBoxes.outline(boxes))
        let corner = Coordinate(latitude: outline.minLatitude + 0.001, longitude: outline.maxLongitude - 0.001)
        let offRoute = BoundingBox(corner).padded(byMeters: 60)
        #expect(outline.contains(corner))
        #expect(!RoadDataBoxes.covers(boxes, [offRoute]))
    }

    @Test func aRouteWhoseDataIsAFallbackIsNeverBorrowedFrom() {
        let boxes = RoadDataBoxes.boxes(for: diagonal(metres: 2_000))
        let good = RoadMetadata(segments: [], controls: [], wasFallback: false)
        #expect(RouteBuilder.roadDataSource(for: boxes, primaryBoxes: boxes, primaryRoadData: good) == .primaryBox)
        #expect(RouteBuilder.roadDataSource(for: boxes, primaryBoxes: boxes, primaryRoadData: .empty) == .unavailable)

        let elsewhere = RoadDataBoxes.boxes(for: line(from: downtown.moved(bearing: 0, distance: 9_000), bearing: 90, metres: 2_000))
        #expect(RouteBuilder.roadDataSource(for: elsewhere, primaryBoxes: boxes, primaryRoadData: good) == .fetch)
    }
}

// MARK: - What Overpass actually answers

@Suite("Overpass answers")
struct OverpassAnswerTests {
    /// Overpass reports its own failures with a 200, a body holding whatever
    /// had been printed when it gave up, and a remark at the end. Measured
    /// against the live service: a query over a 173 square kilometre box with
    /// a one second budget came back 200, 37 MB, 52468 of roughly 200000
    /// elements, and `runtime error: Query timed out in "print"`.
    ///
    /// Reading that as a complete answer is where "no speed limits on some
    /// routes" came from, and caching it is why it stayed.
    @Test func aTruncatedAnswerIsAFailureAndNotARoadless() throws {
        let json = """
        {"version":0.6,"elements":[
          {"type":"node","id":1,"lat":30.1,"lon":-97.7,"tags":{"highway":"stop"}}
        ],"remark":"runtime error: Query timed out in \\"print\\" at line 6 after 2 seconds."}
        """
        #expect(throws: OverpassError.self) { try OverpassClient.decode(Data(json.utf8)) }
        do {
            _ = try OverpassClient.decode(Data(json.utf8))
            Issue.record("a truncated answer must not decode")
        } catch OverpassError.truncated(let remark) {
            #expect(remark.contains("runtime error"))
        }
    }

    @Test func anAnswerWithNoRoadsIsAFailureToo() {
        let json = #"{"version":0.6,"elements":[]}"#
        do {
            _ = try OverpassClient.decode(Data(json.utf8))
            Issue.record("an empty answer must not decode")
        } catch {
            #expect(error as? OverpassError != nil)
        }
    }

    @Test func aPlainNoteIsNotAFailure() {
        #expect(OverpassClient.isFailure("runtime error: Query timed out"))
        #expect(OverpassClient.isFailure("Query run out of memory"))
        #expect(!OverpassClient.isFailure("The data included in this document is from OpenStreetMap"))
    }

    @Test func aGoodAnswerCarriesRoadsAndControls() throws {
        let json = """
        {"version":0.6,"elements":[
          {"type":"way","id":10,"geometry":[{"lat":30.0,"lon":-97.0},{"lat":30.001,"lon":-97.0}],
           "tags":{"highway":"residential","maxspeed":"30 mph"}},
          {"type":"node","id":11,"lat":30.0005,"lon":-97.0,"tags":{"highway":"traffic_signals"}},
          {"type":"node","id":12,"lat":30.0006,"lon":-97.0,"tags":{"highway":"stop","stop":"minor"}}
        ]}
        """
        let metadata = try OverpassClient.decode(Data(json.utf8))
        #expect(metadata.segments.count == 1)
        #expect(!metadata.wasFallback)
        #expect(abs(metadata.segments[0].effectiveLimit - Speed.mph(30)) < 0.01)
        #expect(metadata.controls.count == 2)
        #expect(metadata.controls.contains { $0.kind == .signal })
        #expect(metadata.controls.contains { $0.kind == .stop && $0.appliesToMinorRoadOnly })
    }

    /// A regular expression on the tag value cannot use the index. The same
    /// box that answered in 8 seconds as a list of names did not answer in a
    /// hundred as a regex, so the query names them.
    @Test func theQueryNamesRoadClassesRatherThanMatchingThem() {
        let query = OverpassClient.query(for: BoundingBox(downtown).padded(byMeters: 200), serverTimeout: 20)
        #expect(!query.contains("~"))
        #expect(query.contains("[out:json][timeout:20]"))
        #expect(query.contains("way.near[\"highway\"=\"motorway\"];"))
        #expect(query.contains("way.near[\"highway\"=\"residential\"];"))
        #expect(query.contains("node.beside[\"highway\"=\"stop\"];"))
        // Pavements are left out on purpose: a walked stretch is written into
        // the road data by LastMile, and any OSM footway under it is removed
        // again, so fetching them is megabytes for nothing.
        #expect(!query.contains("\"footway\""))
        // `out body` also prints every way's node ids, which nothing reads.
        #expect(query.contains("out tags geom;"))
    }

    /// The box is looked up twice, not eighteen times.
    ///
    /// This is the whole of the query change: one spatial lookup for the ways
    /// and one for the nodes, with the classes picked out of the two sets
    /// afterwards. Asking the mirror to repeat the lookup once per class was
    /// most of what a request cost, and it cost more the bigger the box.
    @Test func theBoxIsLookedUpTwiceRatherThanOncePerRoadClass() {
        let box = BoundingBox(minLatitude: 30, minLongitude: -97.8, maxLatitude: 30.01, maxLongitude: -97.79)
        let query = OverpassClient.query(for: box)
        let named = OverpassClient.drivableHighways.count + OverpassClient.controlNodes.count

        #expect(named == 18)
        #expect(query.components(separatedBy: box.overpassClause).count - 1 == 2)
        #expect(query.contains("->.near;"))
        #expect(query.contains("->.beside;"))
        // Every class the eighteen statements asked for is still asked for.
        for highway in OverpassClient.drivableHighways {
            #expect(query.contains("way.near[\"highway\"=\"\(highway)\"];"))
        }
        for control in OverpassClient.controlNodes {
            #expect(query.contains("node.beside[\"highway\"=\"\(control)\"];"))
        }
        // And nothing names the box outside those two lookups, which would be
        // one of the eighteen having crept back in.
        #expect(!query.contains("](\(box.overpassClause));"))
    }
}

// MARK: - Which mirror gets asked

@Suite("Overpass mirrors")
struct OverpassMirrorTests {
    private func pool(_ count: Int, cooldown: TimeInterval = 60, concurrent: Int = 1) -> EndpointPool {
        EndpointPool(
            endpoints: (0..<count).map { URL(string: "https://mirror\($0).example/api")! },
            minimumInterval: 0,
            cooldown: cooldown,
            concurrent: concurrent
        )
    }

    @Test func twoBoxesAtOnceGoToTwoDifferentMirrors() async {
        let pool = pool(3)
        let first = await pool.takeEndpoint()
        let second = await pool.takeEndpoint()
        let third = await pool.takeEndpoint()
        let fourth = await pool.takeEndpoint()
        #expect(first != nil && second != nil && third != nil)
        #expect(Set([first, second, third].compactMap { $0?.absoluteString }).count == 3)
        // Mirrors nothing is known about are spread across, one box each. A
        // mirror is only doubled up on once it has earned it.
        #expect(fourth == nil)
    }

    @Test func aMirrorThatRefusedIsLeftAlone() async {
        let pool = pool(2)
        let refused = try! #require(await pool.takeEndpoint())
        await pool.failed(refused, refused: true)
        let next = await pool.takeEndpoint()
        #expect(next != nil)
        #expect(next != refused)
        // Only the other one is on offer now.
        #expect(await pool.takeEndpoint() == nil)
    }

    @Test func theMirrorThatAnsweredIsTriedFirstNextTime() async {
        let pool = pool(3)
        let first = try! #require(await pool.takeEndpoint())
        let second = try! #require(await pool.takeEndpoint())
        await pool.failed(first, refused: true)
        await pool.answered(second, after: 0.2)
        #expect(await pool.takeEndpoint() == second)
    }

    @Test func aMirrorMeasuredSlowLosesToOneMeasuredFast() async {
        let pool = pool(3)
        let quick = try! #require(await pool.takeEndpoint())
        let slow = try! #require(await pool.takeEndpoint())
        await pool.answered(quick, after: 0.4)
        // Nothing came back from this one. It was given up when the other
        // answered, which for a mirror this slow is the only evidence there
        // will ever be, and it is enough to stop handing it out.
        await pool.cancelled(slow, after: 9)
        #expect(await pool.believedSeconds(slow) == 9)
        #expect(await pool.takeEndpoint() == quick)
    }

    @Test func aMirrorThatHasProvedItselfCarriesASecondBoxRatherThanLoseItToASlowOne() async {
        let pool = pool(2, concurrent: 2)
        let quick = try! #require(await pool.takeEndpoint())
        let slow = try! #require(await pool.takeEndpoint())
        await pool.answered(quick, after: 0.4)
        await pool.cancelled(slow, after: 20)

        #expect(await pool.takeEndpoint() == quick)
        // And a second box at the same time: a second request to this mirror
        // is scored as twice its cost, and twice 0.4 still beats 20. Spreading
        // is the preference while the mirrors look alike, not a rule to keep
        // when one of them is fifty times worse.
        #expect(await pool.takeEndpoint() == quick)
        // Never a third, whatever it has proved.
        #expect(await pool.takeEndpoint() == slow)
    }

    @Test func mirrorsThatLookAlikeAreStillSpreadAcross() async {
        let pool = pool(3, concurrent: 2)
        let first = try! #require(await pool.takeEndpoint())
        await pool.answered(first, after: 0.2)
        let second = try! #require(await pool.takeEndpoint())
        // `first` has answered and is free, and is the only mirror with a
        // measurement. It still gets picked first...
        #expect(second == first)
        // ...and the box after it goes elsewhere, because a second request to
        // `first` costs double and the others are assumed to be as good as the
        // best that is known.
        #expect(await pool.takeEndpoint() != first)
    }

    @Test func aMirrorThatCannotBeReachedIsRestedAndRestedLongerEachTime() async {
        let pool = pool(2, cooldown: 4)
        let dead = try! #require(await pool.takeEndpoint())
        await pool.failed(dead, refused: false, after: 25)
        let other = try! #require(await pool.takeEndpoint())
        #expect(other != dead)
        // A dropped connection rests from a quarter of a refusal's base, so a
        // phone changing networks does not cost its best mirror. Saying it
        // again lengthens the rest, which is how a mirror that is simply down
        // stops being paid for once per box.
        #expect(await pool.takeEndpoint(now: .now.addingTimeInterval(0.5)) == nil)
        #expect(await pool.takeEndpoint(now: .now.addingTimeInterval(1.5)) == dead)
        await pool.failed(dead, refused: false, after: 25)
        #expect(await pool.takeEndpoint(now: .now.addingTimeInterval(1.5)) == nil)
        #expect(await pool.takeEndpoint(now: .now.addingTimeInterval(2.5)) == dead)
    }

    @Test func aRefusalRestsForFarLongerThanADroppedConnection() {
        #expect(OverpassClient.isRefusal(.rateLimited))
        #expect(OverpassClient.isRefusal(.truncated("runtime error")))
        #expect(OverpassClient.isRefusal(.badResponse(500)))
        #expect(!OverpassClient.isRefusal(.transport("The network connection was lost.")))
        #expect(!OverpassClient.isRefusal(.empty))
    }
}

// MARK: - The cache

@Suite("Road data cache")
struct RoadDataCacheTests {
    private func temporary() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloak-roaddata-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let box = BoundingBox(minLatitude: 30, minLongitude: -97.8, maxLatitude: 30.01, maxLongitude: -97.79)

    private func answer() -> RoadMetadata {
        RoadMetadata(
            segments: [road(Coordinate(latitude: 30.001, longitude: -97.795),
                            Coordinate(latitude: 30.008, longitude: -97.795),
                            limit: Speed.mph(35))],
            controls: [],
            wasFallback: false
        )
    }

    @Test func aGoodAnswerIsFetchedOnceAndKept() async {
        let cache = RoadDataCache(directory: temporary())
        let calls = Counter()
        let good = answer()
        for _ in 0..<3 {
            let result = await cache.metadata(for: box) { requested in
                await calls.record(requested)
                return good
            }
            #expect(result.segments.count == 1)
        }
        #expect(await calls.count == 1)
    }

    @Test func aFailureIsNotCachedAndIsTriedAgain() async {
        let cache = RoadDataCache(directory: temporary())
        let calls = Counter()
        for _ in 0..<2 {
            let result = await cache.metadata(for: box) { requested in
                await calls.record(requested)
                throw OverpassError.rateLimited
            }
            // Said plainly rather than passed off as a road free square mile.
            #expect(result.wasFallback)
            #expect(result.segments.isEmpty)
        }
        #expect(await calls.count == 2)
    }

    @Test func anAnswerWithNothingInItIsNotKeptForMonths() async {
        let cache = RoadDataCache(directory: temporary(), emptyMaximumAge: 0)
        let calls = Counter()
        for _ in 0..<2 {
            _ = await cache.metadata(for: box) { requested in
                await calls.record(requested)
                return RoadMetadata(segments: [], controls: [], wasFallback: false)
            }
        }
        #expect(await calls.count == 2)

        // A real answer for the same box is kept the usual way.
        let keeping = RoadDataCache(directory: temporary())
        #expect(await keeping.keeps(answer()))
        #expect(await !keeping.keeps(.empty))
        #expect(await !keeping.keeps(RoadMetadata(segments: [], controls: [], fetchedAt: .now.addingTimeInterval(-3600), wasFallback: false)))
    }

    @Test func twoRoutesThroughTheSameStreetsShareOneRequest() async {
        let cache = RoadDataCache(directory: temporary())
        let calls = Counter()
        let good = answer()
        let box = self.box
        async let first = cache.metadata(for: box) { requested in
            await calls.record(requested)
            try? await Task.sleep(for: .milliseconds(60))
            return good
        }
        async let second = cache.metadata(for: box) { requested in
            await calls.record(requested)
            try? await Task.sleep(for: .milliseconds(60))
            return good
        }
        let answers = await [first, second]
        #expect(answers.allSatisfy { $0.segments.count == 1 })
        #expect(await calls.count == 1)
    }

    @Test func anAnswerSurvivesTheAppBeingRelaunched() async {
        let directory = temporary()
        let calls = Counter()
        let good = answer()
        let box = self.box

        let before = RoadDataCache(directory: directory)
        _ = await before.metadata(for: box) { requested in
            await calls.record(requested)
            return good
        }

        // A second cache over the same directory is what the next launch gets:
        // nothing in memory, everything on disk. If this asked again, road
        // data would be re-fetched every time the app was opened.
        let after = RoadDataCache(directory: directory)
        let again = await after.metadata(for: box) { requested in
            await calls.record(requested)
            return .empty
        }
        #expect(again.segments.count == 1)
        #expect(await calls.count == 1)
    }

    @Test func aDifferentLineThroughTheSameStreetsIsADifferentBox() {
        // Worth being plain about, because it bounds what the cache is for.
        // The key is the box's own corners to three decimal places, about a
        // hundred metres, and boxes are cut wherever a route's own points
        // fall. The same trip planned twice is a hit. A second trip down the
        // same streets from a different start is a miss, and pays in full.
        let shifted = BoundingBox(
            minLatitude: box.minLatitude + 0.002,
            minLongitude: box.minLongitude,
            maxLatitude: box.maxLatitude + 0.002,
            maxLongitude: box.maxLongitude
        )
        #expect(RoadDataCache.key(for: box) != RoadDataCache.key(for: shifted))
        // Under a hundred metres is the same box, which is what lets a route
        // borrow the answer fetched for a line a little to one side of it.
        let nudged = BoundingBox(
            minLatitude: box.minLatitude + 0.0001,
            minLongitude: box.minLongitude,
            maxLatitude: box.maxLatitude + 0.0001,
            maxLongitude: box.maxLongitude
        )
        #expect(RoadDataCache.key(for: box) == RoadDataCache.key(for: nudged))
    }
}

// MARK: - Merging

@Suite("Merging road data")
struct RoadMetadataMergeTests {
    @Test func theSameRoadInTwoBoxesIsKeptOnce() {
        let shared = road(Coordinate(latitude: 30, longitude: -97),
                          Coordinate(latitude: 30.002, longitude: -97), limit: Speed.mph(30))
        let other = road(Coordinate(latitude: 30.002, longitude: -97),
                         Coordinate(latitude: 30.004, longitude: -97), limit: Speed.mph(40))
        let control = TrafficControl(kind: .stop, coordinate: Coordinate(latitude: 30.002, longitude: -97), alongTrack: 0)
        let merged = RoadMetadata.merged([
            RoadMetadata(segments: [shared], controls: [control], wasFallback: false),
            RoadMetadata(segments: [shared, other], controls: [control], wasFallback: false)
        ])
        #expect(merged.segments.count == 2)
        #expect(merged.controls.count == 1)
        #expect(!merged.wasFallback)
    }

    @Test func onePieceMissingMakesTheWholeThingAFallback() {
        let good = RoadMetadata(segments: [road(Coordinate(latitude: 30, longitude: -97),
                                                Coordinate(latitude: 30.002, longitude: -97), limit: 20)],
                                controls: [], wasFallback: false)
        let merged = RoadMetadata.merged([good, .empty])
        #expect(merged.wasFallback)
        // What did arrive is still there to drive on.
        #expect(merged.segments.count == 1)
    }

    @Test func nothingAtAllIsAFallback() {
        #expect(RoadMetadata.merged([]).wasFallback)
        #expect(RoadMetadata.merged([]).isEmpty)
    }
}

// MARK: - Looking things up quickly

@Suite("Finding the road under a point")
struct SpatialIndexTests {
    /// Thirty streets in a grid, and a route down one of them.
    private func world() -> (RoadMetadata, Polyline) {
        var segments: [RoadSegment] = []
        for step in 0..<15 {
            let north = downtown.moved(bearing: 0, distance: Double(step) * 120)
            segments.append(road(north, north.moved(bearing: 90, distance: 1_800), limit: Speed.mph(30 + Double(step))))
            let east = downtown.moved(bearing: 90, distance: Double(step) * 120)
            segments.append(road(east, east.moved(bearing: 0, distance: 1_800), limit: Speed.mph(20 + Double(step))))
        }
        var controls: [TrafficControl] = []
        for step in 0..<15 {
            controls.append(TrafficControl(
                kind: .signal,
                coordinate: downtown.moved(bearing: 90, distance: Double(step) * 120),
                alongTrack: 0
            ))
            // One street over, which is not the road being driven.
            controls.append(TrafficControl(
                kind: .stop,
                coordinate: downtown.moved(bearing: 0, distance: 240).moved(bearing: 90, distance: Double(step) * 120),
                alongTrack: 0
            ))
        }
        let route = Polyline(points: [downtown, downtown.moved(bearing: 90, distance: 1_700)]).densified(spacing: 5)
        return (RoadMetadata(segments: segments, controls: controls, wasFallback: false), route)
    }

    /// The grid is a way of not measuring everything, never a different
    /// answer. This is the same question asked the slow way.
    @Test func theGridFindsExactlyWhatAFullScanFinds() {
        let (metadata, route) = world()
        let quick = metadata.limits(along: route, fallback: .residential)
        let slow = Self.byBruteForce(metadata, along: route, fallback: .residential)
        #expect(quick == slow)
        // And it is the limit on the street being driven rather than the
        // fallback, or the test would agree about nothing.
        #expect(abs(quick[quick.count / 2] - Speed.mph(30)) < 0.01)
        #expect(abs(quick[quick.count / 2] - RoadClass.residential.defaultLimit) > 0.01)
    }

    @Test func onlyTheControlsOnTheRoadBeingDrivenAreSnapped() {
        let (metadata, route) = world()
        let snapped = metadata.snappedControls(to: route)
        // The signals are on the route. The stop signs are a block north.
        #expect(!snapped.isEmpty)
        #expect(snapped.allSatisfy { $0.kind == .signal })
        #expect(snapped.allSatisfy { $0.alongTrack >= 0 && $0.alongTrack <= route.length })
    }

    @Test func aBoxIsFoundFromEveryCellItTouches() {
        let wide = BoundingBox(downtown).padded(byMeters: 400)
        let index = SpatialIndex(boxes: [wide], latitudeSlack: 0.0015, longitudeSlack: 0.0015)
        for bearing in stride(from: 0.0, to: 360.0, by: 30) {
            let point = downtown.moved(bearing: bearing, distance: 380)
            #expect(index.candidates(near: point).contains(0))
        }
    }

    /// The same lookup, written the obvious way, for the test above to agree
    /// with.
    private static func byBruteForce(_ metadata: RoadMetadata, along polyline: Polyline, fallback: RoadClass) -> [Double] {
        let points = polyline.points
        let cumulative = polyline.cumulative
        var output: [Double] = []
        for position in points.indices {
            let point = points[position]
            let routeBearing = polyline.bearing(at: cumulative[position])
            var bestScore = Double.greatestFiniteMagnitude
            var bestDistance = Double.greatestFiniteMagnitude
            var bestLimit = fallback.defaultLimit
            for segment in metadata.segments {
                let nodes = segment.nodes
                guard nodes.count > 1 else { continue }
                for n in 0..<(nodes.count - 1) {
                    let (metres, _) = point.distance(toSegmentFrom: nodes[n], to: nodes[n + 1])
                    if metres > 40 { continue }
                    let roadBearing = nodes[n].bearing(to: nodes[n + 1])
                    var delta = abs(roadBearing - routeBearing).truncatingRemainder(dividingBy: 360)
                    if delta > 180 { delta = 360 - delta }
                    if delta > 90 { delta = 180 - delta }
                    let score = metres + (delta > 35 ? 30.0 : 0.0)
                    if score < bestScore {
                        bestScore = score
                        bestDistance = metres
                        bestLimit = segment.effectiveLimit
                    }
                }
            }
            output.append(bestDistance <= 40 ? bestLimit : fallback.defaultLimit)
        }
        return output
    }
}
