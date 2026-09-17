import Testing
import Foundation
@testable import CloakKit

/// Durations come back out of two `Date`s a third of a billion seconds wide,
/// so they are only ever good to a fraction of a millisecond.
private func near(_ a: TimeInterval, _ b: TimeInterval, _ slack: TimeInterval = 0.001) -> Bool {
    abs(a - b) < slack
}

/// An itinerary the user has taken apart and put back together.
@Suite("Journey editing")
struct JourneyEditingTests {
    let dallas = Coordinate(latitude: 32.7767, longitude: -96.7970)
    let manhattan = Coordinate(latitude: 40.7580, longitude: -73.9855)
    let dfw = Journey.Airport(
        name: "Dallas Fort Worth International", iata: "DFW",
        coordinate: Coordinate(latitude: 32.8998, longitude: -97.0403),
        terminal: Coordinate(latitude: 32.9010, longitude: -97.0420),
        isInternational: true)
    let love = Journey.Airport(
        name: "Dallas Love Field", iata: "DAL",
        coordinate: Coordinate(latitude: 32.8471, longitude: -96.8518),
        isInternational: false)
    let jfk = Journey.Airport(
        name: "John F. Kennedy International", iata: "JFK",
        coordinate: Coordinate(latitude: 40.6413, longitude: -73.7781),
        terminal: Coordinate(latitude: 40.6440, longitude: -73.7830),
        isInternational: true)
    let ewr = Journey.Airport(
        name: "Newark Liberty International", iata: "EWR",
        coordinate: Coordinate(latitude: 40.6895, longitude: -74.1745),
        isInternational: true)
    let departing = Date(timeIntervalSince1970: 1_758_000_000)

    private func basePlan() -> Journey.Plan {
        Journey.Plan(from: dallas, to: manhattan, origin: dfw, destination: jfk, departure: departing)
    }

    @Test func theDefaultPlanBuildsTheSameItineraryAsBefore() {
        let byHand = Journey.fly(basePlan())
        let asBefore = Journey.fly(from: dallas, to: manhattan, via: dfw, and: jfk, departing: departing)
        #expect(byHand.legs.map(\.name) == asBefore.legs.map(\.name))
        #expect(zip(byHand.legs, asBefore.legs).allSatisfy { near($0.duration, $1.duration) })
        #expect(byHand.plan != nil)
    }

    @Test func everyEditLeavesTheLegsInOrder() {
        // The invariant that matters: whatever comes out of the editor, no
        // leg may start before the one in front of it has ended.
        var plans: [Journey.Plan] = []
        let beforeChoices: [TimeInterval] = [0, 60, 82 * 60, 9 * 3600, -500, 40 * 3600]
        let afterChoices: [TimeInterval] = [0, 34 * 60, 3 * 3600]
        for before in beforeChoices {
            for after in afterChoices {
                for toAirport in [true, false] {
                    for fromAirport in [true, false] {
                        var plan = basePlan()
                        plan.beforeFlight = before
                        plan.afterFlight = after
                        plan.drivesToAirport = toAirport
                        plan.drivesFromAirport = fromAirport
                        plans.append(plan)
                    }
                }
            }
        }
        for plan in plans {
            let journey = Journey.fly(plan)
            #expect(journey.isSequential, "\(plan.beforeFlight)/\(plan.afterFlight) came out overlapping")
            #expect(journey.legs.allSatisfy { $0.duration > 0 })
            #expect(journey.departs <= journey.arrives)
        }
    }

    @Test func aHoldShortenedToNothingRemovesTheLeg() {
        var plan = basePlan()
        plan.beforeFlight = 0
        let journey = Journey.fly(plan)
        #expect(!journey.legs.contains { $0.name == "At DFW" })
        #expect(journey.legs.contains { $0.name == "In the air" })
        #expect(journey.isSequential)

        plan.afterFlight = 0
        let barer = Journey.fly(plan)
        #expect(!barer.legs.contains { $0.name.hasPrefix("Landed") })
        #expect(barer.isSequential)
    }

