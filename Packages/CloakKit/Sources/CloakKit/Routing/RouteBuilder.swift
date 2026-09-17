import Foundation
import MapKit

public enum RouteBuilderError: Error, Sendable {
    case notEnoughWaypoints
    case routingFailed(String)
}

public struct RouteBuilder: Sendable {
    /// One route Apple Maps offered between two points, carrying only what
    /// Cloak reads from `MKRoute`. Everything past the request works on this,
    /// so all of it can be exercised without a network.
    struct Offer: Sendable {
        var points: [Coordinate]
        var travelTime: TimeInterval
        var distance: Double
        var name: String
        var advisories: [String]

        init(
            points: [Coordinate],
            travelTime: TimeInterval,
            distance: Double? = nil,
            name: String = "",
            advisories: [String] = []
        ) {
            self.points = points
            self.travelTime = travelTime
            self.distance = distance ?? Polyline(points: points).length
            self.name = name
            self.advisories = advisories
        }
    }

    /// Asks for routes between two points, best first. With `alternatives`
    /// false the answer is a single route.
    typealias Directions = @Sendable (
        _ from: Coordinate,
        _ to: Coordinate,
        _ mode: TravelMode,
        _ alternatives: Bool
    ) async throws -> [Offer]

    /// Every road and traffic control in a box.
    typealias RoadData = @Sendable (BoundingBox) async -> RoadMetadata

    private let directions: Directions
    let roadData: RoadData

    public init(cache: RoadDataCache = RoadDataCache(), overpass: OverpassClient = OverpassClient()) {
        self.directions = { origin, destination, mode, alternatives in
            try await Self.appleMaps(from: origin, to: destination, mode: mode, alternatives: alternatives)
        }
        self.roadData = { box in
            await cache.metadata(for: box) { requested in
                try await overpass.fetch(box: requested)
            }
        }
    }

    /// Routes and road data from somewhere other than Apple Maps and Overpass.
    init(directions: @escaping Directions, roadData: @escaping RoadData) {
        self.directions = directions
        self.roadData = roadData
    }

    /// One routed line, and how it is covered.
    struct Piece: Sendable {
        var mode: TravelMode
        var points: [Coordinate]
        var travelTime: TimeInterval
        var reason: RouteLeg.Reason
    }

    /// One waypoint to the next: its first route laid out in full, and the
    /// other routes Apple Maps offered for it, not laid out yet.
    struct Leg: Sendable {
        var origin: RouteWaypoint
        var destination: RouteWaypoint
        var pieces: [Piece]
        /// The route the pieces were laid out from. Nil when the leg is a
        /// short hop that was walked instead of asked for in the trip's mode.
        var first: Offer?
        var others: [Offer]
    }

    /// Everything about a built route except its road data.
    ///
    /// The line is known as soon as Apple Maps answers; the posted limits and
    /// the stops arrive later. Keeping the two apart is what lets the same
    /// route be shown straight away and then filled in, without rebuilding it
    /// or giving it a new identity on the way.
    struct Shape: Sendable {
        var id: UUID
        var waypoints: [RouteWaypoint]
        var polyline: Polyline
        var legs: [RouteLeg]
        var travelTime: TimeInterval
        var name: String
        var advisories: [String]
    }

    /// Builds a route, road data and all.
    ///
    /// This is the path for starting a drive with nothing on screen, so it
    /// waits for the road data: a drive that is about to run wants its posted
    /// limits and its stop signs. `beginRoutes` is the path for showing a
    /// route, and that one does not wait.
    public func build(
        waypoints: [RouteWaypoint],
        mode: TravelMode,
        metadataBudget: TimeInterval = RouteBuilder.metadataBudget
    ) async throws -> RoutePlan {
        let build = try await begin(waypoints: waypoints, mode: mode, alternatives: false, metadataBudget: metadataBudget)
        return await build.settled()
    }

