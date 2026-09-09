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

public enum MaxSpeedParser {
    public static func parse(_ raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if value == "none" { return Speed.mph(80) }
        if value == "walk" { return Speed.mph(4) }
        let parts = value.split(separator: " ")
        guard let first = parts.first, let number = Double(first) else { return nil }
        if parts.count > 1, parts[1] == "mph" { return Speed.mph(number) }
        if parts.count > 1, parts[1] == "knots" { return number * 0.514444 }
        return Speed.kph(number)
    }
}
