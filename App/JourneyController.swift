import Foundation
import CoreLocation
import Observation
import CloakKit

/// Plans and runs a believable trip to the pin, leg by leg.
///
/// The plan is built from real airports and real distances. Running it means
/// handing each leg to the simulation in turn: drives go to the route engine,
/// holds go to the fixed-position engine, and the next leg starts the moment
/// the previous one finishes so the history never shows the real position in
/// between.
@MainActor
@Observable
final class JourneyController {
    static let shared = JourneyController()

    private(set) var proposal: Journey?
    private(set) var destinationPin: Coordinate?
    private(set) var planning = false
    private(set) var problem: String?

    /// What the planner suggested before anybody touched it, so an edit can
    /// always be walked back without going to the network again.
    private(set) var suggestion: Journey.Plan?
    /// Every airport near each end, nearest first, for the airport pickers.
    private(set) var originChoices: [Journey.Airport] = []
    private(set) var destinationChoices: [Journey.Airport] = []

    private(set) var isRunning = false
    private(set) var legIndex = 0
    private(set) var legEndsAt: Date?
    private(set) var startedAt: Date?
    /// Set while a trip with a departure in the future is waiting for it.
    private(set) var waitingUntil: Date?
    /// When the flight really began, which is not always when the plan said
    /// it would: the drive to the airport is built by the route engine and
    /// can run long.
    private(set) var darkLegStartedAt: Date?

    private let airports = AirportFinder()
    private var runner: Task<Void, Never>?
    private weak var model: AppModel?

    /// The recipe behind the current itinerary, when there is one to edit.
    /// A straight drive has nothing to change.
    var editable: Journey.Plan? { isRunning ? nil : proposal?.plan }

    var currentLeg: Journey.Leg? {
        guard isRunning, let proposal, legIndex < proposal.legs.count else { return nil }
        return proposal.legs[legIndex]
    }

    /// When the whole trip ends, given where it is up to.
    var arrivesAt: Date? {
        guard isRunning, let proposal, let legEndsAt, legIndex < proposal.legs.count else { return nil }
        let rest = proposal.legs[(legIndex + 1)...].reduce(0.0) { $0 + $1.duration }
        return legEndsAt.addingTimeInterval(rest)
    }

    func attach(_ model: AppModel) { self.model = model }

    // MARK: - Planning

    func plan(to pin: Coordinate, from origin: Coordinate) async {
        planning = true
        problem = nil
        proposal = nil
        destinationPin = pin
        defer { planning = false }

        let distance = origin.distance(to: pin)
        switch Journey.shape(for: distance) {
        case .drive:
            proposal = Journey.drive(from: origin, to: pin)
        case .fly:
            do {
                async let here = airports.airports(near: origin)
                async let there = airports.airports(near: pin)
                let nearHere = try await here
                let nearThere = try await there
                originChoices = nearHere.sorted { origin.distance(to: $0.door) < origin.distance(to: $1.door) }
                destinationChoices = nearThere.sorted { pin.distance(to: $0.door) < pin.distance(to: $1.door) }
                let departure = Journey.choose(from: nearHere, near: origin)
                let arrival = Journey.choose(from: nearThere, near: pin)
                guard let departure else {
                    problem = "No airport with scheduled flights within 160 km of where you are."
                    return
                }
                guard let arrival else {
                    problem = "No airport with scheduled flights within 160 km of the pin."
                    return
                }
                guard departure.iata != arrival.iata else {
                    proposal = Journey.drive(from: origin, to: pin)
                    return
                }
                // Naming the two ends is what makes the switch advice able to
                // say what to switch to. It changes nothing about the route,
                // so a failure here costs the wording and nothing else.
                async let hereName = region(for: origin)
                async let thereName = region(for: pin)
                let built = Journey.Plan(
                    from: origin,
                    to: pin,
                    origin: departure,
                    destination: arrival,
                    departure: Date(),
                    originRegion: await hereName,
                    destinationRegion: await thereName
                )
                suggestion = built
                proposal = Journey.fly(built)
            } catch {
                problem = "Could not look up airports: \(error.localizedDescription)"
            }
        }
    }

