import Foundation

/// A real place near a coordinate, pulled from the map.
///
/// This is what makes Living Cover more than a shape on a map: the errands it
/// invents happen at businesses that actually exist where you live, so a
/// history reviewer cross-referencing your stops against a places database
/// finds a real coffee shop, not a pin in the middle of a car park.
public struct DiscoveredPlace: Sendable, Equatable, Hashable, Codable, Identifiable {
    public var id: String { "\(category.rawValue):\(name):\(Int(coordinate.latitude * 1e5)):\(Int(coordinate.longitude * 1e5))" }
    public var name: String
    public var category: PlaceCategory
    public var coordinate: Coordinate

    public init(name: String, category: PlaceCategory, coordinate: Coordinate) {
        self.name = name
        self.category = category
        self.coordinate = coordinate
    }
}

/// The kinds of place a believable week visits, each with when it is plausible
/// and how long a real visit lasts. The dwell ranges are what nobody else
/// models: a coffee stop is minutes, a gym is the best part of an hour, a
/// supermarket run is in between, and getting those wrong is a tell.
public enum PlaceCategory: String, Sendable, CaseIterable, Codable {
    case coffee
    case food
    case gym
    case grocery
    case shop
    case park
    case pharmacy

    public var symbol: String {
        switch self {
        case .coffee: "cup.and.saucer.fill"
        case .food: "fork.knife"
        case .gym: "figure.run"
        case .grocery: "cart.fill"
        case .shop: "bag.fill"
        case .park: "tree.fill"
        case .pharmacy: "cross.case.fill"
        }
    }

    public var label: String {
        switch self {
        case .coffee: "Coffee"
        case .food: "Lunch or dinner"
        case .gym: "Gym"
        case .grocery: "Groceries"
        case .shop: "Errand"
        case .park: "Park"
        case .pharmacy: "Pharmacy"
        }
    }

    /// Minutes a real visit lasts, low to high.
    public var dwellMinutes: ClosedRange<Double> {
        switch self {
        case .coffee: 8...25
        case .food: 25...70
        case .gym: 40...80
        case .grocery: 15...45
        case .shop: 8...30
        case .park: 20...60
        case .pharmacy: 5...15
        }
    }

    /// The hours of the day this is plausible at, as a set of 24-hour bands.
    public func plausible(atHour hour: Int) -> Bool {
        switch self {
        case .coffee: (6...11).contains(hour) || (14...16).contains(hour)
        case .food: (11...14).contains(hour) || (18...21).contains(hour)
        case .gym: (6...9).contains(hour) || (17...21).contains(hour)
        case .grocery: (10...21).contains(hour)
        case .shop: (10...20).contains(hour)
        case .park: (8...19).contains(hour)
        case .pharmacy: (9...19).contains(hour)
        }
    }

    var overpassSelectors: [String] {
        switch self {
        case .coffee: ["amenity=cafe", "shop=coffee"]
        case .food: ["amenity=restaurant", "amenity=fast_food"]
        case .gym: ["leisure=fitness_centre", "leisure=sports_centre"]
        case .grocery: ["shop=supermarket", "shop=greengrocer"]
        case .shop: ["shop=convenience", "shop=department_store", "shop=mall"]
        case .park: ["leisure=park"]
        case .pharmacy: ["amenity=pharmacy", "shop=chemist"]
        }
    }
}

public actor PlaceFinder {
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

    /// Every named place of the requested categories within `radiusMeters` of
    /// the anchor, nearest kept when a category has many.
    public func find(
        near anchor: Coordinate,
        radiusMeters: Double = 2500,
        categories: [PlaceCategory] = PlaceCategory.allCases
    ) async throws -> [DiscoveredPlace] {
        let elapsed = Date.now.timeIntervalSince(lastRequest)
        if elapsed < 1 { try await Task.sleep(for: .seconds(1 - elapsed)) }
        lastRequest = .now

        let box = BoundingBox(
            minLatitude: anchor.latitude, minLongitude: anchor.longitude,
            maxLatitude: anchor.latitude, maxLongitude: anchor.longitude
        ).padded(byMeters: radiusMeters)

        let query = Self.query(box: box, categories: categories)
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
        request.timeoutInterval = 12
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")".data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OverpassError.malformed }
        if http.statusCode == 429 || http.statusCode == 504 { throw OverpassError.rateLimited }
        guard (200..<300).contains(http.statusCode) else { throw OverpassError.badResponse(http.statusCode) }
        return data
    }

    static func query(box: BoundingBox, categories: [PlaceCategory]) -> String {
        let clause = box.overpassClause
        var lines: [String] = []
        for category in categories {
            for selector in category.overpassSelectors {
                let parts = selector.split(separator: "=")
                guard parts.count == 2 else { continue }
                lines.append("  nwr[\"\(parts[0])\"=\"\(parts[1])\"][\"name\"](\(clause));")
            }
        }
        return """
        [out:json][timeout:25];
        (
        \(lines.joined(separator: "\n"))
        );
        out center 200;
        """
    }

    static func decode(_ data: Data, near anchor: Coordinate) -> [DiscoveredPlace] {
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

        var found: [DiscoveredPlace] = []
        for element in response.elements {
            guard let tags = element.tags, let name = tags["name"] else { continue }
            let lat = element.lat ?? element.center?.lat
            let lon = element.lon ?? element.center?.lon
            guard let lat, let lon else { continue }
            guard let category = category(for: tags) else { continue }
            found.append(DiscoveredPlace(name: name, category: category, coordinate: Coordinate(latitude: lat, longitude: lon)))
        }

        // Keep the closest handful per category, so a dense downtown does not
        // return five hundred cafes.
        var byCategory: [PlaceCategory: [DiscoveredPlace]] = [:]
        for place in found { byCategory[place.category, default: []].append(place) }
        var result: [DiscoveredPlace] = []
        for (_, places) in byCategory {
            let sorted = places.sorted { anchor.distance(to: $0.coordinate) < anchor.distance(to: $1.coordinate) }
            result.append(contentsOf: sorted.prefix(8))
        }
        return result
    }

    static func category(for tags: [String: String]) -> PlaceCategory? {
        for category in PlaceCategory.allCases {
            for selector in category.overpassSelectors {
                let parts = selector.split(separator: "=")
                guard parts.count == 2 else { continue }
                if tags[String(parts[0])] == String(parts[1]) { return category }
            }
        }
        return nil
    }
}
