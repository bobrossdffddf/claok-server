import Foundation

public enum RoadClass: String, Codable, Sendable, CaseIterable {
    case motorway
    case trunk
    case primary
    case secondary
    case tertiary
    case residential
    case service
    case living
    case footway
    case unknown

    public init(osmHighway value: String) {
        switch value {
        case "motorway", "motorway_link": self = .motorway
        case "trunk", "trunk_link": self = .trunk
        case "primary", "primary_link": self = .primary
        case "secondary", "secondary_link": self = .secondary
        case "tertiary", "tertiary_link": self = .tertiary
        case "residential", "unclassified": self = .residential
        case "service": self = .service
        case "living_street": self = .living
        case "footway", "path", "pedestrian", "steps", "cycleway": self = .footway
        default: self = .unknown
        }
    }

    public var defaultLimit: Double {
        switch self {
        case .motorway: Speed.mph(65)
        case .trunk: Speed.mph(55)
        case .primary: Speed.mph(45)
        case .secondary: Speed.mph(35)
        case .tertiary: Speed.mph(30)
        case .residential: Speed.mph(25)
        case .service: Speed.mph(15)
        case .living: Speed.mph(15)
        case .footway: Speed.mph(3)
        case .unknown: Speed.mph(30)
        }
    }
}

/// OSM `maxspeed`, which in the wild is messier than the wiki suggests.
///
/// A bare number is km/h, that much is settled. Everything else is however
/// the mapper typed it: "45 mph", "45mph", "70 km/h", "70kph", "none" on an
/// unrestricted autobahn, "walk" in a yard, and lists like "50;30" where the
/// first entry is the one that applies to the way. Anything this cannot read
/// returns nil so the caller falls back to the road class, which is a guess
/// but an honest one.
public enum MaxSpeedParser {
    public static func parse(_ raw: String) -> Double? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // A semicolon list is per-lane or seasonal. The first entry is the
        // one that applies to the way itself.
        if let cut = value.firstIndex(of: ";") {
            value = String(value[..<cut]).trimmingCharacters(in: .whitespaces)
        }
        if value.isEmpty { return nil }
        if value == "none" { return Speed.mph(80) }
        if value == "walk" { return Speed.mph(4) }

        // Split the number from its unit wherever the digits stop, rather than
        // on a space. "45mph" is written without one often enough, and it used
        // to fail the number parse outright and fall back to the road class's
        // default: a 45 mph arterial read as whatever a primary road is, and a
        // 45 mph residential read as 25. That is where limits "way under or
        // way over" came from.
        let digits = value.prefix { $0.isNumber || $0 == "." }
        guard let number = Double(digits), number > 0 else { return nil }
        let unit = value
            .dropFirst(digits.count)
            .replacingOccurrences(of: " ", with: "")

        switch unit {
        case "mph", "mp/h": return Speed.mph(number)
        case "knots", "knot", "kn": return number * 0.514444
        case "", "km/h", "kmh", "kph", "kmph": return Speed.kph(number)
        // A unit nobody recognises means the tag is not a plain speed:
        // "30 zone", a country code, a sign reference. Better to say so than
        // to read the number as km/h and be wrong by a factor.
        default: return nil
        }
    }
}
