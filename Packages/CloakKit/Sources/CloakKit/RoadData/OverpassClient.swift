import Foundation
import os

public enum OverpassError: Error, Sendable {
    case rateLimited
    case badResponse(Int)
    case malformed
    /// The mirror answered 200 with a `remark` saying its own query timed out
    /// or ran out of memory. The body that came with it is whatever had been
    /// printed when it died: a slice of the roads, in id order, which is not
    /// the slice the route runs on.
    ///
    /// This used to be read as a complete answer. It is the reason a route
    /// came back with speed limits on some streets and none on others, and
    /// the reason it stayed that way: the cache kept it for ninety days.
    case truncated(String)
    /// The answer parsed and held nothing. An empty box is possible but a box
    /// drawn around a route that Apple Maps just drove down is not empty, so
    /// this is treated as a failure rather than cached as a fact.
    case empty
    case noEndpoint
    /// Anything below Overpass: no route to the host, the connection dropped,
    /// TLS refused, the request timed out.
    case transport(String)
}

public actor OverpassClient {
    public struct Configuration: Sendable {
        public var endpoints: [URL]
        /// How long one request may take. This has to be longer than the
        /// server's own timeout below, or the client hangs up on an answer
        /// that was about to arrive, which is what it used to do: 8 seconds
        /// against a server allowed 25.
        public var timeout: TimeInterval
        /// What the mirror is told it may spend, in seconds. Kept under the
        /// client timeout so a slow query comes back as a refusal this code
        /// can see rather than as a socket that went quiet.
        public var serverTimeout: Int
        /// The shortest gap between two requests to the same mirror, measured
        /// from when one starts to when the next may start.
        ///
        /// It used to be measured from when one finished, which reads as the
        /// politer rule and is, for one box. For a route cut into three it
        /// meant the one mirror that answers quickly could serve at most one
        /// box every five seconds, so the route was as slow as the mirrors
        /// nobody wanted.
        public var minimumInterval: TimeInterval
        /// How long to give one mirror before trying the next one alongside
        /// it. Mirrors were tried one at a time, so a mirror that answers 429
        /// after ten seconds cost ten seconds before the next was asked.
        public var hedgeDelay: TimeInterval
        /// How long a mirror that refused is left alone. A 429 from Overpass
        /// usually means its slots are full this second rather than that it is
        /// done with you, and locking it out for a minute left a route cut into
        /// pieces queuing them all on the one mirror that had not said no yet.
        public var cooldown: TimeInterval
        /// How many requests one mirror may be carrying at once.
        ///
        /// Two, and only for a mirror that has already answered this session
        /// without failing since. Overpass instances hand out two slots per
        /// address as their own default, so this is the allowance the servers
        /// describe rather than a new one invented here, and `minimumInterval`
        /// still caps how often a request may start. It matters because on a
        /// real network the mirrors are not comparable: one answers in a
        /// second, one is queued sixteen deep and one accepts the connection
        /// and never speaks. Spreading three boxes evenly over those three is
        /// how a route ends up as slow as the worst of them.
        public var concurrentPerEndpoint: Int

        public init(
            // Measured from a real network, not chosen from a list on a wiki.
            // Asked for a count of residential ways in one square kilometre of
            // Austin, which is as small as an Overpass request gets, so what
            // this measures is the queue in front of the mirror rather than
            // the data behind it:
            //
            //   overpass.openstreetmap.fr   200 in  0.9 s
            //   maps.mail.ru                200 in  7.4 s
            //   overpass.kumi.systems       200 in 16.3 s
            //   overpass-api.de             406 in  1.1 s
            //   overpass.private.coffee     connects, then never answers
            //
            // The order is left as it was. It is only the guess a route starts
            // from, and it stops mattering within the first box: `EndpointPool`
            // measures the mirrors as it uses them and hands out the one it has
            // watched answer, so a cold start costs one request to a slow
            // mirror and nothing after that. Reordering by these numbers would
            // put maps.mail.ru second, which is a decision about where a
            // route's bounding box is allowed to go rather than a decision
            // about speed, and it was worth nothing measurable when tried.
            endpoints: [URL] = [
                URL(string: "https://overpass.openstreetmap.fr/api/interpreter")!,
                URL(string: "https://overpass.kumi.systems/api/interpreter")!,
                URL(string: "https://maps.mail.ru/osm/tools/overpass/api/interpreter")!,
                URL(string: "https://overpass-api.de/api/interpreter")!,
                URL(string: "https://overpass.private.coffee/api/interpreter")!
            ],
            timeout: TimeInterval = 25,
            serverTimeout: Int = 20,
            minimumInterval: TimeInterval = 1,
            hedgeDelay: TimeInterval = 2.5,
            cooldown: TimeInterval = 20,
            concurrentPerEndpoint: Int = 2
        ) {
            self.endpoints = endpoints
            self.timeout = timeout
            self.serverTimeout = serverTimeout
            self.minimumInterval = minimumInterval
            self.hedgeDelay = hedgeDelay
            self.cooldown = cooldown
            self.concurrentPerEndpoint = concurrentPerEndpoint
        }
    }

    private let configuration: Configuration
    private let session: URLSession
    private let pool: EndpointPool

    public init(configuration: Configuration = Configuration(), session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
        self.pool = EndpointPool(
            endpoints: configuration.endpoints,
            minimumInterval: configuration.minimumInterval,
            cooldown: configuration.cooldown,
            concurrent: configuration.concurrentPerEndpoint
        )
    }

    /// Everything the route needs from one box.
    ///
    /// The mirrors are raced rather than queued. The first one starts at once
    /// and the next joins it after `hedgeDelay`, and the first good answer wins
    /// and cancels the rest.
    ///
    /// Which mirror a box is given is up to `EndpointPool`, and it is given the
    /// one it has the best reason to believe in rather than the next one along.
    /// A route cut into boxes therefore converges on whichever mirror is
    /// actually fast from this network: the first box measures them, and every
    /// box after it is handed the winner as soon as the winner has a slot.
    /// Boxes still spread out while the mirrors look alike, because a second
    /// request to a mirror already carrying one is scored as twice its cost.
    public func fetch(box: BoundingBox) async throws -> RoadMetadata {
        let query = Self.query(for: box, serverTimeout: configuration.serverTimeout)
        let started = RouteTiming.now()
        do {
            let answer = try await race(query: query)
            RouteTiming.done(
                "overpass.box",
                started,
                "\(String(format: "%.1f", box.areaSquareKilometres))km2 \(answer.bytes / 1024)KB \(answer.metadata.segments.count) roads \(answer.metadata.controls.count) controls via \(answer.endpoint.host() ?? "?")"
            )
            return answer.metadata
        } catch {
            RouteTiming.done(
                "overpass.box.failed",
                started,
                "\(String(format: "%.1f", box.areaSquareKilometres))km2 \(error)"
            )
            throw error
        }
    }

    struct Answer: Sendable {
        var metadata: RoadMetadata
        var endpoint: URL
        var bytes: Int
    }

    private enum Step: Sendable {
        case answer(URL, Answer)
        case failed(URL, OverpassError)
        case hedge
    }

    /// Seconds since a moment, as a plain number.
    static func elapsed(since instant: ContinuousClock.Instant) -> TimeInterval {
        let span = ContinuousClock.now - instant
        return Double(span.components.seconds) + Double(span.components.attoseconds) / 1e18
    }

    private func race(query: String) async throws -> Answer {
        let limit = configuration.endpoints.count
        guard limit > 0 else { throw OverpassError.noEndpoint }
        guard let first = await pool.waitForEndpoint(timeout: configuration.timeout) else {
            throw OverpassError.noEndpoint
        }

        let session = self.session
        let timeout = configuration.timeout
        let hedgeDelay = configuration.hedgeDelay
        /// How long to wait before looking again when every mirror worth having
        /// is busy with another box of the same route. Waiting another whole
        /// `hedgeDelay` was the expensive part: the mirror this box wants is
        /// the one another box is about to hand back, and it was handed back
        /// two and a half seconds before anyone looked.
        let lookAgain = min(hedgeDelay, 0.25)
        let pool = self.pool

        return try await withThrowingTaskGroup(of: Step.self) { group in
            var outstanding = 0
            var launched = 0
            /// Mirrors taken out of the pool and not yet handed back, and when
            /// each was started. A race ends by cancelling the attempts that
            /// lost, and those never report, so they are handed back here.
            /// Forgetting to would take a mirror out of the pool for good, one
            /// route at a time. How long each had been running is handed back
            /// with it: an attempt cancelled after six seconds is the only
            /// evidence there is that a mirror is slow, because a mirror that
            /// is slow enough never gets to report anything else.
            var held: [URL: ContinuousClock.Instant] = [:]
            /// Mirrors this box has already asked. One request per mirror per
            /// box: asking the same one twice for the same ground is spending
            /// the rate limit on an answer already on its way.
            var attempted: Set<String> = []
            var lastError = OverpassError.noEndpoint

            func launch(_ endpoint: URL) {
                launched += 1
                outstanding += 1
                held[endpoint] = ContinuousClock.now
                attempted.insert(endpoint.absoluteString)
                group.addTask {
                    do {
                        let data = try await Self.post(query: query, to: endpoint, timeout: timeout, session: session)
                        let parsed = RouteTiming.now()
                        let metadata = try Self.decode(data)
                        RouteTiming.done("overpass.parse", parsed, "\(data.count / 1024)KB \(metadata.segments.count) roads")
                        return .answer(endpoint, Answer(metadata: metadata, endpoint: endpoint, bytes: data.count))
                    } catch let error as OverpassError {
                        return .failed(endpoint, error)
                    } catch {
                        return .failed(endpoint, .transport(error.localizedDescription))
                    }
                }
            }

            func armHedge(after delay: TimeInterval) {
                guard delay.isFinite, delay > 0, launched < limit else { return }
                group.addTask {
                    try? await Task.sleep(for: .seconds(delay))
                    return .hedge
                }
            }

            /// Hands back whatever is still out, so the next box finds a full
            /// pool and the pool knows how long each of these had been trying.
            func releaseHeld() async {
                for (endpoint, started) in held {
                    await pool.cancelled(endpoint, after: Self.elapsed(since: started))
                }
                held.removeAll()
            }

            launch(first)
            armHedge(after: hedgeDelay)

            while let step = try await group.next() {
                switch step {
                case .hedge:
                    if launched < limit, let next = await pool.takeEndpoint(excluding: attempted) {
                        launch(next)
                        armHedge(after: hedgeDelay)
                    } else if outstanding > 0 {
                        armHedge(after: lookAgain)
                    }

                case .answer(let endpoint, let answer):
                    outstanding -= 1
                    let took = held[endpoint].map(Self.elapsed(since:)) ?? 0
                    held[endpoint] = nil
                    await pool.answered(endpoint, after: took)
                    group.cancelAll()
                    await releaseHeld()
                    return answer

                case .failed(let endpoint, let error):
                    outstanding -= 1
                    let took = held[endpoint].map(Self.elapsed(since:)) ?? 0
                    held[endpoint] = nil
                    lastError = error
                    await pool.failed(endpoint, refused: Self.isRefusal(error), after: took)
                    if launched < limit, let next = await pool.takeEndpoint(excluding: attempted) {
                        launch(next)
                        armHedge(after: hedgeDelay)
                        continue
                    }
                    guard outstanding == 0 else { continue }
                    if launched >= limit {
                        group.cancelAll()
                        await releaseHeld()
                        throw lastError
                    }
                    // Every mirror is busy with another box of the same route.
                    // Wait for one rather than giving up on this box.
                    if let next = await pool.waitForEndpoint(timeout: timeout, excluding: attempted) {
                        launch(next)
                        armHedge(after: hedgeDelay)
                    } else {
                        group.cancelAll()
                        await releaseHeld()
                        throw lastError
                    }
                }
            }
            await releaseHeld()
            throw lastError
        }
    }

    /// True when the mirror said no rather than failing to answer.
    ///
    /// Both are rested before the mirror is asked again, but a refusal is
    /// rested from a much longer base: a 429 is the mirror telling you what it
    /// wants, while a dropped connection is as likely to have been the phone
    /// changing networks. A mirror that keeps failing gets there anyway,
    /// because every failure in a row lengthens the rest.
    static func isRefusal(_ error: OverpassError) -> Bool {
        switch error {
        case .rateLimited, .truncated, .badResponse: true
        case .malformed, .empty, .noEndpoint, .transport: false
        }
    }

    nonisolated private static func post(
        query: String,
        to endpoint: URL,
        timeout: TimeInterval,
        session: URLSession
    ) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"
            .data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OverpassError.malformed }
        if http.statusCode == 429 || http.statusCode == 504 { throw OverpassError.rateLimited }
        guard (200..<300).contains(http.statusCode) else { throw OverpassError.badResponse(http.statusCode) }
        return data
    }

    /// The road classes worth asking for.
    ///
    /// Listed one by one rather than as a regular expression on the value: a
    /// regex cannot use the tag index, and the same box that answers in eight
    /// seconds as a list did not answer in a hundred as a regex. Measured, not
    /// assumed.
    ///
    /// Pavements and paths are left out on purpose. A walked stretch is written
    /// into the road data by `LastMile` as a footway of its own, and any OSM
    /// footway inside a walked stretch is removed again, so fetching them costs
    /// megabytes and changes nothing.
    static let drivableHighways = [
        "motorway", "trunk", "primary", "secondary", "tertiary",
        "unclassified", "residential", "living_street", "service",
        "motorway_link", "trunk_link", "primary_link", "secondary_link", "tertiary_link"
    ]

    static let controlNodes = ["traffic_signals", "stop", "give_way", "crossing"]

    /// Everything in a box, asked for with two spatial lookups.
    ///
    /// The box is evaluated once for ways and once for nodes, into a set each,
    /// and the fourteen road classes and four control kinds are picked out of
    /// those sets afterwards.
    ///
    /// The obvious way round - eighteen statements, each carrying its own copy
    /// of the box - asks the mirror to do the same spatial lookup eighteen
    /// times, and that turned out to be most of what a request costs. Measured
    /// on the same box against the same mirror moments apart, byte for byte
    /// the same answer:
    ///
    ///     1.5 km2,    613 roads,   572 KB   18 statements  3595 ms   this 2858 ms
    ///     206.8 km2, 29754 roads, 20918 KB  18 statements 15736 ms   this 6221 ms
    ///
    /// The saving grows with the box, which is the shape of a fixed cost being
    /// paid eighteen times instead of twice.
    ///
    /// The classes are still named one by one rather than matched. A regular
    /// expression on the tag value cannot use the index: the same box that
    /// answered in eight seconds as a list of names did not answer in a
    /// hundred as a regex. Naming them inside the set costs nothing, because
    /// the set is already in memory by then.
    static func query(for box: BoundingBox, serverTimeout: Int = 20) -> String {
        let clause = box.overpassClause
        let ways = drivableHighways
            .map { "  way.near[\"highway\"=\"\($0)\"];" }
            .joined(separator: "\n")
        let nodes = controlNodes
            .map { "  node.beside[\"highway\"=\"\($0)\"];" }
            .joined(separator: "\n")
        // `out tags geom` rather than `out body geom`: body prints every way's
        // list of node ids as well, which nothing here reads and which is a
        // large part of the bytes.
        return """
        [out:json][timeout:\(serverTimeout)];
        way["highway"](\(clause))->.near;
        node["highway"](\(clause))->.beside;
        (
        \(ways)
        \(nodes)
        );
        out tags geom;
        """
    }

    static func decode(_ data: Data) throws -> RoadMetadata {
        struct Response: Decodable {
            struct Element: Decodable {
                struct Geometry: Decodable {
                    let lat: Double
                    let lon: Double
                }
                let type: String
                let lat: Double?
                let lon: Double?
                let geometry: [Geometry]?
                let tags: [String: String]?
            }
            let elements: [Element]
            /// Overpass puts its own failures here, with a 200 and a partial
            /// body. Reading it is the difference between knowing the answer
            /// is short and believing the roads simply are not there.
            let remark: String?
        }

        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw OverpassError.malformed
        }
        if let remark = response.remark, isFailure(remark) {
            throw OverpassError.truncated(remark)
        }

        var segments: [RoadSegment] = []
        var controls: [TrafficControl] = []

        for element in response.elements {
            let tags = element.tags ?? [:]
            if element.type == "way" {
                guard let highway = tags["highway"], let geometry = element.geometry else { continue }
                let nodes = geometry.map { Coordinate(latitude: $0.lat, longitude: $0.lon) }
                guard nodes.count > 1 else { continue }
                let limit = tags["maxspeed"].flatMap(MaxSpeedParser.parse)
                segments.append(RoadSegment(roadClass: RoadClass(osmHighway: highway), limit: limit, nodes: nodes))
                if tags["junction"] == "roundabout" {
                    controls.append(TrafficControl(kind: .roundabout, coordinate: nodes[nodes.count / 2], alongTrack: 0))
                }
            } else if element.type == "node" {
                guard let lat = element.lat, let lon = element.lon, let highway = tags["highway"] else { continue }
                let coordinate = Coordinate(latitude: lat, longitude: lon)
                let kind: TrafficControlKind?
                switch highway {
                case "traffic_signals": kind = .signal
                case "stop": kind = .stop
                case "give_way": kind = .giveWay
                case "crossing": kind = .crossing
                default: kind = nil
                }
                if let kind {
                    let minorOnly = tags["stop"] == "minor" || tags["direction"] != nil
                    let signalled = tags["crossing"] == "traffic_signals"
                        || tags["crossing_ref"] == "pelican"
                        || tags["crossing_ref"] == "toucan"
                    controls.append(TrafficControl(
                        kind: kind,
                        coordinate: coordinate,
                        alongTrack: 0,
                        appliesToMinorRoadOnly: minorOnly,
                        isSignalled: signalled
                    ))
                }
            }
        }

        // A box drawn around a line Apple Maps just routed a car down has roads
        // in it. Nothing at all means the answer is not an answer.
        guard !segments.isEmpty else { throw OverpassError.empty }
        return RoadMetadata(segments: segments, controls: controls, fetchedAt: .now, wasFallback: false)
    }

    /// True when a remark is Overpass reporting its own failure rather than a
    /// note. Overpass writes runtime errors and out of memory here.
    static func isFailure(_ remark: String) -> Bool {
        let text = remark.lowercased()
        return text.contains("error") || text.contains("timed out") || text.contains("out of memory")
    }
}