    /// The first route Apple Maps offered, complete, with the others it
    /// offered kept for `RouteBuild.alternatives()` to finish.
    ///
    /// Waits for the road data, the way `build` does. The app uses
    /// `beginRoutes` instead.
    public func buildRoutes(
        waypoints: [RouteWaypoint],
        mode: TravelMode,
        metadataBudget: TimeInterval = RouteBuilder.metadataBudget
    ) async throws -> RouteBuild {
        let build = try await begin(waypoints: waypoints, mode: mode, alternatives: true, metadataBudget: metadataBudget)
        return await build.withSettledPrimary()
    }

    /// The first route Apple Maps offered, as soon as Apple Maps offers it.
    ///
    /// The line comes back with no road data and `wasFallback` set, which is
    /// the truth: the speeds in it are the per class defaults until Overpass
    /// answers. The caller draws it, lets the person start it, and calls
    /// `settled()` to get the same route again, same identity, with its posted
    /// limits and stops in place.
    ///
    /// This exists because waiting was the whole complaint. Overpass takes
    /// seconds at best and the better part of a minute on a mirror having a
    /// bad day, and the route sat behind it doing nothing, looking broken.
    public func beginRoutes(
        waypoints: [RouteWaypoint],
        mode: TravelMode,
        metadataBudget: TimeInterval = RouteBuilder.metadataBudget
    ) async throws -> RouteBuild {
        try await begin(waypoints: waypoints, mode: mode, alternatives: true, metadataBudget: metadataBudget)
    }

    /// How long one pass at the road data may take.
    ///
    /// It used to be 7 seconds against a request allowed 8 and a server told
    /// it could spend 25, so the builder gave up before its own request could
    /// finish. Nothing waits on this any more, so it is set to outlast a slow
    /// mirror rather than to keep a person waiting.
    public static let metadataBudget: TimeInterval = 30

    private func begin(
        waypoints: [RouteWaypoint],
        mode: TravelMode,
        alternatives: Bool,
        metadataBudget: TimeInterval
    ) async throws -> RouteBuild {
        guard waypoints.count >= 2 else { throw RouteBuilderError.notEnoughWaypoints }
        let started = RouteTiming.now()
        let memo = DirectionsMemo(directions)

        var legs: [Leg] = []
        for index in 0..<(waypoints.count - 1) {
            legs.append(try await connect(
                from: waypoints[index],
                to: waypoints[index + 1],
                mode: mode,
                alternatives: alternatives,
                memo: memo
            ))
        }

        let (polyline, stitched, travelTime) = Self.stitch(legs.flatMap(\.pieces))
        let boxes = Self.roadDataBoxes(for: polyline)
        let varied = Self.variedLeg(legs)
        let described = Self.describe(legs, varying: varied, with: nil)
        let shape = Shape(
            id: UUID(),
            waypoints: waypoints,
            polyline: polyline,
            legs: stitched,
            travelTime: travelTime,
            name: described.name,
            advisories: described.advisories
        )
        RouteTiming.done(
            "route.line",
            started,
            "\(Int(polyline.length))m \(legs.count) legs, \(boxes.count) road data boxes"
        )

        // Starts now, in the background. Nothing here waits on it.
        let run = RoadDataRun(boxes: boxes, source: roadData, budget: metadataBudget)
        await run.start()

        return RouteBuild(
            primary: Self.plan(shape: shape, mode: mode, roadData: .empty),
            builder: self,
            mode: mode,
            shape: shape,
            legs: legs,
            variedLeg: varied,
            primaryBoxes: boxes,
            roadDataRun: run,
            metadataBudget: metadataBudget,
            memo: memo
        )
    }

    // MARK: - The other routes

    /// Which leg the other routes differ on: the longest leg Apple Maps
    /// offered more than one route for, measured along its first route.
    ///
    /// Every other leg keeps its first route. Offering each combination of
    /// every leg's routes would be up to 3^n lines, each needing its own road
    /// data, for choices that mostly differ by a side street. The longest leg
    /// is where the choice of road changes the most time, so a trip with
    /// several stops still gets at most three routes, and the same number of
    /// Overpass requests as a trip with two.
    static func variedLeg(_ legs: [Leg]) -> Int? {
        var best: (index: Int, distance: Double)?
        for (index, leg) in legs.enumerated() {
            guard let first = leg.first, !leg.others.isEmpty else { continue }
            if let current = best, current.distance >= first.distance { continue }
            best = (index, first.distance)
        }
        return best?.index
    }

