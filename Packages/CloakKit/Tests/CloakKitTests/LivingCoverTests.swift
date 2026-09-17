import Testing
import Foundation
@testable import CloakKit

@Suite("Idle jitter")
struct IdleJitterTests {
    @Test func staysMostlyWithinRadiusButBreachesOnMultipath() {
        var jitter = IdleJitter(anchor: Coordinate(latitude: 37.0, longitude: -122.0), radius: 8, seed: 42)
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        var maxOffset = 0.0
        var breaches = 0
        for _ in 0..<3600 {
            now = now.addingTimeInterval(1)
            let fix = jitter.next(now: now)
            let d = fix.coordinate.distance(to: Coordinate(latitude: 37.0, longitude: -122.0))
            maxOffset = max(maxOffset, d)
            if d > 8 { breaches += 1 }
        }
        // It drifts to the edge and occasionally past it, but never runs away.
        #expect(maxOffset > 4)
        #expect(maxOffset < 60)
        #expect(breaches > 0)
    }

    @Test func isAutocorrelatedNotWhiteNoise() {
        var jitter = IdleJitter(anchor: Coordinate(latitude: 40.0, longitude: -74.0), radius: 6, seed: 7)
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        var samples: [Double] = []
        let base = Coordinate(latitude: 40.0, longitude: -74.0)
        for _ in 0..<600 {
            now = now.addingTimeInterval(1)
            let fix = jitter.next(now: now)
            samples.append(fix.coordinate.offsetNorth(from: base))
        }
        // Consecutive step differences should be far smaller than the spread of
        // the signal itself: that is what autocorrelation means, and what a
        // uniform-noise spoofer fails.
        let spread = standardDeviation(samples)
        var stepDiffs: [Double] = []
        for i in 1..<samples.count { stepDiffs.append(samples[i] - samples[i-1]) }
        let stepSpread = standardDeviation(stepDiffs)
        #expect(stepSpread < spread * 0.5)
    }

    /// Set a pin and stand still. The dot has to look alive without being seen
    /// to move: this checks the radius the app actually sends for a plain pin,
    /// and that a multipath excursion arrives as a lean rather than a hop.
    @Test func aPinnedPositionDoesNotVisiblyWander() {
        let anchor = Coordinate(latitude: 37.0, longitude: -122.0)
        let pin = TunnelStartPayload.fixed(anchor, label: "Pin")
        var jitter = IdleJitter(anchor: anchor, radius: pin.dwellRadius, seed: 12_345)
        #expect(jitter.behaviour == .resting)

        var now = Date(timeIntervalSince1970: 1_700_000_000)
        var previous: Coordinate?
        var worstStep = 0.0
        var worstOffset = 0.0
        for _ in 0..<3600 {
            now = now.addingTimeInterval(1)
            let fix = jitter.next(now: now)
            if let previous { worstStep = max(worstStep, previous.distance(to: fix.coordinate)) }
            previous = fix.coordinate
            worstOffset = max(worstOffset, anchor.distance(to: fix.coordinate))
            #expect(fix.speed == 0)
        }
        // An hour of standing still: never as much as a pace between one fix
        // and the next, and never further off than the width of a house.
        #expect(worstStep < 2.5)
        #expect(worstOffset < 12)
        // Still alive, though. A position that never moves at all is its own
        // giveaway.
        #expect(worstOffset > 1.5)
    }

    /// A wait at an airport gate. The radius there is ground to cover, not
    /// receiver error, so it is played as walking: short trips at walking
    /// pace with long sits between them, rather than the position being flung
    /// tens of metres a second.
    @Test func aTerminalHoldWalksRatherThanTeleports() {
        let gate = Coordinate(latitude: 32.8998, longitude: -97.0403)
        #expect(IdleJitter(anchor: gate, radius: 9).behaviour == .resting)
        var jitter = IdleJitter(anchor: gate, radius: Journey.terminalWander, seed: 99)
        #expect(jitter.behaviour == .wandering)

        var now = Date(timeIntervalSince1970: 1_700_000_000)
        var previous: Coordinate?
        var worstStep = 0.0
        var worstOffset = 0.0
        var moving = 0
        let seconds = Int(Journey.beforeFlight)
        for _ in 0..<seconds {
            now = now.addingTimeInterval(1)
            let fix = jitter.next(now: now)
            if let previous { worstStep = max(worstStep, previous.distance(to: fix.coordinate)) }
            previous = fix.coordinate
            worstOffset = max(worstOffset, gate.distance(to: fix.coordinate))
            if fix.speed > 0 { moving += 1 }
            // Nobody runs through a terminal.
            #expect(fix.speed < 2)
        }
        // Walking pace plus the receiver's own noise, not a jump.
        #expect(worstStep < 5)
        // It does get up and go somewhere, and stays inside the building.
        #expect(worstOffset > 20)
        #expect(worstOffset < Journey.terminalWander + 15)
        // And spends most of the wait sitting, which is what a gate wait is.
        #expect(moving > 0)
        #expect(Double(moving) / Double(seconds) < 0.5)
    }

