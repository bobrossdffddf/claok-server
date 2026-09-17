import Foundation

/// A believable way of getting from where the phone is to where the pin is.
///
/// Every spoofer teleports, and the teleport is the loudest thing in the
/// history: one fix in Dallas, the next in Tokyo, no time in between. A
/// person does not do that. A person drives to an airport, sits in it, goes
/// dark for the length of the flight, appears at another airport, and drives
/// on. This lays that out with real airports and real timings so the trace
/// reads like travel rather than magic.
///
/// The flight itself is a hold at the departure airport: a phone in airplane
/// mode reports nothing, and the last place anything saw it was the gate.
/// The next thing anything sees is the arrival gate. That is what a real
/// flight looks like from outside, and it is what is produced here.
public struct Journey: Sendable, Equatable {
    public struct Airport: Sendable, Equatable, Codable, Hashable {
        public var name: String
        public var iata: String
        /// The airfield. This is a centroid over the whole aerodrome polygon,
        /// which at a large airport is somewhere out on a runway.
        public var coordinate: Coordinate
        /// The passenger terminal, when the map knows where it is.
        ///
        /// This is the difference between a trace that sits in the departures
        /// hall and one that sits on a taxiway. `coordinate` is the centroid
        /// of the entire aerodrome, so at somewhere like DFW it can be over a
        /// kilometre from any building a passenger ever enters. Every leg that
        /// is about a person rather than an aircraft should aim at `door`.
        public var terminal: Coordinate?
        public var isInternational: Bool

        /// Where a passenger actually is: the terminal if the map has one,
        /// otherwise the best that is known.
        public var door: Coordinate { terminal ?? coordinate }

        public init(
            name: String,
            iata: String,
            coordinate: Coordinate,
            terminal: Coordinate? = nil,
            isInternational: Bool
        ) {
            self.name = name
            self.iata = iata
            self.coordinate = coordinate
            self.terminal = terminal
            self.isInternational = isInternational
        }
    }

    /// Where a leg leaves you, in the only two terms that matter to anything
    /// watching from outside: what a VPN exit there would be called, and what
    /// the clock says.
    ///
    /// Held as a name and an identifier rather than a `TimeZone` so the whole
    /// plan stays `Codable` and comparing two plans compares two strings.
    public struct Region: Sendable, Equatable, Codable, Hashable {
        /// The place the way you would type it into a VPN app: "Tokyo, Japan".
        public var placeName: String
        public var countryCode: String?
        /// An IANA identifier, "Asia/Tokyo".
        public var timeZoneIdentifier: String?

        public init(placeName: String, countryCode: String? = nil, timeZoneIdentifier: String? = nil) {
            self.placeName = placeName
            self.countryCode = countryCode
            self.timeZoneIdentifier = timeZoneIdentifier
        }

        public var timeZone: TimeZone? {
            guard let timeZoneIdentifier else { return nil }
            return TimeZone(identifier: timeZoneIdentifier)
        }

        /// The zone in words a person uses, falling back to the identifier.
        public func zoneName(at moment: Date) -> String? {
            guard let zone = timeZone else { return nil }
            return zone.localizedName(for: .generic, locale: .current) ?? zone.identifier
        }
    }

    public enum Shape: Sendable, Equatable {
        /// Close enough to drive. The existing drive does this.
        case drive
        /// Far enough that only a flight is believable.
        case fly
    }

    public struct Leg: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable {
            case drive(from: Coordinate, to: Coordinate)
            case hold(Coordinate, drift: Double)
        }

        public var id: String { name + "\(start.timeIntervalSince1970)" }
        public var name: String
        public var kind: Kind
        public var start: Date
        public var end: Date

        public var duration: TimeInterval { end.timeIntervalSince(start) }

