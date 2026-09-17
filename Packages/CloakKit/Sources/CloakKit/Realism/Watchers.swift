import Foundation

/// The apps that look for a faked location, and what each one actually reads.
///
/// Every app in this category is caught by a different check. A dating app
/// compares the pin to where the connection comes out. A family tracker's
/// telematics engine wants the accelerometer to agree the phone is in a car.
/// A game measures how far you jumped. Knowing which app reads which signal
/// turns "am I safe" into "am I safe from this one", which is the only form
/// of the question that has an answer.
///
/// Where a check is published, it is marked documented. Where it is the
/// standard practice of that kind of app but not published, it is marked
/// likely. Nothing here is a guess dressed up as a fact.
public struct Watcher: Sendable, Equatable, Identifiable {
    public enum Certainty: String, Sendable {
        case documented
        case likely
    }

    public var id: String
    public var name: String
    public var scheme: String
    public var symbol: String
    /// Which environmental leaks this app is known to read.
    public var reads: Set<Exposure.Leak.Kind>
    /// Whether it measures the jump from the last position, which a trace
    /// grade covers and this one does not.
    public var teleportSensitive: Bool
    public var certainty: Certainty
    public var note: String

    public init(
        id: String,
        name: String,
        scheme: String,
        symbol: String,
        reads: Set<Exposure.Leak.Kind>,
        teleportSensitive: Bool = false,
        certainty: Certainty,
        note: String
    ) {
        self.id = id
        self.name = name
        self.scheme = scheme
        self.symbol = symbol
        self.reads = reads
        self.teleportSensitive = teleportSensitive
        self.certainty = certainty
        self.note = note
    }

    public static let known: [Watcher] = [
        Watcher(
            id: "life360", name: "Life360", scheme: "life360://", symbol: "figure.2.and.child.holdinghands",
            reads: [.motion],
            teleportSensitive: true,
            certainty: .documented,
            note: "Its drive detection comes from Arity's telematics SDK. A drive counts above 15 mph and half a mile, and the engine wants the phone's own motion sensors to agree it is in a car. SHIELD is built for exactly this."
        ),
        Watcher(
            id: "findmy", name: "Find My", scheme: "findmy://", symbol: "location.circle",
            reads: [],
            certainty: .documented,
            note: "Reads the same location every other app does. It shows the pin, and nothing about it checks whether the pin is real."
        ),
        Watcher(
            id: "pokemongo", name: "Pokémon GO", scheme: "com.nianticlabs.pokemongo://", symbol: "gamecontroller",
            reads: [.softwareFlag, .ip, .country],
            teleportSensitive: true,
            certainty: .documented,
            note: "Niantic enforces a cooldown on distance jumped, region-locks events by connection country, and its anti-cheat looks for signs of simulation. It is the strictest app on this list."
        ),
        Watcher(
            id: "tinder", name: "Tinder", scheme: "tinder://", symbol: "flame",
            reads: [.ip, .country],
            certainty: .likely,
            note: "Compares the reported position to where the connection comes out. Passport is the sanctioned way to be elsewhere; a mismatch outside it is what gets flagged."
        ),
        Watcher(
            id: "hinge", name: "Hinge", scheme: "hinge://", symbol: "heart",
            reads: [.ip, .country],
            certainty: .likely,
            note: "Same family as Tinder, same check: pin against connection."
        ),
        Watcher(
            id: "bumble", name: "Bumble", scheme: "bumble://", symbol: "heart.circle",
            reads: [.ip, .country],
            certainty: .likely,
            note: "Pin against connection, and a sudden change of city is reviewed."
        ),
        Watcher(
            id: "grindr", name: "Grindr", scheme: "grindr://", symbol: "person.2",
            reads: [.ip],
            certainty: .likely,
            note: "Pin against connection."
        ),
        Watcher(
            id: "snapchat", name: "Snapchat", scheme: "snapchat://", symbol: "camera.viewfinder",
            reads: [.ip],
            teleportSensitive: true,
            certainty: .likely,
            note: "Snap Map notices a jump it cannot explain and compares the pin to the connection."
        ),
        Watcher(
            id: "uber", name: "Uber", scheme: "uber://", symbol: "car",
            reads: [.motion, .softwareFlag, .ip],
            teleportSensitive: true,
            certainty: .likely,
            note: "Rider and driver fraud checks read motion, connection and the simulation mark. A pickup pin far from where the phone really is gets the trip cancelled."
        ),
        Watcher(
            id: "lyft", name: "Lyft", scheme: "lyft://", symbol: "car.fill",
            reads: [.motion, .ip],
            teleportSensitive: true,
            certainty: .likely,
            note: "Same shape of check as Uber."
        ),
        Watcher(
            id: "doordash", name: "DoorDash", scheme: "doordash://", symbol: "bag",
            reads: [.motion],
            teleportSensitive: true,
            certainty: .likely,
            note: "Dasher tracking expects motion to match movement."
        ),
        Watcher(
            id: "strava", name: "Strava", scheme: "strava://", symbol: "figure.run",
            reads: [.motion],
            teleportSensitive: true,
            certainty: .likely,
            note: "An activity with no matching motion is flagged and can be removed from leaderboards."
        ),
        Watcher(
            id: "venmo", name: "Venmo", scheme: "venmo://", symbol: "dollarsign.circle",
            reads: [.ip, .country],
            certainty: .likely,
            note: "Payments gate on connection country before anything else."
        ),
        Watcher(
            id: "cashapp", name: "Cash App", scheme: "cashapp://", symbol: "dollarsign.square",
            reads: [.ip, .country],
            certainty: .likely,
            note: "Payments gate on connection country before anything else."
        ),
        Watcher(
            id: "paypal", name: "PayPal", scheme: "paypal://", symbol: "creditcard",
            reads: [.ip, .country],
            certainty: .likely,
            note: "Payments gate on connection country before anything else."
        ),
        Watcher(
            id: "netflix", name: "Netflix", scheme: "nflx://", symbol: "play.rectangle",
            reads: [.country],
            certainty: .documented,
            note: "Catalogue is chosen by connection country. The pin is not read at all."
        ),
        Watcher(
            id: "disney", name: "Disney+", scheme: "disneyplus://", symbol: "sparkles.tv",
            reads: [.country],
            certainty: .documented,
            note: "Catalogue is chosen by connection country. The pin is not read at all."
        ),
        Watcher(
            id: "hulu", name: "Hulu", scheme: "hulu://", symbol: "tv",
            reads: [.country, .ip],
            certainty: .documented,
            note: "Home network is tied to the connection, and travel away from it is limited."
        ),
        Watcher(
            id: "instagram", name: "Instagram", scheme: "instagram://", symbol: "camera",
            reads: [.ip],
            certainty: .likely,
            note: "Connection sets locale and ads. Rarely acts on a mismatch."
        ),
    ]