    /// The whole trip again with one leg's first route swapped for another
    /// route Apple Maps offered for it.
    ///
    /// Nothing is carried over from the first route but the other legs, which
    /// are the same lines. The swapped leg gets its own walks in and out, the
    /// whole line gets road data that covers it, and the walked stretches are
    /// written into that road data along this line, not the first one.
    func alternative(of build: RouteBuild, varying index: Int, with offer: Offer) async -> RoutePlan? {
        let leg = build.legs[index]
        let swapped = await layOut(offer, from: leg.origin, to: leg.destination, mode: build.mode, memo: build.memo)

        var pieces: [Piece] = []
        for (position, each) in build.legs.enumerated() {
            pieces.append(contentsOf: position == index ? swapped : each.pieces)
        }
        let (polyline, stitched, travelTime) = Self.stitch(pieces)
        guard polyline.points.count > 1 else { return nil }

        let boxes = Self.roadDataBoxes(for: polyline)
        let primaryRoadData = await build.roadDataRun.settled()
        let roadData: RoadMetadata
        switch Self.roadDataSource(for: boxes, primaryBoxes: build.primaryBoxes, primaryRoadData: primaryRoadData) {
        case .primaryBox:
            roadData = primaryRoadData
        case .unavailable:
            roadData = .empty
        case .fetch:
            // Stops changed while the walks were being asked for. Starting an
            // Overpass request for a route nobody will see only spends the
            // rate limit.
            guard !Task.isCancelled else { return nil }
            let run = RoadDataRun(boxes: boxes, source: self.roadData, budget: build.metadataBudget)
            roadData = await run.settled()
        }

        let described = Self.describe(build.legs, varying: index, with: offer)
        return Self.plan(
            shape: Shape(
                id: UUID(),
                waypoints: build.primary.waypoints,
                polyline: polyline,
                legs: stitched,
                travelTime: travelTime,
                name: described.name,
                advisories: described.advisories
            ),
            mode: build.mode,
            roadData: roadData
        )
    }

    /// Where an offered route's road data comes from.
    enum RoadDataSource: Equatable, Sendable {
        /// Its own Overpass request, for its own boxes.
        case fetch
        /// The first route's answer, untouched by that route's walks, because
        /// the boxes it was fetched for already hold every road this line runs
        /// on and every control beside it.
        case primaryBox
        /// Overpass did not answer for the first route, so it is not asked
        /// again for a second and a third. They fall back the way the first
        /// did, and the three stay comparable.
        case unavailable
    }

    /// How far the road data boxes reach past the line.
    static let roadDataPadding: Double = RoadDataBoxes.padding

    static func roadDataBox(for polyline: Polyline) -> BoundingBox {
        polyline.boundingBox().padded(byMeters: roadDataPadding)
    }

    /// The boxes to ask Overpass for, for one route.
    ///
    /// A short trip is one box, exactly as before. A trip long enough that one
    /// box would be a quarter of a city is cut into pieces first: same ground
    /// along the line, a fraction of the ground in total, and each piece small
    /// enough that a mirror answers it rather than timing out halfway through
    /// and sending a truncated answer that looks complete.
    static func roadDataBoxes(for polyline: Polyline) -> [BoundingBox] {
        RoadDataBoxes.boxes(for: polyline)
    }

    /// Decides where an offered route's road data comes from.
    ///
    /// A box inside the first route's boxes is safe to answer from that
    /// route's data: both are padded by 120 m, and a limit is looked up within
    /// 40 m of the line and a control within 10 m, so nothing the line needs
    /// lies outside. The cache rounds boxes to about 110 m, which still leaves
    /// more than 60 m to spare.
    static func roadDataSource(
        for box: BoundingBox,
        primaryBox: BoundingBox,
        primaryRoadData: RoadMetadata
    ) -> RoadDataSource {
        roadDataSource(for: [box], primaryBoxes: [primaryBox], primaryRoadData: primaryRoadData)
    }

