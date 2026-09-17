import Testing
import Foundation
@testable import CloakKit

/// A stand in for the Overpass mirrors, so the racing can be exercised without
/// spending a free public service's rate limit on it.
final class OverpassStub: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var body: String
        /// Seconds before the answer comes back.
        var delay: TimeInterval

        init(status: Int = 200, body: String = OverpassStub.oneRoad, delay: TimeInterval = 0) {
            self.status = status
            self.body = body
            self.delay = delay
        }
    }

    static let oneRoad = """
    {"version":0.6,"elements":[
      {"type":"way","id":1,"geometry":[{"lat":30.0,"lon":-97.0},{"lat":30.002,"lon":-97.0}],
       "tags":{"highway":"residential","maxspeed":"25 mph"}}
    ]}
    """

    private final class Store: @unchecked Sendable {
        private let guardrail = NSLock()
        private var replies: [String: Reply] = [:]
        private var asked: [String] = []

        func install(_ value: [String: Reply]) {
            guardrail.lock(); defer { guardrail.unlock() }
            replies = value
            asked = []
        }
        func reply(for host: String) -> Reply {
            guardrail.lock(); defer { guardrail.unlock() }
            return replies[host] ?? Reply(status: 500, body: "")
        }
        func record(_ host: String) {
            guardrail.lock(); defer { guardrail.unlock() }
            asked.append(host)
        }
        var log: [String] {
            guardrail.lock(); defer { guardrail.unlock() }
            return asked
        }
    }

    private static let store = Store()

    static func install(_ replies: [String: Reply]) { store.install(replies) }
    static var asked: [String] { store.log }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OverpassStub.self]
        return URLSession(configuration: configuration)
    }

    static func endpoints(_ names: [String]) -> [URL] {
        names.map { URL(string: "https://\($0)/api/interpreter")! }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private let stopping = NSLock()
    private var stopped = false
    private var cancelled: Bool {
        stopping.lock(); defer { stopping.unlock() }
        return stopped
    }

    override func startLoading() {
        let host = request.url?.host() ?? ""
        OverpassStub.store.record(host)
        let reply = OverpassStub.store.reply(for: host)
        let url = request.url ?? URL(string: "https://example.invalid")!
        let deliver: @Sendable () -> Void = { [weak self] in
            guard let self, !self.cancelled else { return }
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay <= 0 {
            DispatchQueue.global().async(execute: deliver)
        } else {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: deliver)
        }
    }

    override func stopLoading() {
        stopping.lock(); stopped = true; stopping.unlock()
    }
}

private let box = BoundingBox(minLatitude: 30, minLongitude: -97.01, maxLatitude: 30.01, maxLongitude: -97)

@Suite("Racing the mirrors", .serialized)
struct OverpassRacingTests {
    private func client(
        _ names: [String],
        hedgeDelay: TimeInterval = 0.1,
        timeout: TimeInterval = 5,
        minimumInterval: TimeInterval = 0,
        cooldown: TimeInterval = 30
    ) -> OverpassClient {
        OverpassClient(
            configuration: .init(
                endpoints: OverpassStub.endpoints(names),
                timeout: timeout,
                serverTimeout: 20,
                minimumInterval: minimumInterval,
                hedgeDelay: hedgeDelay,
                cooldown: cooldown
            ),
            session: OverpassStub.session()
        )
    }

    @Test func aSlowMirrorDoesNotHoldUpTheRequest() async throws {
        OverpassStub.install([
            "slow.example": .init(delay: 3),
            "quick.example": .init(delay: 0.03)
        ])
        let client = client(["slow.example", "quick.example"], hedgeDelay: 0.1)

        let started = ContinuousClock.now
        let answer = try await client.fetch(box: box)
        let took = ContinuousClock.now - started

        #expect(answer.segments.count == 1)
        // The second mirror joined after the hedge and won, rather than the
        // first one being waited out. Before, the mirrors were tried strictly
        // one after another.
        #expect(took < .seconds(1))
        #expect(OverpassStub.asked.contains("quick.example"))
    }

    @Test func aMirrorTakenByACancelledAttemptComesBack() async throws {
        OverpassStub.install([
            "slow.example": .init(delay: 2),
            "quick.example": .init(delay: 0.02)
        ])
        let client = client(["slow.example", "quick.example"], hedgeDelay: 0.05)
        _ = try await client.fetch(box: box)

        // The slow mirror lost and was cancelled. If it never came back to the
        // pool the next box could only ever use the other one, and a route cut
        // into pieces would queue them all on it.
        let second = BoundingBox(minLatitude: 31, minLongitude: -97.01, maxLatitude: 31.01, maxLongitude: -97)
        OverpassStub.install([
            "slow.example": .init(delay: 0.02),
            "quick.example": .init(status: 429, body: "")
        ])
        let answer = try await client.fetch(box: second)
        #expect(answer.segments.count == 1)
        #expect(OverpassStub.asked.contains("slow.example"))
    }

    @Test func aRefusalMovesOnToTheNextMirrorAtOnce() async throws {
        OverpassStub.install([
            "busy.example": .init(status: 429, body: "rate_limited"),
            "good.example": .init(delay: 0.02)
        ])
        // No hedging at all, so this is the failover path on its own.
        let client = client(["busy.example", "good.example"], hedgeDelay: 0)
        let answer = try await client.fetch(box: box)
        #expect(answer.segments.count == 1)
        #expect(OverpassStub.asked == ["busy.example", "good.example"])
    }

