import Foundation

/// Finds real airports near a point, from OpenStreetMap.
public actor AirportFinder {
    private let session: URLSession
    private let endpoints: [URL]
    private var lastRequest: Date = .distantPast

    public init(session: URLSession = .shared) {
        self.session = session
        self.endpoints = [
            URL(string: "https://overpass-api.de/api/interpreter")!,
            URL(string: "https://overpass.kumi.systems/api/interpreter")!,
            URL(string: "https://maps.mail.ru/osm/tools/overpass/api/interpreter")!
        ]
    }

    /// Airports with an IATA code within the radius, nearest first. Only ones
    /// with a code, because those are the ones with scheduled flights.
    public func airports(near anchor: Coordinate, radiusMeters: Double = 160_000) async throws -> [Journey.Airport] {
        let elapsed = Date.now.timeIntervalSince(lastRequest)
        if elapsed < 1 { try await Task.sleep(for: .seconds(1 - elapsed)) }
        lastRequest = .now

        let box = BoundingBox(
            minLatitude: anchor.latitude, minLongitude: anchor.longitude,
            maxLatitude: anchor.latitude, maxLongitude: anchor.longitude
        ).padded(byMeters: radiusMeters)

        let query = Self.query(box: box)
        var lastError: Error = OverpassError.malformed
        for endpoint in endpoints {
            do {
                let data = try await post(query: query, to: endpoint)
                return Self.decode(data, near: anchor)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func post(query: String, to endpoint: URL) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")".data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OverpassError.malformed }
        if http.statusCode == 429 || http.statusCode == 504 { throw OverpassError.rateLimited }
        guard (200..<300).contains(http.statusCode) else { throw OverpassError.badResponse(http.statusCode) }
        return data
    }

    /// How far a terminal may be from its airfield centroid and still be
    /// taken as belonging to it. Large hubs are several kilometres across, so
    /// this is generous; airports are far enough apart that it does not cause
    /// a terminal to be claimed by the wrong field.
    static let terminalWithin: Double = 6_000

    static func query(box: BoundingBox) -> String {
        let clause = box.overpassClause
        return """
        [out:json][timeout:25];
        (
        nwr["aeroway"="aerodrome"]["iata"](\(clause));
        nwr["aeroway"="terminal"](\(clause));
        );
        out center tags;
        """
    }

    static func decode(_ data: Data, near anchor: Coordinate) -> [Journey.Airport] {
        struct Response: Decodable {
            struct Center: Decodable { let lat: Double; let lon: Double }
            struct Element: Decodable {
                let lat: Double?
                let lon: Double?
                let center: Center?
                let tags: [String: String]?
            }
            let elements: [Element]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return [] }

        // The same query brings back terminals as well as airfields. An
        // aerodrome polygon's centroid is a point on a runway at anywhere
        // large, and a passenger is never on a runway, so each field is
        // matched to the nearest terminal building and carries that as its
        // door.
        var terminals: [Coordinate] = []
        for element in response.elements where element.tags?["aeroway"] == "terminal" {
            guard let lat = element.lat ?? element.center?.lat,
                  let lon = element.lon ?? element.center?.lon else { continue }
            terminals.append(Coordinate(latitude: lat, longitude: lon))
        }

        var found: [Journey.Airport] = []
        var seen: Set<String> = []
        for element in response.elements {
            guard let tags = element.tags, tags["aeroway"] == "aerodrome" else { continue }
            guard let iata = tags["iata"], iata.count == 3 else { continue }
            let lat = element.lat ?? element.center?.lat
            let lon = element.lon ?? element.center?.lon
            guard let lat, let lon, !seen.contains(iata) else { continue }
            // Military and closed fields carry codes too. Skip the ones that
            // say so; the rest are fair.
            if let type = tags["aerodrome:type"], type == "military" { continue }
            if tags["disused"] == "yes" || tags["abandoned"] == "yes" { continue }
            seen.insert(iata)
            let field = Coordinate(latitude: lat, longitude: lon)
            let terminal = terminals
                .filter { field.distance(to: $0) <= terminalWithin }
                .min { field.distance(to: $0) < field.distance(to: $1) }
            found.append(Journey.Airport(
                name: tags["name:en"] ?? tags["name"] ?? iata,
                iata: iata,
                coordinate: field,
                terminal: terminal,
                isInternational: tags["aerodrome:type"] == "international" || (tags["name"] ?? "").localizedCaseInsensitiveContains("international")
            ))
        }
        return found.sorted { anchor.distance(to: $0.door) < anchor.distance(to: $1.door) }
    }
}