    /// The same decision when either route took more than one box.
    ///
    /// Being inside the outline of the first route's boxes is not enough: with
    /// the line cut into pieces the outline holds ground nobody fetched, so
    /// every box has to sit inside one of them.
    static func roadDataSource(
        for boxes: [BoundingBox],
        primaryBoxes: [BoundingBox],
        primaryRoadData: RoadMetadata
    ) -> RoadDataSource {
        if primaryRoadData.wasFallback { return .unavailable }
        if RoadDataBoxes.covers(primaryBoxes, boxes) { return .primaryBox }
        return .fetch
    }

    static func covers(_ outer: BoundingBox, _ inner: BoundingBox) -> Bool {
        inner.minLatitude >= outer.minLatitude && inner.maxLatitude <= outer.maxLatitude
            && inner.minLongitude >= outer.minLongitude && inner.maxLongitude <= outer.maxLongitude
    }

    /// What Apple Maps said about the routes a trip is made of: the name of
    /// the leg the routes differ on, and every notice on any leg.
    static func describe(_ legs: [Leg], varying index: Int?, with offer: Offer?) -> (name: String, advisories: [String]) {
        var used: [Offer?] = legs.map(\.first)
        if let index, let offer, used.indices.contains(index) { used[index] = offer }

        let named = index ?? legs.indices.max { (legs[$0].first?.distance ?? 0) < (legs[$1].first?.distance ?? 0) }
        let name = named.flatMap { used.indices.contains($0) ? used[$0]?.name : nil } ?? ""

        var advisories: [String] = []
        for notice in used.compactMap({ $0 }).flatMap(\.advisories) where !advisories.contains(notice) {
            advisories.append(notice)
        }
        return (name, advisories)
    }

    /// A finished route: the walked stretches written into its road data.
    ///
    /// The identity comes from the shape, not from this call, so the same
    /// route rebuilt when its road data lands is still the route on screen.
    static func plan(shape: Shape, mode: TravelMode, roadData: RoadMetadata) -> RoutePlan {
        // Write the walked stretches into the road data. The simulation rebuilds
        // the speed profile from the points and their posted limits alone, so
        // this is how the decision reaches it.
        let walked = shape.legs.filter(\.mode.isOnFoot).map { $0.start...$0.end }
        let metadata = LastMile.describing(roadData, walked: walked, along: shape.polyline)

        return RoutePlan(
            waypoints: shape.waypoints,
            polyline: shape.polyline,
            metadata: metadata,
            mode: mode,
            expectedTravelTime: shape.travelTime,
            legs: shape.legs,
            routeName: shape.name,
            advisories: shape.advisories,
            id: shape.id
        )
    }

    // MARK: - One waypoint to the next

    private func connect(
        from origin: RouteWaypoint,
        to destination: RouteWaypoint,
        mode: TravelMode,
        alternatives: Bool,
        memo: DirectionsMemo
    ) async throws -> Leg {
        // Nobody starts a car, pulls out and parks again to cover a few
        // hundred metres. If the walk fails, the drive still stands.
        if mode == .drive,
           LastMile.isShortHop(origin.coordinate.distance(to: destination.coordinate)),
           let walk = try? await memo.first(from: origin.coordinate, to: destination.coordinate, mode: .walk) {
            return Leg(
                origin: origin,
                destination: destination,
                pieces: [Piece(mode: .walk, points: walk.points, travelTime: walk.travelTime, reason: .shortHop)],
                first: nil,
                others: []
            )
        }

        let offers = try await memo.routes(
            from: origin.coordinate,
            to: destination.coordinate,
            mode: mode,
            alternatives: alternatives
        )
        guard let first = offers.first else {
            throw RouteBuilderError.routingFailed(
                "Apple Maps could not connect those two points by \(mode == .drive ? "road" : "foot").")
        }
        let pieces = await layOut(first, from: origin, to: destination, mode: mode, memo: memo)
        return Leg(
            origin: origin,
            destination: destination,
            pieces: pieces,
            first: first,
            others: alternatives ? Array(offers.dropFirst().prefix(RouteChoice.limit - 1)) : []
        )
    }