    /// One app's standing against the current reading.
    public struct Verdict: Sendable, Equatable, Identifiable {
        public enum Standing: Int, Sendable, Comparable {
            case covered = 0
            case exposed = 1
            case alwaysKnows = 2

            public static func < (lhs: Standing, rhs: Standing) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        public var id: String { watcher.id }
        public var watcher: Watcher
        public var standing: Standing
        /// The leaks this app reads that are currently open.
        public var open: [Exposure.Leak]

        public var headline: String {
            switch standing {
            case .alwaysKnows: "Can always tell"
            case .exposed: open.count == 1 ? "Exposed by one thing" : "Exposed by \(open.count) things"
            case .covered: "Covered"
            }
        }
    }

    /// Grades every installed watcher against the reading.
    public static func judge(installed: [Watcher], against reading: Exposure?) -> [Verdict] {
        let openLeaks = reading?.problems ?? []
        let byKind = Dictionary(grouping: openLeaks, by: \.kind)

        let verdicts = installed.map { watcher -> Verdict in
            if watcher.reads.contains(.softwareFlag) {
                let others = watcher.reads.subtracting([.softwareFlag]).compactMap { byKind[$0]?.first }
                return Verdict(watcher: watcher, standing: .alwaysKnows, open: others)
            }
            let open = watcher.reads.compactMap { byKind[$0]?.first }.sorted { $0.cost > $1.cost }
            return Verdict(watcher: watcher, standing: open.isEmpty ? .covered : .exposed, open: open)
        }
        return verdicts.sorted { lhs, rhs in
            if lhs.standing != rhs.standing { return lhs.standing > rhs.standing }
            return lhs.watcher.name < rhs.watcher.name
        }
    }
}
