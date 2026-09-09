import Foundation
import SwiftData

@Model
public final class Place {
    public var id: UUID
    public var name: String
    public var subtitle: String
    public var latitude: Double
    public var longitude: Double
    public var symbolName: String
    public var folder: String?
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var useCount: Int

    public init(
        id: UUID = UUID(),
        name: String,
        subtitle: String = "",
        coordinate: Coordinate,
        symbolName: String = "mappin",
        folder: String? = nil
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.symbolName = symbolName
        self.folder = folder
        self.createdAt = .now
        self.lastUsedAt = nil
        self.useCount = 0
    }

    public var coordinate: Coordinate {
        Coordinate(latitude: latitude, longitude: longitude)
    }

    public func markUsed() {
        lastUsedAt = .now
        useCount += 1
    }
}

@Model
public final class SavedRoute {
    public var id: UUID
    public var name: String
    public var modeRaw: String
    public var personaID: String
    public var encodedWaypoints: Data
    public var createdAt: Date
    public var lastRunAt: Date?

    public init(id: UUID = UUID(), name: String, mode: TravelMode, personaID: String, waypoints: [RouteWaypoint]) {
        self.id = id
        self.name = name
        self.modeRaw = mode.rawValue
        self.personaID = personaID
        self.encodedWaypoints = (try? JSONEncoder().encode(waypoints)) ?? Data()
        self.createdAt = .now
        self.lastRunAt = nil
    }

    public var mode: TravelMode { TravelMode(rawValue: modeRaw) ?? .drive }

    public var waypoints: [RouteWaypoint] {
        (try? JSONDecoder().decode([RouteWaypoint].self, from: encodedWaypoints)) ?? []
    }
}

@Model
public final class RecordedTrip {
    public var id: UUID
    public var name: String
    public var recordedAt: Date
    public var duration: TimeInterval
    public var distance: Double
    public var encodedFixes: Data

    public init(id: UUID = UUID(), name: String, fixes: [SimulatedFix]) {
        self.id = id
        self.name = name
        self.recordedAt = fixes.first?.timestamp ?? .now
        if let first = fixes.first?.timestamp, let last = fixes.last?.timestamp {
            self.duration = last.timeIntervalSince(first)
        } else {
            self.duration = 0
        }
        let polyline = Polyline(points: fixes.map(\.coordinate))
        self.distance = polyline.length
        self.encodedFixes = (try? JSONEncoder().encode(fixes)) ?? Data()
    }

    public var fixes: [SimulatedFix] {
        (try? JSONDecoder().decode([SimulatedFix].self, from: encodedFixes)) ?? []
    }
}