    private func standardDeviation(_ values: [Double]) -> Double {
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot()
    }
}

@Suite("Living Cover")
struct LivingCoverTests {
    private func places() -> [DiscoveredPlace] {
        let home = Coordinate(latitude: 37.0, longitude: -122.0)
        return [
            DiscoveredPlace(name: "Blue Bottle", category: .coffee, coordinate: home.offset(metersNorth: 300, metersEast: 100)),
            DiscoveredPlace(name: "Corner Deli", category: .food, coordinate: home.offset(metersNorth: -200, metersEast: 400)),
            DiscoveredPlace(name: "Iron Works Gym", category: .gym, coordinate: home.offset(metersNorth: 800, metersEast: -300)),
            DiscoveredPlace(name: "SaveMart", category: .grocery, coordinate: home.offset(metersNorth: 500, metersEast: 600))
        ]
    }

    @Test func buildsARoutineAnchoredToRealPlaces() {
        let home = Coordinate(latitude: 37.0, longitude: -122.0)
        let work = Coordinate(latitude: 37.02, longitude: -122.01)
        let cover = LivingCover(home: home, work: work)
        let routine = cover.routine(from: places(), density: 0.8)
        #expect(routine.errands.count == 4)
        #expect(routine.work.distance(to: work) < 1)
    }

    @Test func sameDayAlwaysPlansTheSame() {
        let home = Coordinate(latitude: 37.0, longitude: -122.0)
        let cover = LivingCover(home: home, work: Coordinate(latitude: 37.02, longitude: -122.01))
        let routine = cover.routine(from: places(), density: 0.9)
        let day = Date(timeIntervalSince1970: 1_757_000_000)
        let a = routine.plan(for: day)
        let b = routine.plan(for: day)
        #expect(a.segments.count == b.segments.count)
        #expect(a.segments.map(\.kind.name) == b.segments.map(\.kind.name))
    }

    @Test func differentDaysDiffer() {
        let home = Coordinate(latitude: 37.0, longitude: -122.0)
        let cover = LivingCover(home: home, work: Coordinate(latitude: 37.02, longitude: -122.01))
        var routine = cover.routine(from: places(), density: 0.9)
        // A fixed seed, so this measures the day-to-day variation and not the
        // luck of whichever seed the routine was born with.
        routine.seed = 0x5EED_C0FF_EE12_3456
        var shapes = Set<String>()
        for offset in 0..<14 {
            let day = Date(timeIntervalSince1970: 1_757_000_000 + Double(offset) * 86_400)
            let plan = routine.plan(for: day)
            shapes.insert(plan.segments.map(\.kind.name).joined(separator: ">"))
        }
        // Two weeks should not all be identical.
        #expect(shapes.count > 3)
    }

    @Test func segmentsNeverOverlapOrGoBackwards() {
        let home = Coordinate(latitude: 37.0, longitude: -122.0)
        let cover = LivingCover(home: home, work: Coordinate(latitude: 37.02, longitude: -122.01))
        let routine = cover.routine(from: places(), density: 1.0)
        for offset in 0..<21 {
            let day = Date(timeIntervalSince1970: 1_757_000_000 + Double(offset) * 86_400)
            let segments = routine.plan(for: day).segments
            for i in 1..<segments.count {
                #expect(segments[i].start >= segments[i-1].end - 0.001)
                #expect(segments[i].end >= segments[i].start)
            }
        }
    }

    @Test func errandsHappenAtPlausibleHours() {
        let home = Coordinate(latitude: 37.0, longitude: -122.0)
        let cover = LivingCover(home: home, work: Coordinate(latitude: 37.02, longitude: -122.01))
        let routine = cover.routine(from: places(), density: 1.0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // The errands have to come from the routine being planned. Calling
        // `routine(from:)` a second time builds a fresh one with a fresh
        // random seed, so a name found in this plan was matched against some
        // other routine's errand and the category compared was not the
        // category that produced the segment. That made this test fail about
        // one run in six for no reason anybody could reproduce.
        let errands = routine.errands
        for offset in 0..<30 {
            let day = Date(timeIntervalSince1970: 1_757_000_000 + Double(offset) * 86_400)
            for segment in routine.plan(for: day, calendar: calendar).segments {
                if case .dwell(_, let name, _) = segment.kind,
                   let place = errands.first(where: { $0.name == name }) {
                    let hour = calendar.component(.hour, from: segment.start)
                    #expect(place.category.plausible(atHour: hour), "\(name) at \(hour):00")
                }
            }
        }
    }
}
