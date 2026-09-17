import Testing
import Foundation
import MapKit
@testable import CloakKit

/// Measurements against the live services, off by default.
///
/// These are how the numbers in the route speed work were arrived at, and how
/// they can be arrived at again. They talk to Apple Maps and to the Overpass
/// mirrors, so they are not part of the ordinary test run: nothing in CI
/// should depend on a free public service being in a good mood, and nothing
/// should spend its rate limit by accident.
///
///     CLOAK_NET=1 swift test --filter RoadDataNetworkMeasurements
private let networkMeasurementsEnabled = ProcessInfo.processInfo.environment["CLOAK_NET"] == "1"

/// Serialized on purpose. Swift Testing runs a suite's tests side by side, so
/// these used to be measured against each other: the 27 km route in three
/// boxes was timed while the same route in one 207 km2 box was in flight to
/// the same five mirrors. Every number taken before that was partly a
/// measurement of contention this file put there itself. One at a time.
@Suite("Road data network measurements", .serialized)
struct RoadDataNetworkMeasurements {
    private func temporary() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloak-measure-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The line Apple Maps gives for a trip, and how long it took to give it.
    private func route(from: Coordinate, to: Coordinate) async throws -> (Polyline, Int) {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from.clCoordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to.clCoordinate))
        request.transportType = .automobile
        request.requestsAlternateRoutes = true

        let started = ContinuousClock.now
        let response = try await MKDirections(request: request).calculate()
        let millis = Int((ContinuousClock.now - started) / .milliseconds(1))
        let line = Polyline(points: try #require(response.routes.first).polyline.coordinates)
        return (line, millis)
    }

    /// One line of the table.
    ///
    /// `reference` is another way of asking for the same route, when there is
    /// one. The bar for two ways of asking being the same answer is not that
    /// the numbers look similar: it is that the speed limit under every one of
    /// several thousand sample points is the same limit. Anything looser
    /// hides a road that went missing in the middle of a route.
    private func report(
        _ label: String,
        _ data: RoadMetadata,
        _ millis: Int,
        _ densified: Polyline,
        _ reference: [Double]?,
        _ extra: String
    ) -> (text: String, limits: [Double]) {
        let started = ContinuousClock.now
        let limits = data.limits(along: densified, fallback: .residential)
        let controls = data.snappedControls(to: densified)
        let profile = Int((ContinuousClock.now - started) / .milliseconds(1))

        let furthest = controls
            .map { densified.nearestDistance(to: $0.coordinate).offset }
            .max() ?? 0
        let agreement = reference.map { was in
            let differing = zip(was, limits).reduce(0) { $0 + (abs($1.0 - $1.1) > 0.01 ? 1 : 0) }
            return "\(differing) of \(limits.count) points differ from the reference"
        } ?? "reference"

        let text = """
          \(label.padding(toLength: 16, withPad: " ", startingAt: 0))\(millis) ms, \
        \(data.segments.count) roads, \(data.controls.count) controls, fallback \(data.wasFallback)
          \(String(repeating: " ", count: 16))\(extra)
          \(String(repeating: " ", count: 16))-> \(controls.count) controls on route, \
        limits \(Int(Speed.toMph(limits.min() ?? 0)))-\(Int(Speed.toMph(limits.max() ?? 0))) mph, \
        profile \(profile) ms
          \(String(repeating: " ", count: 16))-> \(agreement), \
        furthest control used \(Int(furthest)) m off the line
        """
        return (text, limits)
    }

    /// The route as it is fetched now, and the same route in one box.
    ///
    /// The one-box line is not a candidate. It is there because it is the
    /// cheapest way to see what a request costs when the ground it covers goes
    /// up by a factor of forty, which is the number the box splitting is
    /// spending three requests to avoid.
    private func measure(_ name: String, from: Coordinate, to: Coordinate) async throws {
        let (route, appleMillis) = try await route(from: from, to: to)
        let densified = route.densified(spacing: 5)
        let client = OverpassClient()
        let whole = RouteBuilder.roadDataBox(for: route)
        let boxes = RoadDataBoxes.boxes(for: route)

        func fetch(_ wanted: [BoundingBox]) async -> (RoadMetadata, Int) {
            let cache = RoadDataCache(directory: temporary())
            let started = ContinuousClock.now
            let data = await RoadDataRun.fetch(
                boxes: wanted,
                source: { box in await cache.metadata(for: box) { try await client.fetch(box: $0) } },
                budget: 60
            )
            return (data, Int((ContinuousClock.now - started) / .milliseconds(1)))
        }

        let (boxed, boxMillis) = await fetch(boxes)
        let shipped = report(
            "boxes", boxed, boxMillis, densified, nil,
            "\(boxes.count) boxes, \(String(format: "%.1f", boxes.reduce(0) { $0 + $1.areaSquareKilometres })) km2"
        )

        let (single, singleMillis) = await fetch([whole])
        let one = report(
            "one box", single, singleMillis, densified, shipped.limits,
            "1 box, \(String(format: "%.1f", whole.areaSquareKilometres)) km2"
        )

        print("""
        MEASURE \(name)
          route            \(Int(route.length)) m, \(route.points.count) points
          apple maps       \(appleMillis) ms
        \(shipped.text)
        \(one.text)
        """)
    }

    /// A short city trip: downtown Austin, about a mile.
    @Test(.enabled(if: networkMeasurementsEnabled))
    func shortCityRoute() async throws {
        try await measure(
            "short city route",
            from: Coordinate(latitude: 30.2650, longitude: -97.7450),
            to: Coordinate(latitude: 30.2720, longitude: -97.7350)
        )
    }

    /// A longer trip: Austin to Round Rock, about 27 km, which is the shape
    /// that used to come back with no road data at all.
    @Test(.enabled(if: networkMeasurementsEnabled))
    func longerRoute() async throws {
        try await measure(
            "27 km route",
            from: Coordinate(latitude: 30.2672, longitude: -97.7431),
            to: Coordinate(latitude: 30.5083, longitude: -97.6789)
        )
    }
}