    @Test func shorteningAHoldShortensTheTrip() {
        let full = Journey.fly(basePlan())
        var plan = basePlan()
        plan.beforeFlight = 30 * 60
        let trimmed = Journey.fly(plan)
        #expect(trimmed.totalDuration < full.totalDuration)
        #expect(near(full.totalDuration - trimmed.totalDuration, Journey.beforeFlight - 30 * 60))
        let hold = trimmed.legs.first { $0.name == "At DFW" }
        #expect(near(hold?.duration ?? 0, 30 * 60))
    }

    @Test func theDrivesCanBeDropped() {
        var plan = basePlan()
        plan.drivesToAirport = false
        plan.drivesFromAirport = false
        let journey = Journey.fly(plan)
        #expect(journey.legs.map(\.name) == ["At DFW", "In the air", "Landed at JFK"])
        #expect(journey.legs.first?.start == departing)
        #expect(journey.isSequential)
    }

    @Test func aHoldCannotBeNegativeOrAWeekLong() {
        var plan = basePlan()
        plan.beforeFlight = -3600
        plan.afterFlight = 400 * 3600
        let tidied = plan.tidied
        #expect(tidied.beforeFlight == 0)
        #expect(tidied.afterFlight == Journey.longestHold)
        let journey = Journey.fly(plan)
        #expect(journey.legs.allSatisfy { $0.duration > 0 })
        #expect(near(journey.legs.first { $0.name.hasPrefix("Landed") }?.duration ?? 0, Journey.longestHold))
    }

    @Test func movingTheDepartureMovesTheWholeItinerary() {
        let later = departing.addingTimeInterval(6 * 3600)
        var plan = basePlan()
        plan.departure = later
        let journey = Journey.fly(plan)
        let same = Journey.fly(basePlan())
        #expect(journey.departs == later)
        #expect(near(journey.totalDuration, same.totalDuration))
        #expect(journey.isSequential)
        for (a, b) in zip(journey.legs, same.legs) {
            #expect(near(a.start.timeIntervalSince(b.start), 6 * 3600))
        }
    }

    @Test func swappingAnAirportRenamesAndRetimesTheFlight() {
        var plan = basePlan()
        plan.origin = love
        plan.destination = ewr
        let journey = Journey.fly(plan)
        #expect(journey.legs.map(\.name) == ["To DAL", "At DAL", "In the air", "Landed at EWR", "To the pin"])
        #expect(journey.origin?.iata == "DAL")
        #expect(journey.destination?.iata == "EWR")
        #expect(journey.summary.contains("DAL to EWR"))
        let air = journey.legs.first { $0.name == "In the air" }!
        #expect(air.duration > Journey.flightOverhead)
        #expect(journey.isSequential)
    }

    @Test func aRebuiltItineraryStillAimsAtTheDoor() {
        var plan = basePlan()
        plan.beforeFlight = 20 * 60
        plan.drivesFromAirport = false
        let journey = Journey.fly(plan)
        for leg in journey.legs {
            switch leg.kind {
            case .drive(_, let to):
                #expect(to == dfw.door)
                #expect(to != dfw.coordinate)
            case .hold(let where_, let drift) where drift > 0:
                #expect(where_ == dfw.door || where_ == jfk.door)
            default:
                continue
            }
        }
    }

    @Test func theFlightItselfIsNotEditable() {
        // Air time is arithmetic on the distance. There is no field for it,
        // and the leg can never come out shorter than the taxi and the climb.
        let plan = basePlan()
        #expect(plan.airTime > Journey.flightOverhead)
        let journey = Journey.fly(plan)
        let air = journey.legs.first { $0.name == "In the air" }!
        #expect(near(air.duration, max(Journey.flightOverhead, plan.airTime)))
        #expect(air.isDark)
    }

    @Test func resequencingRepairsAnOverlap() {
        var journey = Journey.fly(basePlan())
        // Shove one leg backwards, the way a careless edit would.
        journey.legs[2].start = journey.legs[1].start
        journey.legs[2].end = journey.legs[2].start.addingTimeInterval(3600)
        #expect(!journey.isSequential)
        let fixed = journey.resequenced()
        #expect(fixed.isSequential)
        #expect(near(fixed.legs[2].duration, 3600))
        #expect(fixed.legs[2].start == fixed.legs[1].end)
    }