    /// Names one end of the trip.
    ///
    /// A fresh geocoder per call on purpose: `CLGeocoder` handles one request
    /// at a time and answers a second one on the same instance with an error,
    /// so the two ends cannot share one.
    private func region(for coordinate: Coordinate) async -> Journey.Region? {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let mark = try? await geocoder.reverseGeocodeLocation(location).first else { return nil }
        let town = mark.locality ?? mark.subAdministrativeArea ?? mark.administrativeArea
        let name = [town, mark.country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        guard !name.isEmpty || mark.timeZone != nil else { return nil }
        return Journey.Region(
            placeName: name,
            countryCode: mark.isoCountryCode,
            timeZoneIdentifier: mark.timeZone?.identifier
        )
    }

    // MARK: - Editing

    /// Rebuilds the itinerary from an edited plan.
    ///
    /// The legs are never edited in place. They are laid out again from one
    /// clock, which is the only way a change to a hold in the middle cannot
    /// leave something behind it starting before the thing in front of it
    /// has ended.
    func apply(_ plan: Journey.Plan) {
        guard !isRunning else { return }
        proposal = Journey.fly(plan)
    }

    /// Puts back what the planner suggested.
    func resetPlan() {
        guard !isRunning, let suggestion else { return }
        proposal = Journey.fly(suggestion)
    }

    /// Whether the current itinerary differs from the suggested one.
    ///
    /// Never while it is running: starting rewrites the departure to now,
    /// which is not an edit anybody made and not something to offer to undo.
    var isEdited: Bool {
        guard !isRunning, let suggestion, let current = proposal?.plan else { return false }
        return current != suggestion
    }

    // MARK: - Being told when to switch

    var reminds: Bool { RunScheduler.remindsAboutTrips }

    /// Turning reminders on is the one moment notifications are asked for.
    ///
    /// Returns what the user actually ended up with, which is not always what
    /// they asked for: somebody who has already refused Cloak notifications in
    /// Settings gets `false` back and no prompt, because iOS will not show one
    /// twice. Either way the trip is untouched and runs exactly the same.
    @discardableResult
    func setReminders(_ on: Bool) async -> Bool {
        guard on else {
            RunScheduler.remindsAboutTrips = false
            RunScheduler.disarmTripCues()
            return false
        }
        let allowed = await RunScheduler.askAboutTripCues()
        RunScheduler.remindsAboutTrips = allowed
        if allowed, isRunning, let proposal {
            RunScheduler.armTripCues(proposal.cues(startingAt: darkLegStartedAt))
        }
        return allowed
    }

    // MARK: - Running

    func start() {
        guard var journey = proposal, let model, !isRunning else { return }
        // A plan drawn up ten minutes ago says it left ten minutes ago. Leave
        // now instead. A departure the user deliberately moved into the
        // future is left where they put it and waited for.
        if let recipe = journey.plan, recipe.departure < Date() {
            var fresh = recipe
            fresh.departure = Date()
            journey = Journey.fly(fresh)
            proposal = journey
        }
        isRunning = true
        legIndex = 0
        darkLegStartedAt = nil
        startedAt = Date()
        if RunScheduler.remindsAboutTrips {
            RunScheduler.armTripCues(journey.cues)
        }
        runner = Task { [weak self] in
            await self?.run(journey, on: model)
        }
    }

    func cancel() {
        runner?.cancel()
        runner = nil
        isRunning = false
        legEndsAt = nil
        waitingUntil = nil
        darkLegStartedAt = nil
        // A trip that is not happening must not go on telling somebody to
        // change their VPN for it.
        RunScheduler.disarmTripCues()
    }

    private func run(_ journey: Journey, on model: AppModel) async {
        // A departure in the future is a departure in the future.
        if journey.departs > Date() {
            waitingUntil = journey.departs
            while !Task.isCancelled, Date() < journey.departs {
                try? await Task.sleep(for: .seconds(min(20, max(1, journey.departs.timeIntervalSinceNow))))
            }
            waitingUntil = nil
        }

        // Timings are re-based on now, so a plan drawn up ten minutes ago
        // still lines up when it starts.
        let offset = Date().timeIntervalSince(journey.departs)

        // Set when the simulation is stopped from somewhere other than here,
        // which ends the trip whatever the itinerary still says.
        var stoppedByHand = false

        for (index, leg) in journey.legs.enumerated() {
            guard !Task.isCancelled else { break }
            legIndex = index
            let plannedEnd = leg.end.addingTimeInterval(offset)
            legEndsAt = plannedEnd

            switch leg.kind {
            case .drive(let from, let to):
                await model.travel(from: from, to: to, label: leg.name, mode: .drive)
                // The route engine decides how long the drive really takes.
                // Wait for it to finish, with a ceiling so a stuck drive does
                // not hold the whole trip hostage.
                let ceiling = Date().addingTimeInterval(leg.duration * 1.8 + 120)
                while !Task.isCancelled, model.snapshot.isRunning, Date() < ceiling {
                    try? await Task.sleep(for: .seconds(2))
                }

            case .hold(let where_, let drift):
                if leg.isDark {
                    // The drive to the airport is built by the route engine
                    // and can take longer than the estimate, which moves the
                    // silence and everything worth saying inside it. Now that
                    // it has actually begun, say so.
                    darkLegStartedAt = Date()
                    if RunScheduler.remindsAboutTrips {
                        RunScheduler.armTripCues(journey.cues(startingAt: darkLegStartedAt))
                    }
                }
                await model.hold(at: where_, label: leg.name, drift: drift)
                // Somebody who hits stop on the main controls has stopped the
                // trip, not just this leg. Carrying on would put the phone
                // back at the gate a few seconds later and would leave the
                // switch reminders armed for a flight that is not happening.
                //
                // It takes two readings in a row to believe it, and only after
                // the hold has been seen running at least once. The tunnel
                // reconnects by itself (`snapshot.reconnectCount` counts it),
                // and a trip aborting eight hours in because one poll landed
                // inside a reconnect would be much worse than noticing a stop
                // fifteen seconds late.
                var everRan = false
                var missed = 0
                while !Task.isCancelled, Date() < plannedEnd {
                    try? await Task.sleep(for: .seconds(min(15, max(1, plannedEnd.timeIntervalSinceNow))))
                    if model.snapshot.isRunning {
                        everRan = true
                        missed = 0
                        continue
                    }
                    guard everRan else { continue }
                    missed += 1
                    if missed >= 2 {
                        stoppedByHand = true
                        break
                    }
                }
                if stoppedByHand { break }
            }
        }

        if !Task.isCancelled {
            legIndex = journey.legs.count
            // Never end this silently. A trip that stops halfway and says
            // nothing looks exactly like a trip that quietly broke.
            model.banner = stoppedByHand
                ? "Trip stopped. The rest of the itinerary was dropped and the switch reminders are off."
                : "Arrived. The history shows a trip, not a jump."
        }
        isRunning = false
        legEndsAt = nil
        waitingUntil = nil
        darkLegStartedAt = nil
        runner = nil
        RunScheduler.disarmTripCues()
    }
}