        /// True while the phone is reporting nothing at all.
        ///
        /// Only the flight itself is built this way: a hold with no drift
        /// whatsoever is a phone in airplane mode, and it is the one stretch
        /// of a journey where changing something about the device cannot be
        /// correlated with a fix.
        public var isDark: Bool {
            if case .hold(_, let drift) = kind, drift == 0 { return true }
            return false
        }
    }

    public var shape: Shape
    public var legs: [Leg]
    public var origin: Airport?
    public var destination: Airport?
    /// The recipe this itinerary was built from, when there is one.
    ///
    /// A flight keeps it so the itinerary can be taken apart and rebuilt
    /// without going back to the network: change an airport, a departure
    /// time or the length of a hold and hand the plan back to `fly`. A
    /// straight drive has nothing to edit and leaves it nil.
    public var plan: Plan?

    public var departs: Date { legs.first?.start ?? Date() }
    public var arrives: Date { legs.last?.end ?? Date() }
    public var totalDuration: TimeInterval { arrives.timeIntervalSince(departs) }

    public var summary: String {
        switch shape {
        case .drive:
            return "Drive, about \(Self.clock(totalDuration))"
        case .fly:
            let via = [origin?.iata, destination?.iata].compactMap { $0 }.joined(separator: " to ")
            return "Fly \(via), about \(Self.clock(totalDuration)) door to door"
        }
    }

    // MARK: - Deciding the shape

    /// Under this a drive is believable and nobody flies. Over it nobody
    /// drives without a very good reason.
    public static let flyBeyondMetres: Double = 450_000

    public static func shape(for distance: Double) -> Shape {
        distance > flyBeyondMetres ? .fly : .drive
    }

    // MARK: - Timings

    /// Ground speed of an airliner. Slightly under cruise, because the
    /// climb and the descent are slower and the route is never a straight line.
    public static let cruiseMetresPerSecond: Double = 760_000 / 3600
    /// Taxi, takeoff, climb, descent, landing, taxi. Not part of the cruise.
    public static let flightOverhead: TimeInterval = 28 * 60
    /// From walking in the door to boarding. Security, the gate, the wait.
    public static let beforeFlight: TimeInterval = 82 * 60
    /// From wheels down to walking out. Taxi, deplane, bags, terminal.
    public static let afterFlight: TimeInterval = 34 * 60
    /// How much ground a person covers inside a terminal: the gate, the row of
    /// shops next to it, the walk back. It is a distance walked, not a drift —
    /// a hold this wide is played as short walks at walking pace with long
    /// sits between them, not as receiver error stretched to fit. See
    /// `IdleJitter.walkingBeyond`.
    public static let terminalWander: Double = 45
    /// Rough driving speed for the airport legs, including traffic.
    public static let groundMetresPerSecond: Double = 52_000 / 3600
    /// Nobody sits in a terminal for longer than this, and a slider that can
    /// reach a week is a slider that can produce an itinerary nobody believes.
    public static let longestHold: TimeInterval = 12 * 3600

    // MARK: - The editable recipe

    /// Everything a flight itinerary is made of, and the only thing an editor
    /// ever touches.
    ///
    /// The legs themselves are a rendering, not a document. Changing an
    /// airport or the length of a hold means changing this and asking `fly`
    /// for the legs again, which is the only way the result is guaranteed to
    /// stay in order: the builder lays legs down one after another from a
    /// single clock, so no leg can start before the one in front of it ends.
    public struct Plan: Sendable, Equatable {
        /// Where the person is now.
        public var from: Coordinate
        /// The pin.
        public var to: Coordinate
        public var origin: Airport
        public var destination: Airport
        /// When the first leg begins.
        public var departure: Date
        /// The terminal hold before the flight. Zero removes the leg.
        public var beforeFlight: TimeInterval
        /// The terminal hold after landing. Zero removes the leg.
        public var afterFlight: TimeInterval
        /// Whether the drive to the departure airport is part of the trip.
        /// Off for somebody who is already at the airport, or who would
        /// rather the history simply began at the kerb.
        public var drivesToAirport: Bool
        /// Whether the drive from the arrival airport to the pin is part of it.
        public var drivesFromAirport: Bool
        public var originRegion: Region?
        public var destinationRegion: Region?

        public init(
            from: Coordinate,
            to: Coordinate,
            origin: Airport,
            destination: Airport,
            departure: Date = Date(),
            beforeFlight: TimeInterval = Journey.beforeFlight,
            afterFlight: TimeInterval = Journey.afterFlight,
            drivesToAirport: Bool = true,
            drivesFromAirport: Bool = true,
            originRegion: Region? = nil,
            destinationRegion: Region? = nil
        ) {
            self.from = from
            self.to = to
            self.origin = origin
            self.destination = destination
            self.departure = departure
            self.beforeFlight = beforeFlight
            self.afterFlight = afterFlight
            self.drivesToAirport = drivesToAirport
            self.drivesFromAirport = drivesFromAirport
            self.originRegion = originRegion
            self.destinationRegion = destinationRegion
        }

        /// The same plan with anything a text field or a slider could have
        /// produced brought back inside the possible. Done once, here, so the
        /// numbers the editor shows and the legs the builder lays out are the
        /// same numbers.
        public var tidied: Plan {
            var copy = self
            copy.beforeFlight = min(max(0, beforeFlight.isFinite ? beforeFlight : 0), Journey.longestHold)
            copy.afterFlight = min(max(0, afterFlight.isFinite ? afterFlight : 0), Journey.longestHold)
            return copy
        }

        /// Great circle between the two airfields. Aircraft fly field to
        /// field; only people go to the terminal.
        public var airDistance: Double {
            origin.coordinate.distance(to: destination.coordinate)
        }

        /// How long the phone is dark. Not editable: it is arithmetic on the
        /// distance, and a flight that takes the time the user would like is
        /// the tell the whole feature exists to avoid.
        public var airTime: TimeInterval {
            Journey.flightOverhead + airDistance / Journey.cruiseMetresPerSecond
        }
    }

    // MARK: - Planning

    /// Lays out a flight from a plan.
    ///
    /// Ground legs are given a duration estimate; the drive itself is built by
    /// the route engine when the leg runs, which may be slower or faster, and
    /// the following legs simply start when it finishes.
    public static func fly(_ plan: Plan) -> Journey {
        let plan = plan.tidied
        var legs: [Leg] = []
        var clock = plan.departure

        func add(_ name: String, _ kind: Leg.Kind, _ length: TimeInterval) {
            // A hold the user has shortened to nothing is a leg the user
            // removed. Laying it down anyway would put a zero length step in
            // the itinerary that reads as a stutter in the history.
            guard length > 0 else { return }
            let end = clock.addingTimeInterval(length)
            legs.append(Leg(name: name, kind: kind, start: clock, end: end))
            clock = end
        }

        let origin = plan.origin
        let destination = plan.destination

        // Every leg below is about a person, so every one of them aims at
        // the terminal door and not at the middle of the airfield.
        let toAirport = plan.from.distance(to: origin.door)
        if plan.drivesToAirport, toAirport > 300 {
            add("To \(origin.iata)", .drive(from: plan.from, to: origin.door), max(6 * 60, toAirport / groundMetresPerSecond))
        }

        add("At \(origin.iata)", .hold(origin.door, drift: terminalWander), plan.beforeFlight)

        add("In the air", .hold(origin.door, drift: 0), max(flightOverhead, plan.airTime))

        add("Landed at \(destination.iata)", .hold(destination.door, drift: terminalWander), plan.afterFlight)

        let fromAirport = destination.door.distance(to: plan.to)
        if plan.drivesFromAirport, fromAirport > 300 {
            add("To the pin", .drive(from: destination.door, to: plan.to), max(6 * 60, fromAirport / groundMetresPerSecond))
        }

        return Journey(shape: .fly, legs: legs, origin: origin, destination: destination, plan: plan)
            .resequenced()
    }

    /// The default itinerary between two airports: drive, wait, fly, land,
    /// drive on. What the planner proposes before anybody edits it.
    public static func fly(
        from here: Coordinate,
        to there: Coordinate,
        via origin: Airport,
        and destination: Airport,
        departing: Date = Date()
    ) -> Journey {
        fly(Plan(from: here, to: there, origin: origin, destination: destination, departure: departing))
    }

    // MARK: - Staying in order

    /// True when nothing overlaps: every leg ends after it starts, and no leg
    /// begins before the one in front of it has finished.
    public var isSequential: Bool {
        if legs.contains(where: { $0.end < $0.start }) { return false }
        return zip(legs, legs.dropFirst()).allSatisfy { $0.end <= $1.start }
    }

    /// The same itinerary with every leg pushed far enough forward that none
    /// of them overlap, keeping each leg's own length.
    ///
    /// `fly` builds forward from one clock and cannot produce an overlap, so
    /// this is a belt on top of braces. It costs one pass and it means the
    /// invariant holds for any itinerary, however it was assembled.
    public func resequenced() -> Journey {
        var copy = self
        var previousEnd: Date?
        for index in copy.legs.indices {
            var leg = copy.legs[index]
            let length = max(0, leg.duration)
            if let previousEnd, leg.start < previousEnd { leg.start = previousEnd }
            leg.end = leg.start.addingTimeInterval(length)
            previousEnd = leg.end
            copy.legs[index] = leg
        }
        return copy
    }

    /// A drive, laid out the same way so a caller can treat both alike.
    public static func drive(from here: Coordinate, to there: Coordinate, departing: Date = Date()) -> Journey {
        let distance = here.distance(to: there)
        let length = max(4 * 60, distance / groundMetresPerSecond)
        let leg = Leg(name: "Drive to the pin", kind: .drive(from: here, to: there), start: departing, end: departing.addingTimeInterval(length))
        return Journey(shape: .drive, legs: [leg], origin: nil, destination: nil).resequenced()
    }

    // MARK: - The invisible moment

    /// Something about the device that should change partway through the trip,
    /// and the moment to change it.
    public struct Cue: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable, Equatable, Codable {
            /// Where the internet connection comes out.
            case vpn
            /// What the phone thinks the clock is.
            case timeZone
        }

        public var kind: Kind
        /// The moment, in real time.
        public var at: Date
        public var title: String
        public var body: String

        public var id: String { "\(kind.rawValue).\(Int(at.timeIntervalSince1970))" }

        public init(kind: Kind, at: Date, title: String, body: String) {
            self.kind = kind
            self.at = at
            self.title = title
            self.body = body
        }
    }

    /// The leg during which the phone reports nothing.
    public var darkLeg: Leg? { legs.first(where: \.isDark) }

    /// How long after the dark window opens the first change should be made.
    ///
    /// The middle. Both edges are the dangerous ones: a change made in the
    /// first minute sits next to the last fix at the departure gate, and one
    /// made in the last minute sits next to the first fix at the arrival
    /// gate. Anything correlating an IP change or a clock change against a
    /// location history is looking for exactly that adjacency, and the point
    /// furthest from both of them is the middle of the silence.
    private static func momentInside(_ window: (start: Date, end: Date), offsetBy extra: TimeInterval = 0) -> Date {
        let span = window.end.timeIntervalSince(window.start)
        guard span > 0 else { return window.start }
        // Never within a tenth of either edge, and never within five minutes
        // of one either, whichever is the tighter of the two.
        let margin = min(5 * 60, span * 0.1)
        let middle = window.start.addingTimeInterval(span / 2)
        let earliest = window.start.addingTimeInterval(margin)
        let latest = window.end.addingTimeInterval(-margin)
        guard earliest <= latest else { return middle }
        return min(max(middle.addingTimeInterval(extra), earliest), latest)
    }

    /// Whether the connection has to move for this trip to hold up.
    ///
    /// Any flight. `flyBeyondMetres` is 450 km, and there is no exit node
    /// within 450 km of the pin that is also the one you are using now.
    public var changesRegion: Bool { shape == .fly && darkLeg != nil }

    /// Whether the phone's clock has to move too. Only when both ends are
    /// known and they genuinely disagree, because guessing at this and being
    /// wrong is worse than saying nothing.
    public var changesTimeZone: Bool { timeZoneShift != nil }

    /// Seconds the phone's clock should move by, or nil when it should not
    /// move or nothing knows.
    public var timeZoneShift: TimeInterval? {
        guard shape == .fly, let plan,
              let here = plan.originRegion?.timeZone,
              let there = plan.destinationRegion?.timeZone else { return nil }
        let shift = Double(there.secondsFromGMT(for: arrives) - here.secondsFromGMT(for: departs))
        return abs(shift) < 60 ? nil : shift
    }

    /// The moments worth being told about, in the order they happen.
    public var cues: [Cue] { cues(startingAt: nil) }

    /// - Parameter windowStart: when the dark leg really began. A drive to the
    ///   airport that took longer than the estimate moves everything after it,
    ///   so a run that knows the real moment should say so rather than letting
    ///   the reminder fire while the phone is still on the motorway.
    public func cues(startingAt windowStart: Date?) -> [Cue] {
        guard shape == .fly, let dark = darkLeg else { return [] }
        let start = windowStart ?? dark.start
        let end = start.addingTimeInterval(dark.duration)
        guard end > start else { return [] }
        let window = (start: start, end: end)

        var out: [Cue] = []

        if changesRegion {
            let at = Self.momentInside(window)
            let landing = Self.clock(end.timeIntervalSince(at))
            let target: String
            if let name = plan?.destinationRegion?.placeName, !name.isEmpty {
                target = "Move your VPN exit to \(name)."
            } else if let destination {
                target = "Move your VPN exit to a server near \(destination.name)."
            } else {
                target = "Move your VPN exit as close to the pin as you can get."
            }
            let where_ = destination.map { " at \($0.iata)" } ?? ""
            out.append(Cue(
                kind: .vpn,
                at: at,
                title: "Switch your VPN now",
                body: "The phone is in the air and reporting nothing, so a change now lines up with no fix at either end. \(target) You land\(where_) in about \(landing)."
            ))
        }

        if let shift = timeZoneShift {
            // A minute and a half after the VPN, not at the same instant. Two
            // notifications landing together read as one and get swiped as
            // one, and the VPN is the one that can fail and need a retry.
            let at = Self.momentInside(window, offsetBy: 90)
            let zone = plan?.destinationRegion?.zoneName(at: end)
                ?? plan?.destinationRegion?.timeZoneIdentifier
                ?? "the zone the pin is in"
            let landing = Self.clock(end.timeIntervalSince(at))
            out.append(Cue(
                kind: .timeZone,
                at: at,
                title: "Change the phone's time zone now",
                // The instruction has to name the setting. iOS greys the zone
                // field out while Set Automatically is on, so somebody who
                // follows this notification without being told that opens
                // Settings, finds a control they cannot touch, and concludes
                // the app is talking nonsense.
                body: "Turn off Set Automatically in Date and Time, then set the phone to \(zone), \(Self.describeShift(shift)) where you took off. Any app can read the zone without asking, and one that flips the minute you land is the giveaway. You have about \(landing)."
            ))
        }

        return out.sorted { $0.at < $1.at }
    }

    // MARK: - Choosing airports

    /// The airport a person would actually fly from. Nearest wins unless a
    /// bigger one is not much further, because nobody drives past an
    /// international airport to use a regional strip.
    public static func choose(from candidates: [Airport], near point: Coordinate) -> Airport? {
        guard !candidates.isEmpty else { return nil }
        let scored = candidates.map { airport -> (Airport, Double) in
            var cost = point.distance(to: airport.coordinate)
            if airport.isInternational { cost *= 0.3 }
            return (airport, cost)
        }
        return scored.min { $0.1 < $1.1 }?.0
    }

    // MARK: - Wording

    public static func clock(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        if rest == 0 { return "\(hours) h" }
        return "\(hours) h \(rest) min"
    }

    /// A clock offset in words. Signed, because "5 hours" on its own is the
    /// half of the instruction that does not help.
    public static func describeShift(_ seconds: TimeInterval) -> String {
        let minutes = Int((abs(seconds) / 60).rounded())
        let hours = minutes / 60
        let rest = minutes % 60
        var size = ""
        if hours > 0 { size = hours == 1 ? "1 hour" : "\(hours) hours" }
        if rest > 0 { size += size.isEmpty ? "\(rest) min" : " \(rest) min" }
        if size.isEmpty { return "level with" }
        return "\(size) \(seconds >= 0 ? "ahead of" : "behind")"
    }
}