    @Test func aTruncatedAnswerCountsAsARefusalAndTheNextMirrorIsAsked() async throws {
        OverpassStub.install([
            "cut.example": .init(body: """
            {"version":0.6,"elements":[],"remark":"runtime error: Query timed out in \\"print\\" after 25 seconds."}
            """),
            "good.example": .init(delay: 0.02)
        ])
        let client = client(["cut.example", "good.example"], hedgeDelay: 0)
        let answer = try await client.fetch(box: box)
        #expect(answer.segments.count == 1)
        #expect(!answer.wasFallback)
        #expect(OverpassStub.asked.contains("cut.example"))
        #expect(OverpassStub.asked.contains("good.example"))
    }

    @Test func whenEveryMirrorRefusesTheFailureIsReported() async {
        OverpassStub.install([
            "a.example": .init(status: 429, body: ""),
            "b.example": .init(status: 504, body: ""),
            "c.example": .init(status: 500, body: "")
        ])
        let client = client(["a.example", "b.example", "c.example"], hedgeDelay: 0)
        do {
            _ = try await client.fetch(box: box)
            Issue.record("a fetch with no mirror left must not come back as an answer")
        } catch {
            #expect(error as? OverpassError != nil)
        }
        #expect(Set(OverpassStub.asked).count == 3)
    }

    @Test func threeBoxesAreNotAsSlowAsTheWorstMirror() async throws {
        // The shape of a real network rather than three mirrors that happen to
        // differ: one that answers, and two that accept the connection and are
        // still thinking about it when the route has long since been given up
        // on. The gap and the hedge are the shipped ones, scaled down.
        OverpassStub.install([
            "quick.example": .init(delay: 0.04),
            "queued.example": .init(delay: 3),
            "silent.example": .init(delay: 3)
        ])
        let client = client(
            ["quick.example", "queued.example", "silent.example"],
            hedgeDelay: 0.5,
            timeout: 10,
            minimumInterval: 0.2
        )
        let boxes = (0..<3).map {
            BoundingBox(minLatitude: 30 + Double($0), minLongitude: -97.01,
                        maxLatitude: 30.01 + Double($0), maxLongitude: -97)
        }

        let started = ContinuousClock.now
        let answered = await withTaskGroup(of: Bool.self) { group in
            for box in boxes {
                group.addTask { (try? await client.fetch(box: box)) != nil }
            }
            var good = 0
            for await ok in group where ok { good += 1 }
            return good
        }
        let took = ContinuousClock.now - started

        #expect(answered == 3)
        // This is the whole point of the change. Box one took the quick
        // mirror, box two the queued one and box three the silent one, and
        // no box would ask for a mirror another box of the same route was
        // holding, so the route cost what the worst of the three cost. Now the
        // first answer tells the pool which mirror is quick, the mirrors that
        // lost carry a floor under how slow they are, and the boxes after the
        // first move onto the winner as soon as it has a slot.
        #expect(took < .seconds(1.2))
        // And the two that never answered were asked once each, not once per
        // box: the cost of finding out is paid by the route, once.
        #expect(OverpassStub.asked.filter { $0 == "queued.example" }.count == 1)
        #expect(OverpassStub.asked.filter { $0 == "silent.example" }.count == 1)
    }

    @Test func aMirrorThatRefusedIsNotPaidForOncePerBox() async throws {
        OverpassStub.install([
            "refusing.example": .init(status: 503, body: ""),
            "good.example": .init(delay: 0.05)
        ])
        let client = client(["refusing.example", "good.example"], hedgeDelay: 0, cooldown: 30)
        let boxes = (0..<4).map {
            BoundingBox(minLatitude: 30 + Double($0), minLongitude: -97.01,
                        maxLatitude: 30.01 + Double($0), maxLongitude: -97)
        }
        for box in boxes { _ = try await client.fetch(box: box) }

        // The first box found out. The three after it did not pay to find out
        // again: a mirror that refused is rested, and four boxes cost one
        // wasted request rather than four.
        #expect(OverpassStub.asked.filter { $0 == "refusing.example" }.count == 1)
        #expect(OverpassStub.asked.filter { $0 == "good.example" }.count == 4)
    }

    @Test func severalBoxesSpreadAcrossTheMirrors() async throws {
        OverpassStub.install([
            "a.example": .init(delay: 0.12),
            "b.example": .init(delay: 0.12),
            "c.example": .init(delay: 0.12)
        ])
        // Hedging is off here, so each box is one request and the only thing on
        // trial is that three boxes go out at once.
        let client = client(["a.example", "b.example", "c.example"], hedgeDelay: 0)
        let boxes = (0..<3).map {
            BoundingBox(minLatitude: 30 + Double($0), minLongitude: -97.01,
                        maxLatitude: 30.01 + Double($0), maxLongitude: -97)
        }
        let started = ContinuousClock.now
        await withTaskGroup(of: Void.self) { group in
            for box in boxes {
                group.addTask { _ = try? await client.fetch(box: box) }
            }
        }
        let took = ContinuousClock.now - started
        // Side by side rather than one after another.
        #expect(took < .milliseconds(340))
        #expect(Set(OverpassStub.asked).count == 3)
        #expect(OverpassStub.asked.count == 3)
    }
}