    @Test func aTerminalHoldIsStillWalkedNotDrifted() {
        // 45 m played as short walks. An edit must not turn it into anything
        // else, whatever it does to the length.
        var plan = basePlan()
        plan.beforeFlight = 4 * 3600
        let journey = Journey.fly(plan)
        guard case .hold(_, let drift)? = journey.legs.first(where: { $0.name == "At DFW" })?.kind else {
            Issue.record("the terminal hold went missing")
            return
        }
        #expect(drift == Journey.terminalWander)
    }
}

/// Knowing when a change to the device is invisible.
@Suite("Journey cues")
struct JourneyCueTests {
    let dallas = Coordinate(latitude: 32.7767, longitude: -96.7970)
    let tokyoPin = Coordinate(latitude: 35.6812, longitude: 139.7671)
    let dfw = Journey.Airport(
        name: "Dallas Fort Worth International", iata: "DFW",
        coordinate: Coordinate(latitude: 32.8998, longitude: -97.0403),
        isInternational: true)
    let hnd = Journey.Airport(
        name: "Tokyo Haneda", iata: "HND",
        coordinate: Coordinate(latitude: 35.5494, longitude: 139.7798),
        isInternational: true)
    let departing = Date(timeIntervalSince1970: 1_758_000_000)

    private var chicago: Journey.Region {
        Journey.Region(placeName: "Dallas, United States", countryCode: "US", timeZoneIdentifier: "America/Chicago")
    }
    private var tokyo: Journey.Region {
        Journey.Region(placeName: "Tokyo, Japan", countryCode: "JP", timeZoneIdentifier: "Asia/Tokyo")
    }

    private func plan(origin: Journey.Region? = nil, destination: Journey.Region? = nil) -> Journey.Plan {
        Journey.Plan(
            from: dallas, to: tokyoPin, origin: dfw, destination: hnd,
            departure: departing, originRegion: origin, destinationRegion: destination)
    }

    @Test func aDriveHasNothingToChange() {
        let drive = Journey.drive(from: dallas, to: Coordinate(latitude: 30.2672, longitude: -97.7431), departing: departing)
        #expect(drive.cues.isEmpty)
        #expect(!drive.changesRegion)
        #expect(!drive.changesTimeZone)
        #expect(drive.darkLeg == nil)
    }

    @Test func everyFlightWantsTheConnectionMoved() {
        let journey = Journey.fly(plan())
        #expect(journey.changesRegion)
        let cues = journey.cues
        #expect(cues.contains { $0.kind == .vpn })
        // Nothing knows where the pin is, so the airport is the best name
        // available and the cue still says what to set it to.
        let vpn = cues.first { $0.kind == .vpn }!
        #expect(vpn.body.contains("Tokyo Haneda"))
        #expect(vpn.body.contains("HND"))
    }

    @Test func theCueNamesThePlaceWhenTheMapKnowsIt() {
        let journey = Journey.fly(plan(origin: chicago, destination: tokyo))
        let vpn = journey.cues.first { $0.kind == .vpn }!
        #expect(vpn.body.contains("Tokyo, Japan"))
        #expect(vpn.title == "Switch your VPN now")
    }

    @Test func theMomentIsBuriedInsideTheSilence() {
        let journey = Journey.fly(plan(origin: chicago, destination: tokyo))
        let dark = journey.darkLeg!
        let margin = min(5 * 60, dark.duration * 0.1)
        for cue in journey.cues {
            #expect(cue.at >= dark.start.addingTimeInterval(margin))
            #expect(cue.at <= dark.end.addingTimeInterval(-margin))
        }
        // And near the middle, which is the point furthest from the last fix
        // at one gate and the first fix at the other.
        let vpn = journey.cues.first { $0.kind == .vpn }!
        let middle = dark.start.addingTimeInterval(dark.duration / 2)
        #expect(abs(vpn.at.timeIntervalSince(middle)) < 1)
    }

    @Test func noClockAdviceWhenNobodyKnowsTheZones() {
        #expect(Journey.fly(plan()).cues.allSatisfy { $0.kind == .vpn })
        #expect(Journey.fly(plan(origin: chicago)).timeZoneShift == nil)
        #expect(Journey.fly(plan(destination: tokyo)).timeZoneShift == nil)
    }

