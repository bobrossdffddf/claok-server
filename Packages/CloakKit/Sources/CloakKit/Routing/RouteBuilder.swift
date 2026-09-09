import Foundation
import MapKit

public enum RouteBuilderError: Error, Sendable {
    case notEnoughWaypoints
    case routingFailed(String)
}

public struct RouteBuilder: Sendable {
    private let cache: RoadDataCache
    private let overpass: OverpassClient

    public init(cache: RoadDataCache = RoadDataCache(), overpass: OverpassClient = OverpassClient()) {
        self.cache = cache
        self.overpass = overpass
    }

    /// Builds a route.
    ///
    /// Posted speed limits are a nice-to-have, not a prerequisite. Overpass can
    /// take the better part of a minute across its three endpoints, and waiting
    /// on it made routes look broken. So the road data gets a budget, and a
    /// route that misses it still starts, using the per-class defaults.
    public func build(
        waypoints: [RouteWaypoint],
        mode: TravelMode,
        metadataBudget: TimeInterval = 7
    ) async throws -> RoutePlan {
        guard waypoints.count >= 2 else { throw RouteBuilderError.notEnoughWaypoints }

        var combined: [Coordinate] = []
        var travelTime: TimeInterval = 0

        for index in 0..<(waypoints.count - 1) {
            let leg = try await route(from: waypoints[index].coordinate, to: waypoints[index + 1].coordinate, mode: mode)
            travelTime += leg.expectedTravelTime
            let points = leg.polyline.coordinates
            if combined.isEmpty {
                combined.append(contentsOf: points)
            } else {
                combined.append(contentsOf: points.dropFirst())
            }
        }

        let polyline = Polyline(points: combined)
        let box = polyline.boundingBox().padded(byMeters: 120)
        let overpassClient = overpass
        let store = cache

        let metadata = await Self.within(seconds: metadataBudget) {
            await store.metadata(for: box) { requested in
                try await overpassClient.fetch(box: requested)
            }
        } ?? .empty

        return RoutePlan(
            waypoints: waypoints,
            polyline: polyline,
            metadata: metadata,
            mode: mode,
            expectedTravelTime: travelTime
        )
    }

    /// Runs `work`, giving up and returning nil once the budget is spent.
    private static func within<T: Sendable>(
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

    private func route(from origin: Coordinate, to destination: Coordinate, mode: TravelMode) async throws -> MKRoute {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.clCoordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination.clCoordinate))
        request.transportType = mode == .drive ? .automobile : .walking
        request.requestsAlternateRoutes = false

        do {
            let response = try await MKDirections(request: request).calculate()
            guard let first = response.routes.first else {
                throw RouteBuilderError.routingFailed(
                    "Apple Maps could not connect those two points by \(mode == .drive ? "road" : "foot").")
            }
            return first
        } catch let error as RouteBuilderError {
            throw error
        } catch {
            throw RouteBuilderError.routingFailed(error.localizedDescription)
        }
    }
}

public extension MKPolyline {
    var coordinates: [Coordinate] {
        var buffer = [CLLocationCoordinate2D](repeating: .init(), count: pointCount)
        getCoordinates(&buffer, range: NSRange(location: 0, length: pointCount))
        return buffer.map(Coordinate.init)
    }
}
