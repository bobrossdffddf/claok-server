import Foundation

/// Turns "here is where I live" into a whole believable life.
///
/// Give it home (and optionally work) and it discovers the real cafes, shops,
/// gyms and restaurants around both, then hands back a Routine that the
/// scheduler runs on its own: asleep at home overnight, out at the usual time,
/// a stop or two at genuine local places on the way back, home in the evening,
/// every day different and none of them impossible.
///
/// Nothing in this category does this. The rest are session tools: run one
/// route, stop, snap back. A tool that snaps back leaves a location history
/// that is empty except for the moments you were performing, which is the most
/// obvious tell there is. Living Cover fills the rest of the history in with a
/// life, anchored to places that exist, so long-term pattern analysis has an
/// ordinary week to look at instead of a handful of suspicious set pieces.
public struct LivingCover: Sendable {
    public var home: Coordinate
    public var homeName: String
    public var work: Coordinate?
    public var workName: String

    public init(home: Coordinate, homeName: String = "Home", work: Coordinate? = nil, workName: String = "Work") {
        self.home = home
        self.homeName = homeName
        self.work = work
        self.workName = workName
    }

    /// Discovers real places near home and work, deduplicated. Call on a
    /// PlaceFinder actor; failures degrade to whatever was found.
    public func discover(using finder: PlaceFinder, radiusMeters: Double = 2500) async -> [DiscoveredPlace] {
        var all: [String: DiscoveredPlace] = [:]
        if let found = try? await finder.find(near: home, radiusMeters: radiusMeters) {
            for place in found { all[place.id] = place }
        }
        if let work, work.distance(to: home) > 500 {
            if let found = try? await finder.find(near: work, radiusMeters: radiusMeters) {
                for place in found { all[place.id] = place }
            }
        }
        return Array(all.values)
    }

    /// Builds the Routine. If no work was given, the "work" anchor is a nearby
    /// everyday destination (a park or the closest shop) so the day still has a
    /// believable there-and-back rather than sitting at home for twenty hours.
    public func routine(from places: [DiscoveredPlace], density: Double = 0.6) -> Routine {
        let resolvedWork: Coordinate
        let resolvedWorkName: String
        if let work {
            resolvedWork = work
            resolvedWorkName = workName
        } else if let anchor = places.first(where: { $0.category == .park })
            ?? places.min(by: { home.distance(to: $0.coordinate) < home.distance(to: $1.coordinate) }) {
            resolvedWork = anchor.coordinate
            resolvedWorkName = anchor.name
        } else {
            // Nothing found: a point a kilometre away, so there is still motion.
            resolvedWork = home.offset(metersNorth: 900, metersEast: 300)
            resolvedWorkName = "Out"
        }

        let routine = Routine(
            name: "Living Cover",
            home: home,
            homeName: homeName,
            work: resolvedWork,
            workName: resolvedWorkName,
            leaveHour: 8,
            leaveMinute: 20,
            returnHour: 17,
            returnMinute: 15,
            jitterMinutes: 18,
            weekdays: 0b1111111,
            mode: .drive,
            dwellDrift: 9
        )
        routine.errands = places
        routine.errandDensity = density
        return routine
    }
}