/// Which mirror gets asked, and what is known about it.
///
/// Three rules keep racing the mirrors from turning into hammering them. A
/// mirror may start no more than one request every `minimumInterval`. It may
/// be carrying no more than `concurrent` at a time, and only if it has already
/// answered without failing since; anything else gets one. A mirror that
/// refused, or that could not be reached, is rested before it is asked again,
/// and rested longer every time it does it again, so a mirror that is simply
/// down stops being paid for once per box.
///
/// The fourth rule is memory, and it is the one that makes a route cut into
/// several boxes fast. Every attempt says something about how long a mirror
/// takes: an answer measures it, and an attempt cancelled because another
/// mirror won puts a floor under it. The pool hands out the mirror with the
/// lowest number, so the boxes converge on whichever mirror is quick from this
/// network instead of being dealt out evenly over one that is quick, one that
/// is queued sixteen deep and one that accepts the connection and goes quiet.
///
/// Spreading is still the default where it is right. A mirror nothing is known
/// about is assumed to be as good as the best mirror that is known, so it gets
/// tried, and a second request to a mirror already carrying one is scored as
/// twice its cost, so the boxes fan out while the mirrors look alike and pile
/// onto one only when it is measurably worth it.
actor EndpointPool {
    private let endpoints: [URL]
    private let minimumInterval: TimeInterval
    private let cooldown: TimeInterval
    private let concurrent: Int

    /// How many requests each mirror is carrying.
    private var inFlight: [String: Int] = [:]
    /// The earliest each mirror may be asked again.
    private var readyAt: [String: Date] = [:]
    /// Seconds a mirror is believed to take.
    private var seconds: [String: TimeInterval] = [:]
    /// Failures in a row, which is what lengthens the rest.
    private var failures: [String: Int] = [:]
    /// Mirrors that have answered and not failed since. Only these are trusted
    /// with a second request at a time.
    private var trusted: Set<String> = []

    init(endpoints: [URL], minimumInterval: TimeInterval, cooldown: TimeInterval, concurrent: Int = 1) {
        self.endpoints = endpoints
        self.minimumInterval = minimumInterval
        self.cooldown = cooldown
        self.concurrent = max(1, concurrent)
    }

    /// The mirror most worth asking right now, or nil if none may be.
    func takeEndpoint(excluding: Set<String> = [], now: Date = .now) -> URL? {
        guard !endpoints.isEmpty else { return nil }
        // What an unknown mirror is assumed to cost: as much as the best known
        // one. Any lower and a route would keep picking untried mirrors over
        // the one it has just watched answer; any higher and a mirror would
        // never get a first chance.
        let assumed = seconds.values.min() ?? 0
        var best: (endpoint: URL, score: Double)?

        for endpoint in endpoints {
            let key = endpoint.absoluteString
            if excluding.contains(key) { continue }
            if let ready = readyAt[key], ready > now { continue }
            let carrying = inFlight[key] ?? 0
            let allowance = trusted.contains(key) ? concurrent : 1
            if carrying >= allowance { continue }
            // The floor matters: without it a mirror measured at zero scores
            // zero however many requests it is already carrying, and the
            // preference for spreading quietly stops existing.
            let score = max(seconds[key] ?? assumed, 0.001) * Double(carrying + 1)
            if let current = best, current.score <= score { continue }
            best = (endpoint, score)
        }

        guard let chosen = best?.endpoint else { return nil }
        let key = chosen.absoluteString
        inFlight[key, default: 0] += 1
        // The gap is measured from one request starting to the next starting,
        // not from one finishing, so a mirror that takes four seconds is still
        // a mirror three boxes can use.
        readyAt[key] = now.addingTimeInterval(minimumInterval)
        return chosen
    }

    /// A mirror, waiting for one to come free.
    func waitForEndpoint(timeout: TimeInterval, excluding: Set<String> = []) async -> URL? {
        if let endpoint = takeEndpoint(excluding: excluding) { return endpoint }
        let deadline = ContinuousClock.now + .seconds(max(1, timeout))
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(80))
            if Task.isCancelled { return nil }
            if let endpoint = takeEndpoint(excluding: excluding) { return endpoint }
        }
        return nil
    }

    /// A mirror that answered, and how long it took.
    func answered(_ endpoint: URL, after took: TimeInterval) {
        let key = endpoint.absoluteString
        release(key)
        failures[key] = 0
        trusted.insert(key)
        // `readyAt` is left where taking the mirror put it: one request may
        // start every `minimumInterval`, however long the last one ran for.
        let measured = max(0, took)
        // Weighted towards the measurement rather than split evenly with it: a
        // mirror's number is often a floor left by a cancelled attempt, and a
        // real answer is better evidence than a floor. Three answers undo one
        // bad guess.
        seconds[key] = seconds[key].map { ($0 + 3 * measured) / 4 } ?? measured
    }

    /// A mirror that refused, or that could not be reached at all.
    func failed(_ endpoint: URL, refused: Bool, after took: TimeInterval = 0, now: Date = .now) {
        let key = endpoint.absoluteString
        release(key)
        trusted.remove(key)
        let count = (failures[key] ?? 0) + 1
        failures[key] = count
        let base = refused ? cooldown : cooldown / 4
        readyAt[key] = now.addingTimeInterval(base * Double(min(count, 4)))
        if took > 0 { seconds[key] = max(seconds[key] ?? 0, took) }
    }

    /// An attempt given up because another mirror answered first.
    ///
    /// Nothing went wrong, so it earns no rest. It is still evidence: this
    /// mirror had not answered in `took` seconds, and for a mirror slow enough
    /// to always lose that is the only evidence there will ever be.
    func cancelled(_ endpoint: URL, after took: TimeInterval) {
        let key = endpoint.absoluteString
        release(key)
        if took > 0 { seconds[key] = max(seconds[key] ?? 0, took) }
    }

    private func release(_ key: String) {
        let carrying = (inFlight[key] ?? 0) - 1
        if carrying <= 0 { inFlight[key] = nil } else { inFlight[key] = carrying }
    }

    /// For tests: how many mirrors are in hand right now.
    var inUse: Int { inFlight.count }

    /// For tests: what the pool believes a mirror costs.
    func believedSeconds(_ endpoint: URL) -> TimeInterval? { seconds[endpoint.absoluteString] }
}
