import Foundation

public enum OverpassError: Error, Sendable {
    case rateLimited
    case badResponse(Int)
    case malformed
}

public actor OverpassClient {
    public struct Configuration: Sendable {
        public var endpoints: [URL]
        public var timeout: TimeInterval
        public var minimumInterval: TimeInterval

        public init(
            endpoints: [URL] = [
                URL(string: "https://overpass-api.de/api/interpreter")!,
                URL(string: "https://overpass.kumi.systems/api/interpreter")!,
                URL(string: "https://maps.mail.ru/osm/tools/overpass/api/interpreter")!
            ],
            timeout: TimeInterval = 8,
            minimumInterval: TimeInterval = 1
        ) {
            self.endpoints = endpoints
            self.timeout = timeout
            self.minimumInterval = minimumInterval
        }
    }

    private let configuration: Configuration
    private let session: URLSession
    private var lastRequest: Date = .distantPast
    private var endpointIndex = 0

    public init(configuration: Configuration = Configuration(), session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public func fetch(box: BoundingBox) async throws -> RoadMetadata {
        let elapsed = Date.now.timeIntervalSince(lastRequest)
        if elapsed < configuration.minimumInterval {
            try await Task.sleep(for: .seconds(configuration.minimumInterval - elapsed))
        }
        lastRequest = .now

        let query = Self.query(for: box)
        var lastError: Error = OverpassError.malformed

        for attempt in 0..<configuration.endpoints.count {
            let endpoint = configuration.endpoints[(endpointIndex + attempt) % configuration.endpoints.count]
            do {
                let payload = try await post(query: query, to: endpoint)
                endpointIndex = (endpointIndex + attempt) % configuration.endpoints.count
                return try Self.decode(payload)
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    private func post(query: String, to endpoint: URL) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")".data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OverpassError.malformed }
        if http.statusCode == 429 || http.statusCode == 504 { throw OverpassError.rateLimited }
        guard (200..<300).contains(http.statusCode) else { throw OverpassError.badResponse(http.statusCode) }
        return data
    }

    static func query(for box: BoundingBox) -> String {
        let clause = box.overpassClause
        return """
        [out:json][timeout:25];
        (
          way["highway"](\(clause));
          node["highway"="traffic_signals"](\(clause));
          node["highway"="stop"](\(clause));
          node["highway"="give_way"](\(clause));
          node["highway"="crossing"](\(clause));
        );
        out body geom;
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
        }

        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw OverpassError.malformed
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
                    controls.append(TrafficControl(kind: kind, coordinate: coordinate, alongTrack: 0))
                }
            }
        }

        return RoadMetadata(segments: segments, controls: controls, fetchedAt: .now, wasFallback: false)
    }
}