    /// Lays out one route Apple Maps offered for a leg, with the walks a
    /// person would make at either end of it.
    private func layOut(
        _ offer: Offer,
        from origin: RouteWaypoint,
        to destination: RouteWaypoint,
        mode: TravelMode,
        memo: DirectionsMemo
    ) async -> [Piece] {
        guard mode == .drive else {
            return [Piece(mode: mode, points: offer.points, travelTime: offer.travelTime, reason: .requested)]
        }

        var drivePoints = offer.points
        var driveTime = offer.travelTime
        guard drivePoints.count > 1 else {
            return [Piece(mode: .drive, points: drivePoints, travelTime: driveTime, reason: .requested)]
        }

        var tail: Piece?

        switch destination.arrival {
        case .driveAll:
            break

        case .onFoot(let metres):
            // Park the stated distance out and walk in, whatever the map
            // thinks about how close a car can get.
            let line = Polyline(points: drivePoints)
            let splitAt = line.length - max(0, metres)
            if splitAt > 20 {
                let handover = line.coordinate(at: splitAt)
                if let walk = try? await memo.first(from: handover, to: destination.coordinate, mode: .walk),
                   walk.points.count > 1 {
                    driveTime *= splitAt / max(line.length, 1)
                    drivePoints = Self.prefix(of: drivePoints, upTo: splitAt)
                    tail = Piece(
                        mode: .walk,
                        points: walk.points,
                        travelTime: walk.travelTime,
                        reason: .askedFor
                    )
                }
            }

        case .automatic:
            let gap = (drivePoints.last ?? destination.coordinate).distance(to: destination.coordinate)
            if LastMile.walksIn(gap: gap), let last = drivePoints.last,
               let walk = try? await memo.first(from: last, to: destination.coordinate, mode: .walk) {
                let points = walk.points
                let length = Polyline(points: points).length
                if points.count > 1, LastMile.accepts(walkLength: length, gap: gap) {
                    tail = Piece(mode: .walk, points: points, travelTime: walk.travelTime, reason: .noRoadToTheDoor)
                }
            }
        }

        // The same thing at the other end: a car cannot be started where there
        // is no road, so the leg out of a terminal begins on foot too.
        var head: Piece?
        let headGap = (drivePoints.first ?? origin.coordinate).distance(to: origin.coordinate)
        if LastMile.walksIn(gap: headGap), let first = drivePoints.first,
           let walk = try? await memo.first(from: origin.coordinate, to: first, mode: .walk) {
            let points = walk.points
            let length = Polyline(points: points).length
            if points.count > 1, LastMile.accepts(walkLength: length, gap: headGap) {
                head = Piece(mode: .walk, points: points, travelTime: walk.travelTime, reason: .noRoadToTheDoor)
            }
        }

        var pieces: [Piece] = []
        if let head { pieces.append(head) }
        pieces.append(Piece(mode: .drive, points: drivePoints, travelTime: driveTime, reason: .requested))
        if let tail { pieces.append(tail) }
        return pieces
    }

    // MARK: - Putting the pieces together

    /// Joins the pieces into one line and records what each stretch is.
    ///
    /// Two pieces that meet at the same point share it, so the join is a point
    /// on the line rather than a step across one.
    static func stitch(_ pieces: [Piece]) -> (Polyline, [RouteLeg], TimeInterval) {
        var combined: [Coordinate] = []
        var ranges: [(piece: Piece, first: Int, last: Int)] = []
        var travelTime: TimeInterval = 0

        for piece in pieces where piece.points.count > 1 {
            travelTime += piece.travelTime
            if combined.isEmpty {
                combined.append(contentsOf: piece.points)
                ranges.append((piece, 0, combined.count - 1))
                continue
            }
            let first = combined.count - 1
            // The pieces are routed to and from the same coordinate, so the
            // shared point is dropped rather than repeated. A piece that does
            // not actually start where the last one ended keeps all its points.
            let shared = combined[first].distance(to: piece.points[0]) < 2
            combined.append(contentsOf: shared ? Array(piece.points.dropFirst()) : piece.points)
            ranges.append((piece, first, combined.count - 1))
        }

        let polyline = Polyline(points: combined)
        guard polyline.points.count > 1 else { return (polyline, [], travelTime) }
        let cumulative = polyline.cumulative

        var legs: [RouteLeg] = []
        for entry in ranges {
            let start = cumulative[entry.first]
            let end = cumulative[entry.last]
            if var last = legs.last, last.mode == entry.piece.mode, last.reason == entry.piece.reason {
                last.end = end
                legs[legs.count - 1] = last
            } else {
                legs.append(RouteLeg(mode: entry.piece.mode, start: start, end: end, reason: entry.piece.reason))
            }
        }
        // A single stretch in the mode that was asked for is not worth
        // describing; the plan already says what the mode is.
        if legs.count == 1, legs[0].reason == .requested { legs = [] }
        return (polyline, legs, travelTime)
    }