    @Test func noClockAdviceWhenTheZonesAgree() {
        let newYork = Journey.Region(placeName: "New York, United States", countryCode: "US", timeZoneIdentifier: "America/Chicago")
        let journey = Journey.fly(plan(origin: chicago, destination: newYork))
        #expect(!journey.changesTimeZone)
        #expect(journey.cues.allSatisfy { $0.kind == .vpn })
    }

    @Test func theClockCueSaysWhatToSetAndByHowMuch() {
        let journey = Journey.fly(plan(origin: chicago, destination: tokyo))
        #expect(journey.changesTimeZone)
        let shift = journey.timeZoneShift!
        #expect(shift > 12 * 3600)
        #expect(shift < 16 * 3600)
        let cue = journey.cues.first { $0.kind == .timeZone }!
        #expect(cue.title == "Change the phone's time zone now")
        #expect(cue.body.contains("ahead of"))
        #expect(cue.body.contains("hours"))
    }

    @Test func theConnectionMovesBeforeTheClock() {
        let cues = Journey.fly(plan(origin: chicago, destination: tokyo)).cues
        #expect(cues.count == 2)
        #expect(cues[0].kind == .vpn)
        #expect(cues[1].kind == .timeZone)
        #expect(cues[1].at > cues[0].at)
        #expect(cues[0].id != cues[1].id)
    }

    @Test func aRunThatKnowsTheRealTakeoffMovesTheMoments() {
        let journey = Journey.fly(plan(origin: chicago, destination: tokyo))
        let late = journey.darkLeg!.start.addingTimeInterval(47 * 60)
        let moved = journey.cues(startingAt: late)
        #expect(moved.count == journey.cues.count)
        for (a, b) in zip(journey.cues, moved) {
            #expect(near(b.at.timeIntervalSince(a.at), 47 * 60))
        }
    }

    @Test func aShortenedTerminalHoldDoesNotMoveTheFlightOutOfTheCue() {
        var edited = plan(origin: chicago, destination: tokyo)
        edited.beforeFlight = 0
        edited.drivesToAirport = false
        let journey = Journey.fly(edited)
        let dark = journey.darkLeg!
        #expect(dark.start == journey.departs)
        for cue in journey.cues {
            #expect(cue.at > dark.start)
            #expect(cue.at < dark.end)
        }
    }

    @Test func nothingSaysItInEmDashes() {
        let journey = Journey.fly(plan(origin: chicago, destination: tokyo))
        for cue in journey.cues {
            #expect(!cue.body.contains("\u{2014}"))
            #expect(!cue.title.contains("\u{2014}"))
            #expect(!cue.body.isEmpty)
        }
    }

    @Test func offsetsReadTheWayAPersonSaysThem() {
        #expect(Journey.describeShift(5 * 3600) == "5 hours ahead of")
        #expect(Journey.describeShift(-3600) == "1 hour behind")
        #expect(Journey.describeShift(5.5 * 3600) == "5 hours 30 min ahead of")
        #expect(Journey.describeShift(-45 * 60) == "45 min behind")
        #expect(Journey.describeShift(0) == "level with")
    }

    @Test func swappingTheArrivalAirportChangesWhatTheCueSays() {
        var edited = plan(origin: chicago, destination: tokyo)
        edited.destination = Journey.Airport(
            name: "Tokyo Narita", iata: "NRT",
            coordinate: Coordinate(latitude: 35.7647, longitude: 140.3864),
            isInternational: true)
        let cue = Journey.fly(edited).cues.first { $0.kind == .vpn }!
        #expect(cue.body.contains("NRT"))
        #expect(!cue.body.contains("HND"))
    }

    @Test func tidyingTwiceChangesNothingTheSecondTime() {
        var messy = plan()
        messy.beforeFlight = -1
        messy.afterFlight = 99 * 3600
        let once = messy.tidied
        #expect(once.tidied == once)
        #expect(Journey.fly(once) == Journey.fly(messy))
    }

    @Test func editingKeepsTheRegionsAttached() {
        var edited = plan(origin: chicago, destination: tokyo)
        edited.afterFlight = 12 * 60
        let journey = Journey.fly(edited)
        #expect(journey.plan?.destinationRegion == tokyo)
        #expect(journey.changesTimeZone)
        #expect(journey.cues.count == 2)
    }
}
