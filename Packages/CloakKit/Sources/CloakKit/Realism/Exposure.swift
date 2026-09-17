import Foundation

/// Grades everything around a simulated location that can give it away.
///
/// `Believability` judges the trace itself: its shape, its speed, its jitter.
/// This judges the room the trace is standing in. The checks here are the ones
/// a fraud team or an anti-cheat SDK actually runs, because none of them need
/// the location history at all. They compare the reported position against
/// signals the phone leaks for free: where its internet connection comes out,
/// what time zone it thinks it is in, and whether it is physically moving.
///
/// Every check names the leak, says what it costs, and says what closes it.
public struct Exposure: Sendable, Equatable {
    public struct Leak: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable, Codable {
            case ip
            case country
            case timeZone
            case motion
            case softwareFlag
            case unchecked
        }

        public enum Severity: Int, Sendable, Comparable {
            case note = 0
            case weak = 1
            case bad = 2

            public static func < (lhs: Severity, rhs: Severity) -> Bool {
                lhs.rawValue < rhs.rawValue
            }
        }

        public var id: String { kind.rawValue }
        public var kind: Kind
        public var title: String
        public var detail: String
        public var fix: String
        public var severity: Severity
        public var cost: Int

        public init(kind: Kind, title: String, detail: String, fix: String, severity: Severity, cost: Int) {
            self.kind = kind
            self.title = title
            self.detail = detail
            self.fix = fix
            self.severity = severity
            self.cost = cost
        }
    }

    /// Where the internet connection comes out, as the world sees it.
    public struct IPPlace: Sendable, Equatable {
        public var address: String
        public var coordinate: Coordinate
        public var city: String?
        public var region: String?
        public var countryCode: String?
        public var timeZone: TimeZone?
        public var checkedAt: Date

        public init(
            address: String,
            coordinate: Coordinate,
            city: String? = nil,
            region: String? = nil,
            countryCode: String? = nil,
            timeZone: TimeZone? = nil,
            checkedAt: Date = Date()
        ) {
            self.address = address
            self.coordinate = coordinate
            self.city = city
            self.region = region
            self.countryCode = countryCode
            self.timeZone = timeZone
            self.checkedAt = checkedAt
        }

        public var placeName: String {
            [city, region, countryCode].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }

    /// What the pin resolves to on a map.
    public struct PinPlace: Sendable, Equatable {
        public var coordinate: Coordinate
        public var city: String?
        public var region: String?
        public var countryCode: String?
        public var timeZone: TimeZone?

        public init(
            coordinate: Coordinate,
            city: String? = nil,
            region: String? = nil,
            countryCode: String? = nil,
            timeZone: TimeZone? = nil
        ) {
            self.coordinate = coordinate
            self.city = city
            self.region = region
            self.countryCode = countryCode
            self.timeZone = timeZone
        }

        public var placeName: String {
            [city, region, countryCode].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        }

        /// The one line to hand somebody choosing a VPN server.
        public var egressAdvice: String {
            let where_ = [city, countryName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            return where_.isEmpty ? "Pick a server as close to the pin as you can." : "Set your VPN to \(where_)."
        }

        public var countryName: String? {
            guard let code = countryCode else { return nil }
            return Locale.current.localizedString(forRegionCode: code)
        }
    }

    /// Everything the grade is built from. Anything unknown is left nil and the
    /// grade says so rather than guessing.
    public struct Environment: Sendable, Equatable {
        public var pin: PinPlace
        public var ip: IPPlace?
        public var deviceTimeZone: TimeZone
        /// nil when there is no motion reading, or motion is not permitted.
        public var deviceIsStationary: Bool?
        /// Metres per second the simulation is currently reporting.
        public var simulatedSpeed: Double
        /// The fastest the run has reported over the last minute or two, when
        /// the caller keeps that history.
        ///
        /// A drive is not a series of unrelated instants. It brakes for a
        /// light, sits at zero for up to a minute, and pulls away again, and
        /// the phone did not move for any of it. Grading the instant makes
        /// the same drive score two different ways depending on whether the
        /// light was red when you looked. Nil means the caller has no
        /// history and only this moment can be judged.
        public var recentTopSpeed: Double?
        public var isSimulating: Bool
        public var now: Date

        public init(
            pin: PinPlace,
            ip: IPPlace? = nil,
            deviceTimeZone: TimeZone = .current,
            deviceIsStationary: Bool? = nil,
            simulatedSpeed: Double = 0,
            recentTopSpeed: Double? = nil,
            isSimulating: Bool = false,
            now: Date = Date()
        ) {
            self.pin = pin
            self.ip = ip
            self.deviceTimeZone = deviceTimeZone
            self.deviceIsStationary = deviceIsStationary
            self.simulatedSpeed = simulatedSpeed
            self.recentTopSpeed = recentTopSpeed
            self.isSimulating = isSimulating
            self.now = now
        }
    }

    /// Nought to a hundred: a hundred less what the open leaks cost, and
    /// nothing else. It is plain arithmetic on the numbers printed beside each
    /// leak, so a reader who adds them up gets this.
    public var score: Int
    public var leaks: [Leak]

    public var grade: String {
        switch standing {
        case 90...: "Covered"
        case 75..<90: "Mostly covered"
        case 55..<75: "Exposed"
        case 35..<55: "Wide open"
        default: "Lit up"
        }
    }

    /// What the reading is worth, for wording and colour only.
    ///
    /// A single serious leak gives you away on its own, so a reading that has
    /// one cannot be called mostly covered no matter how tidy the rest of it
    /// is. That used to be done by clamping `score` itself, which made the
    /// headline number disagree with the costs printed underneath it: one
    /// leak marked minus 25 produced a 49. The number is now honest and only
    /// the judgement of it is capped, so nothing on screen contradicts
    /// anything else on screen.
    public var standing: Int {
        serious.isEmpty ? score : min(score, Self.seriousCeiling)
    }

    /// True when one open leak is enough on its own.
    public var isSeriouslyExposed: Bool { !serious.isEmpty }

    /// Leaks that actually cost something. The permanent note about the
    /// software flag is always present and is not a problem to solve.
    public var problems: [Leak] { leaks.filter { $0.cost > 0 } }
    public var isClean: Bool { problems.isEmpty }

    /// The problems that are enough on their own. Any one of these is the
    /// whole answer to the check that reads it.
    public var serious: [Leak] { problems.filter { $0.severity == .bad } }
    /// The one to close first. `leaks` is already worst first.
    public var worst: Leak? { problems.first }

    /// One line for a banner or a headline, when something serious is open.
    /// Nil when there is nothing anybody would be caught by.
    public var alarm: String? {
        guard let first = serious.first else { return nil }
        if serious.count == 1 { return first.title }
        return "\(first.title), and \(serious.count - 1) more like it"
    }

    /// Distance from the pin to where the connection comes out, when known.
    public var ipDistance: Double?

    // MARK: - Thresholds

    /// Inside this the IP is as good as on top of the pin. Metropolitan
    /// geolocation databases are not more precise than this anyway.
    public static let ipNearMetres: Double = 80_000
    /// Beyond this an IP is plainly somewhere else.
    public static let ipFarMetres: Double = 400_000
    /// An IP reading older than this is not worth trusting.
    public static let ipStaleAfter: TimeInterval = 15 * 60
    /// Simulating faster than this while the phone sits still is a contradiction.
    public static let movingSpeed: Double = 2.5
    /// The best a reading can score while a `bad` leak is open.
    ///
    /// The tally is a tally: one bad leak worth twenty-two points leaves a
    /// score of seventy-eight, which every part of the app draws in amber
    /// and calls "mostly covered". That is a lie about what a bad leak is.
    /// A bad leak is not a deduction, it is the whole answer to the check
    /// that reads it, and one of them is enough. Holding the score under the
    /// line turns the ring, the border and the word red wherever they are
    /// drawn, because they all colour by this number.
    public static let seriousCeiling: Int = 49

    // MARK: - Grading

    public static func grade(_ env: Environment) -> Exposure {
        var leaks: [Leak] = []
        var ipDistance: Double?

        // 1. Where the internet connection comes out. This is the check that
        // catches the most people, because it needs no history and no SDK:
        // one request to a geolocation database and the two cities either
        // agree or they do not.
        if let ip = env.ip {
            let distance = ip.coordinate.distance(to: env.pin.coordinate)
            ipDistance = distance
            let stale = env.now.timeIntervalSince(ip.checkedAt) > ipStaleAfter

            if distance > ipFarMetres {
                leaks.append(Leak(
                    kind: .ip,
                    title: "Your connection comes out somewhere else",
                    detail: "The pin is in \(env.pin.placeName.nonEmpty ?? "one place") but your internet address is in \(ip.placeName.nonEmpty ?? "another"), \(Self.describe(distance)) away. Any service that looks up your address will see that.",
                    fix: env.pin.egressAdvice + " Then check again.",
                    severity: .bad,
                    cost: 40
                ))
            } else if distance > ipNearMetres {
                leaks.append(Leak(
                    kind: .ip,
                    title: "Your connection is close, not on top",
                    detail: "Your internet address resolves \(Self.describe(distance)) from the pin. Most checks allow this. Strict ones do not.",
                    fix: "Pick a VPN server in the same city as the pin if one exists.",
                    severity: .weak,
                    cost: 12
                ))
            }

            if stale {
                leaks.append(Leak(
                    kind: .unchecked,
                    title: "The address check is old",
                    detail: "The last look at your internet address was \(Int(env.now.timeIntervalSince(ip.checkedAt) / 60)) minutes ago. Connections change.",
                    fix: "Check again.",
                    severity: .note,
                    cost: 4
                ))
            }

            // 2. Country. Cheaper than distance and checked far more often:
            // every payment processor and most streaming services gate on it.
            if let mine = ip.countryCode?.uppercased(), let theirs = env.pin.countryCode?.uppercased(), mine != theirs {
                leaks.append(Leak(
                    kind: .country,
                    title: "Different country",
                    detail: "The pin is in \(env.pin.countryName ?? theirs) and your address is in \(Locale.current.localizedString(forRegionCode: mine) ?? mine). Country is the first thing a payment or streaming service checks.",
                    fix: "Your VPN server must be in \(env.pin.countryName ?? theirs).",
                    severity: .bad,
                    cost: 30
                ))
            }
        } else {
            leaks.append(Leak(
                kind: .unchecked,
                title: "Internet address not checked",
                detail: "Cloak has not looked at where your connection comes out yet, so the biggest giveaway is unknown.",
                fix: "Check now.",
                severity: .weak,
                cost: 20
            ))
        }

        // 3. Time zone. Apps read TimeZone.current for free and compare it to
        // the location's zone. A pin in Tokyo on a phone set to Chicago is a
        // fourteen hour disagreement that nobody has to look hard for.
        if let pinZone = env.pin.timeZone {
            let hours = abs(Double(pinZone.secondsFromGMT(for: env.now) - env.deviceTimeZone.secondsFromGMT(for: env.now))) / 3600
            if hours >= 3 {
                leaks.append(Leak(
                    kind: .timeZone,
                    title: "Your clock is in the wrong zone",
                    detail: "The pin is in \(pinZone.identifier) and this phone is set to \(env.deviceTimeZone.identifier), \(Self.describeHours(hours)) apart. Any app can read the phone's zone without asking.",
                    fix: "Settings, General, Date & Time: turn off Set Automatically and choose \(env.pin.city ?? pinZone.identifier).",
                    severity: .bad,
                    cost: 22
                ))
            } else if hours >= 1 {
                leaks.append(Leak(
                    kind: .timeZone,
                    title: "Your clock is a zone off",
                    detail: "The pin's zone is \(pinZone.identifier), the phone is on \(env.deviceTimeZone.identifier). \(Self.describeHours(hours)) apart is the kind of thing a neighbouring state explains, and nothing else does.",
                    fix: "Set the phone's time zone to \(env.pin.city ?? pinZone.identifier) in Date & Time.",
                    severity: .weak,
                    cost: 10
                ))
            }
        }

        // 4. Motion. The accelerometer does not lie and it does not need
        // permission from Location Services to be read. A phone reporting
        // sixty miles an hour while its sensors say it is on a table is the
        // single easiest thing for an anti-cheat SDK to catch.
        //
        // Judged over the run rather than this second. The reported speed
        // drops to zero at every light and every stop sign, and asking the
        // question at that moment answers "nothing is moving, nothing is
        // wrong" about a drive the phone never took. Braking does not make
        // the stillness honest, so the movement the run has been claiming is
        // what counts.
        let claimed = max(env.simulatedSpeed, env.recentTopSpeed ?? 0)
        if env.isSimulating, claimed > movingSpeed, env.deviceIsStationary == true {
            leaks.append(Leak(
                kind: .motion,
                title: "Moving on the map, still in your hand",
                detail: "You are reporting travel at up to \(Self.describeSpeed(claimed)) while the phone's own sensors say it has not moved at all. Apps that read motion will see both.",
                fix: "Walk with the phone, or run the drive while you are really travelling. SHIELD does exactly this.",
                severity: .bad,
                cost: 25
            ))
        }

        // 5. The one thing nothing hides. iOS marks every fix that came from a
        // developer simulation, and an app that reads that mark knows. Most
        // do not read it. Saying so plainly is worth more than pretending.
        leaks.append(Leak(
            kind: .softwareFlag,
            title: "iOS marks simulated fixes",
            detail: "Every location Cloak produces carries a flag that says it was simulated. An app that reads that flag will always know. In practice very few do, and the checks above are how the rest catch people.",
            fix: "Nothing closes this one. It is the same for every app in this category.",
            severity: .note,
            cost: 0
        ))

        let cost = leaks.reduce(0) { $0 + $1.cost }
        let ordered = leaks.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return lhs.cost > rhs.cost
        }
        // The score stays the arithmetic. `standing` is what caps a reading
        // with a serious leak in it, so the number and the costs beside it
        // never disagree.
        var reading = Exposure(score: max(0, 100 - cost), leaks: ordered)
        reading.ipDistance = ipDistance
        return reading
    }

    // MARK: - Wording

    public static func describe(_ metres: Double) -> String {
        let usesMetric = Locale.current.measurementSystem == .metric
        if usesMetric {
            return metres >= 1000 ? "\(Int((metres / 1000).rounded())) km" : "\(Int(metres.rounded())) m"
        }
        let miles = metres / 1609.344
        return miles >= 1 ? "\(Int(miles.rounded())) mi" : "\(Int((metres * 3.28084).rounded())) ft"
    }

    public static func describeHours(_ hours: Double) -> String {
        let whole = Int(hours.rounded())
        return whole == 1 ? "one hour" : "\(whole) hours"
    }

    public static func describeSpeed(_ metresPerSecond: Double) -> String {
        if Locale.current.measurementSystem == .metric {
            return "\(Int((metresPerSecond * 3.6).rounded())) km/h"
        }
        return "\(Int((metresPerSecond * 2.23694).rounded())) mph"
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