    /// The first part of a line, up to a distance along it.
    static func prefix(of points: [Coordinate], upTo distance: Double) -> [Coordinate] {
        let line = Polyline(points: points)
        guard line.points.count > 1, distance > 0 else { return points }
        guard distance < line.length else { return points }
        var output: [Coordinate] = []
        for (index, point) in line.points.enumerated() where line.cumulative[index] < distance {
            output.append(point)
        }
        output.append(line.coordinate(at: distance))
        return output
    }

    /// Runs `work`, giving up and returning nil once the budget is spent.
    static func within<T: Sendable>(
        seconds: TimeInterval,
        _ work: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func appleMaps(
        from origin: Coordinate,
        to destination: Coordinate,
        mode: TravelMode,
        alternatives: Bool
    ) async throws -> [Offer] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.clCoordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination.clCoordinate))
        request.transportType = mode == .drive ? .automobile : .walking
        request.requestsAlternateRoutes = alternatives

        let started = RouteTiming.now()
        do {
            let response = try await MKDirections(request: request).calculate()
            guard !response.routes.isEmpty else {
                throw RouteBuilderError.routingFailed(
                    "Apple Maps could not connect those two points by \(mode == .drive ? "road" : "foot").")
            }
            let routes = alternatives ? response.routes : Array(response.routes.prefix(1))
            RouteTiming.done(
                "applemaps",
                started,
                "\(mode.rawValue) \(routes.count) routes, \(Int(routes[0].distance))m"
            )
            return routes.map { route in
                Offer(
                    points: route.polyline.coordinates,
                    travelTime: route.expectedTravelTime,
                    distance: route.distance,
                    name: route.name,
                    advisories: route.advisoryNotices
                )
            }
        } catch let error as RouteBuilderError {
            RouteTiming.done("applemaps.failed", started, "\(mode.rawValue)")
            throw error
        } catch {
            RouteTiming.done("applemaps.failed", started, "\(mode.rawValue) \(error.localizedDescription)")
            throw RouteBuilderError.routingFailed(error.localizedDescription)
        }
    }
}

/// The road data for one route: fetched once, shared by everything that wants
/// it, and asked for again when it does not arrive.
///
/// The route on screen, the Start button and the other offered routes all want
/// the same answer, and before this they each had their own idea of when to
/// wait for it. One run means one set of requests.
actor RoadDataRun {
    private let boxes: [BoundingBox]
    private let source: RouteBuilder.RoadData
    private let budget: TimeInterval
    private var task: Task<RoadMetadata, Never>?
    /// The answer, once there is one. Lets the Start button ask whether the
    /// road data has landed without committing to waiting for it.
    private var answer: RoadMetadata?
    private(set) var attempts = 0

    init(boxes: [BoundingBox], source: @escaping RouteBuilder.RoadData, budget: TimeInterval) {
        self.boxes = boxes
        self.source = source
        self.budget = budget
    }

    /// Starts the fetch without waiting for it.
    func start() {
        guard task == nil else { return }
        task = fetch()
    }

    /// The answer if it has already arrived, without waiting for one.
    func finished() -> RoadMetadata? { answer }

    /// The answer, fetched once however many times this is asked.
    func settled() async -> RoadMetadata {
        if let task { return await Self.value(of: task) }
        let fresh = fetch()
        task = fresh
        return await Self.value(of: fresh)
    }

    /// Waits on a fetch, and lets go of it when the waiter is cancelled.
    ///
    /// The fetch is its own task so that everything wanting the answer shares
    /// one set of requests. That also means it does not inherit anyone's
    /// cancellation, so it is handed on here instead: a route nobody is
    /// looking at any more should not still be spending the rate limit.
    private static func value(of task: Task<RoadMetadata, Never>) async -> RoadMetadata {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Asks again for a route whose data did not arrive.
    ///
    /// A mirror that is rate limiting or having a bad minute is the usual
    /// reason, and both pass. Giving up for good meant a route stayed on
    /// default limits for as long as it was on screen.
    func retried(times: Int, delay: Duration) async -> RoadMetadata {
        var result = await settled()
        var remaining = max(0, times)
        while result.wasFallback, remaining > 0 {
            if Task.isCancelled { return result }
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return result }
            // The cache keeps whichever boxes did arrive, so asking again asks
            // only for the ones that did not.
            let again = fetch()
            task = again
            result = await Self.value(of: again)
            remaining -= 1
        }
        return result
    }

    private func fetch() -> Task<RoadMetadata, Never> {
        attempts += 1
        answer = nil
        let boxes = self.boxes
        let source = self.source
        let budget = self.budget
        return Task { [weak self] in
            let value = await Self.fetch(boxes: boxes, source: source, budget: budget)
            await self?.record(value)
            return value
        }
    }

    private func record(_ value: RoadMetadata) { answer = value }

    static func fetch(
        boxes: [BoundingBox],
        source: @escaping RouteBuilder.RoadData,
        budget: TimeInterval
    ) async -> RoadMetadata {
        guard !boxes.isEmpty else { return .empty }
        let started = RouteTiming.now()

        let parts = await RouteBuilder.within(seconds: budget) {
            await withTaskGroup(of: (Int, RoadMetadata).self) { group in
                for (index, box) in boxes.enumerated() {
                    group.addTask { (index, await source(box)) }
                }
                var collected = [RoadMetadata?](repeating: nil, count: boxes.count)
                for await (index, part) in group { collected[index] = part }
                return collected.map { $0 ?? .empty }
            }
        }
        let merged = RoadMetadata.merged(parts ?? [])
        RouteTiming.done(
            "roaddata",
            started,
            "\(boxes.count) boxes, \(merged.segments.count) roads, \(merged.controls.count) controls, fallback \(merged.wasFallback)"
        )
        return merged
    }
}

/// A route built with its road data still arriving, and with the other routes
/// Apple Maps offered still to finish.
public struct RouteBuild: Sendable {
    /// The first route Apple Maps offered. Straight out of `beginRoutes` its
    /// line, its walks and its travel time are final and its road data is not
    /// there yet, so its metadata says `wasFallback`. `settled()` is the same
    /// route, same identity, once the road data has landed.
    public let primary: RoutePlan

    /// True when Apple Maps offered more than one route, so `alternatives()`
    /// has something to finish.
    public var hasAlternatives: Bool { variedLeg != nil }

    let builder: RouteBuilder
    let mode: TravelMode
    let shape: RouteBuilder.Shape
    let legs: [RouteBuilder.Leg]
    let variedLeg: Int?
    /// The boxes the first route's road data is being fetched for.
    let primaryBoxes: [BoundingBox]
    let roadDataRun: RoadDataRun
    let metadataBudget: TimeInterval
    let memo: DirectionsMemo

    /// The first route once its road data has arrived, or the same route on
    /// per class defaults when it has not.
    ///
    /// Same `id` either way, so the caller swaps it in place rather than
    /// putting a second route on screen.
    public func settled() async -> RoutePlan {
        let data = await roadDataRun.settled()
        return RouteBuilder.plan(shape: shape, mode: mode, roadData: data)
    }

    /// The first route with its road data if it arrives within `seconds`, and
    /// as it stands if it does not.
    ///
    /// The map never waits for road data. A drive does, briefly: a drive on
    /// per class defaults is a drive at the wrong speed past the wrong number
    /// of stop signs, and a few seconds is worth not being wrong.
    public func settled(waitingUpTo seconds: TimeInterval) async -> RoutePlan {
        let deadline = ContinuousClock.now + .seconds(max(0, seconds))
        while true {
            if let data = await roadDataRun.finished() {
                return RouteBuilder.plan(shape: shape, mode: mode, roadData: data)
            }
            if ContinuousClock.now >= deadline || Task.isCancelled { return primary }
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    /// The same, having asked again for road data that did not arrive.
    public func retryingRoadData(
        times: Int = RouteBuild.roadDataRetries,
        delay: Duration = .seconds(6)
    ) async -> RoutePlan {
        let data = await roadDataRun.retried(times: times, delay: delay)
        return RouteBuilder.plan(shape: shape, mode: mode, roadData: data)
    }

    /// How many times a route whose road data did not arrive asks again before
    /// it settles for the defaults.
    public static let roadDataRetries = 2

    /// True when the road data has still not arrived.
    public var needsRoadData: Bool { primary.metadata.wasFallback }

    /// This build with its first route's road data in place.
    func withSettledPrimary() async -> RouteBuild {
        RouteBuild(
            primary: await settled(),
            builder: builder,
            mode: mode,
            shape: shape,
            legs: legs,
            variedLeg: variedLeg,
            primaryBoxes: primaryBoxes,
            roadDataRun: roadDataRun,
            metadataBudget: metadataBudget,
            memo: memo
        )
    }

    /// Every route on offer, the first one first, each complete and labelled.
    /// One to three of them.
    ///
    /// The others are finished at the same time as each other, each within the
    /// same road data budget the first route had, so this takes about as long
    /// as the slowest one rather than the sum. A route that cannot be laid out
    /// is left out rather than offered half built.
    public func alternatives() async -> [RoutePlan] {
        let first = await settled()
        guard let variedLeg else { return RouteChoice.labelled([first]) }
        let offers = legs[variedLeg].others
        let builder = self.builder
        let build = self

        var finished = [RoutePlan?](repeating: nil, count: offers.count)
        await withTaskGroup(of: (Int, RoutePlan?).self) { group in
            for (index, offer) in offers.enumerated() {
                group.addTask {
                    (index, await builder.alternative(of: build, varying: variedLeg, with: offer))
                }
            }
            for await (index, plan) in group {
                finished[index] = plan
            }
        }
        return RouteChoice.labelled([first] + finished.compactMap { $0 })
    }
}

/// The answers Apple Maps has given during one build.
///
/// An offered route usually parks where the first route parked, and the walk
/// from there to the door is the same walk. Asking for it again spends a
/// request against Apple's throttle, and a throttled request would quietly
/// leave that route without the walk the first route has. Requests still in
/// flight are shared too, since the other routes are finished side by side.
actor DirectionsMemo {
    private let directions: RouteBuilder.Directions
    private var answers: [String: Task<[RouteBuilder.Offer], Error>] = [:]

    init(_ directions: @escaping RouteBuilder.Directions) {
        self.directions = directions
    }

    func routes(
        from origin: Coordinate,
        to destination: Coordinate,
        mode: TravelMode,
        alternatives: Bool
    ) async throws -> [RouteBuilder.Offer] {
        let key = String(
            format: "%.5f,%.5f>%.5f,%.5f",
            origin.latitude, origin.longitude, destination.latitude, destination.longitude
        ) + "|\(mode.rawValue)|\(alternatives)"

        let task: Task<[RouteBuilder.Offer], Error>
        if let known = answers[key] {
            task = known
        } else {
            let directions = self.directions
            task = Task { try await directions(origin, destination, mode, alternatives) }
            answers[key] = task
        }

        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            // A failure is not an answer. Whoever asks next may ask again.
            if answers[key] == task { answers[key] = nil }
            throw error
        }
    }

    func first(from origin: Coordinate, to destination: Coordinate, mode: TravelMode) async throws -> RouteBuilder.Offer? {
        try await routes(from: origin, to: destination, mode: mode, alternatives: false).first
    }
}

public extension MKPolyline {
    var coordinates: [Coordinate] {
        var buffer = [CLLocationCoordinate2D](repeating: .init(), count: pointCount)
        getCoordinates(&buffer, range: NSRange(location: 0, length: pointCount))
        return buffer.map(Coordinate.init)
    }
}
