import Testing
import Foundation
@testable import CloakKit

@Suite("Exposure")
struct ExposureTests {
    let newYork = Coordinate(latitude: 40.7128, longitude: -74.0060)
    let losAngeles = Coordinate(latitude: 34.0522, longitude: -118.2437)
    let newark = Coordinate(latitude: 40.7357, longitude: -74.1724)
    let philadelphia = Coordinate(latitude: 39.9526, longitude: -75.1652)
    let tokyo = Coordinate(latitude: 35.6762, longitude: 139.6503)
    let now = Date(timeIntervalSince1970: 1_758_000_000)

    func pin(_ c: Coordinate, city: String, country: String, zone: String) -> Exposure.PinPlace {
        Exposure.PinPlace(coordinate: c, city: city, countryCode: country, timeZone: TimeZone(identifier: zone))
    }

    func ip(_ c: Coordinate, city: String, country: String, age: TimeInterval = 0) -> Exposure.IPPlace {
        Exposure.IPPlace(address: "203.0.113.7", coordinate: c, city: city, countryCode: country, checkedAt: now.addingTimeInterval(-age))
    }

    @Test func matchingEverythingIsCovered() {
        let env = Exposure.Environment(
            pin: pin(newYork, city: "New York", country: "US", zone: "America/New_York"),
            ip: ip(newark, city: "Newark", country: "US"),
            deviceTimeZone: TimeZone(identifier: "America/New_York")!,
            deviceIsStationary: true,
            simulatedSpeed: 0,
            isSimulating: true,
            now: now
        )
        let reading = Exposure.grade(env)
        #expect(reading.isClean)
        #expect(reading.score == 100)
        #expect(reading.leaks.contains { $0.kind == .softwareFlag })
        #expect(reading.ipDistance! < Exposure.ipNearMetres)
    }

    @Test func farIPIsTheBiggestLeak() {
        let env = Exposure.Environment(
            pin: pin(newYork, city: "New York", country: "US", zone: "America/New_York"),
            ip: ip(losAngeles, city: "Los Angeles", country: "US"),
            deviceTimeZone: TimeZone(identifier: "America/New_York")!,
            now: now
        )
        let reading = Exposure.grade(env)
        let leak = reading.leaks.first { $0.kind == .ip }
        #expect(leak?.severity == .bad)
        #expect(reading.score <= 60)
        #expect(leak!.fix.contains("New York"))
    }

    @Test func nearbyIPIsOnlyAWeakLeak() {
        let env = Exposure.Environment(
            pin: pin(newYork, city: "New York", country: "US", zone: "America/New_York"),
            ip: ip(philadelphia, city: "Philadelphia", country: "US"),
            deviceTimeZone: TimeZone(identifier: "America/New_York")!,
            now: now
        )
        let reading = Exposure.grade(env)
        let leak = reading.leaks.first { $0.kind == .ip }
        #expect(leak?.severity == .weak)
        #expect(reading.leaks.first { $0.kind == .country } == nil)
    }

    @Test func differentCountryIsCalledOutSeparately() {
        let env = Exposure.Environment(
            pin: pin(tokyo, city: "Tokyo", country: "JP", zone: "Asia/Tokyo"),
            ip: ip(newYork, city: "New York", country: "US"),
            deviceTimeZone: TimeZone(identifier: "Asia/Tokyo")!,
            now: now
        )
        let reading = Exposure.grade(env)
        #expect(reading.leaks.contains { $0.kind == .ip && $0.severity == .bad })
        #expect(reading.leaks.contains { $0.kind == .country && $0.severity == .bad })
        #expect(reading.score < 40)
    }

    @Test func timeZoneMismatchScalesWithHours() {
        let small = Exposure.Environment(
            pin: pin(newYork, city: "New York", country: "US", zone: "America/New_York"),
            ip: ip(newark, city: "Newark", country: "US"),
            deviceTimeZone: TimeZone(identifier: "America/Chicago")!,
            now: now
        )
        let large = Exposure.Environment(
            pin: pin(newYork, city: "New York", country: "US", zone: "America/New_York"),
            ip: ip(newark, city: "Newark", country: "US"),
            deviceTimeZone: TimeZone(identifier: "Asia/Tokyo")!,
            now: now
        )
        #expect(Exposure.grade(small).leaks.first { $0.kind == .timeZone }?.severity == .weak)
        #expect(Exposure.grade(large).leaks.first { $0.kind == .timeZone }?.severity == .bad)
    }

    @Test func stationaryPhoneWhileDrivingIsALeak() {
        let env = Exposure.Environment(
            pin: pin(newYork, city: "New York", country: "US", zone: "America/New_York"),
            ip: ip(newark, city: "Newark", country: "US"),
            deviceTimeZone: TimeZone(identifier: "America/New_York")!,
            deviceIsStationary: true,
            simulatedSpeed: 20,
            isSimulating: true,
            now: now
        )
        #expect(Exposure.grade(env).leaks.first { $0.kind == .motion }?.severity == .bad)
    }

    @Test func stationaryPhoneWhileParkedIsFine() {
        let env = Exposure.Environment(
            pin: pin(newYork, city: "New York", country: "US", zone: "America/New_York"),
            ip: ip(newark, city: "Newark", country: "US"),
            deviceTimeZone: TimeZone(identifier: "America/New_York")!,
            deviceIsStationary: true,
            simulatedSpeed: 0.4,
            isSimulating: true,
            now: now
        )
        #expect(Exposure.grade(env).leaks.first { $0.kind == .motion } == nil)
    }

    @Test func unknownMotionDoesNotAccuse() {
        let env = Exposure.Environment(
            pin: pin(newYork, city: "New York", country: "US", zone: "America/New_York"),
            ip: ip(newark, city: "Newark", country: "US"),
            deviceTimeZone: TimeZone(identifier: "America/New_York")!,
            deviceIsStationary: nil,
            simulatedSpeed: 20,
            isSimulating: true,
            now: now
        )
        #expect(Exposure.grade(env).leaks.first { $0.kind == .motion } == nil)
    }

    @Test func noIPCheckIsFlaggedNotIgnored() {
        let env = Exposure.Environment(
            pin: pin(newYork, city: "New York", country: "US", zone: "America/New_York"),
            ip: nil,
            deviceTimeZone: TimeZone(identifier: "America/New_York")!,
            now: now
        )
        let reading = Exposure.grade(env)
        #expect(reading.leaks.contains { $0.kind == .unchecked })
        #expect(reading.ipDistance == nil)
        #expect(reading.score < 100)
    }

    @Test func staleIPIsANote() {
        let env = Exposure.Environment(
            pin: pin(newYork, city: "New York", country: "US", zone: "America/New_York"),
            ip: ip(newark, city: "Newark", country: "US", age: 20 * 60),
            deviceTimeZone: TimeZone(identifier: "America/New_York")!,
            now: now
        )
        let reading = Exposure.grade(env)
        #expect(reading.leaks.contains { $0.kind == .unchecked && $0.severity == .note })
    }

    @Test func worstLeaksComeFirst() {
        let env = Exposure.Environment(
            pin: pin(tokyo, city: "Tokyo", country: "JP", zone: "Asia/Tokyo"),
            ip: ip(newYork, city: "New York", country: "US"),
            deviceTimeZone: TimeZone(identifier: "America/New_York")!,
            deviceIsStationary: true,
            simulatedSpeed: 20,
            isSimulating: true,
            now: now
        )
        let reading = Exposure.grade(env)
        #expect(reading.leaks.first?.severity == .bad)
        #expect(reading.leaks.last?.kind == .softwareFlag)
        #expect(reading.score == 0)
    }

    // MARK: - The drive is graded, not the second

    /// The reported speed goes to exactly zero at every light and every stop
    /// sign. Grading that instant answered "nothing is moving, nothing is
    /// wrong" about a drive the phone never took, and the score swung by the
    /// full cost of the motion leak every time the car slowed down.
    @Test func brakingForALightDoesNotClearTheMotionLeak() {
        func drive(speed: Double, peak: Double) -> Exposure {
            Exposure.grade(Exposure.Environment(
                pin: pin(newYork, city: "New York", country: "US", zone: "America/New_York"),
                ip: ip(newark, city: "Newark", country: "US"),
                deviceTimeZone: TimeZone(identifier: "America/New_York")!,
                deviceIsStationary: true,
                simulatedSpeed: speed,
                recentTopSpeed: peak,
                isSimulating: true,
                now: now
            ))
        }
        let moving = drive(speed: 18, peak: 18)
        let stoppedAtALight = drive(speed: 0, peak: 18)
        #expect(stoppedAtALight.leaks.contains { $0.kind == .motion })
        #expect(stoppedAtALight.score == moving.score)
        #expect(stoppedAtALight.grade == moving.grade)
    }

    /// And once the run has genuinely stopped moving for long enough that the
    /// window has emptied, the accusation goes away again.
    @Test func aRunThatHasNotMovedInAWhileIsNotAccused() {
        let env = Exposure.Environment(
            pin: pin(newYork, city: "New York", country: "US", zone: "America/New_York"),
            ip: ip(newark, city: "Newark", country: "US"),
            deviceTimeZone: TimeZone(identifier: "America/New_York")!,
            deviceIsStationary: true,
            simulatedSpeed: 0,
            recentTopSpeed: 0,
            isSimulating: true,
            now: now
        )
        #expect(Exposure.grade(env).leaks.first { $0.kind == .motion } == nil)
        #expect(Exposure.grade(env).score == 100)
    }

    @Test func recentMovementCountsForNothingWhenNothingIsRunning() {
        let env = Exposure.Environment(
            pin: pin(newYork, city: "New York", country: "US", zone: "America/New_York"),
            ip: ip(newark, city: "Newark", country: "US"),
            deviceTimeZone: TimeZone(identifier: "America/New_York")!,
            deviceIsStationary: true,
            simulatedSpeed: 0,
            recentTopSpeed: 30,
            isSimulating: false,
            now: now
        )
        #expect(Exposure.grade(env).leaks.first { $0.kind == .motion } == nil)
    }

    // MARK: - A serious leak reads as serious

    /// One bad leak used to leave a score of 78, which every part of the app
    /// draws in amber and calls mostly covered.
    @Test func oneSeriousLeakHoldsTheScoreDown() {
        let env = Exposure.Environment(
            pin: pin(newYork, city: "New York", country: "US", zone: "America/New_York"),
            ip: ip(newark, city: "Newark", country: "US"),
            deviceTimeZone: TimeZone(identifier: "Asia/Tokyo")!,
            now: now
        )
        let reading = Exposure.grade(env)
        #expect(reading.serious.count == 1)
        // The score stays the arithmetic the leak costs are printed as, so a
        // reader adding up the minus signs on screen gets this number. The cap
        // is on the judgement, not on the count.
        let printed = reading.problems.reduce(0) { $0 + $1.cost }
        #expect(reading.score == 100 - printed)
        #expect(reading.standing <= Exposure.seriousCeiling)
        #expect(reading.isSeriouslyExposed)
        #expect(reading.grade != "Mostly covered")
        #expect(reading.grade != "Covered")
    }

    @Test func aWeakLeakIsStillJustArithmetic() {
        let env = Exposure.Environment(
            pin: pin(newYork, city: "New York", country: "US", zone: "America/New_York"),
            ip: ip(philadelphia, city: "Philadelphia", country: "US"),
            deviceTimeZone: TimeZone(identifier: "America/New_York")!,
            now: now
        )
        let reading = Exposure.grade(env)
        #expect(reading.serious.isEmpty)
        #expect(reading.score == 88)
        #expect(reading.alarm == nil)
    }

    /// The permanent note about the simulation flag is not a problem to solve
    /// and must never drag the grade down with it.
    @Test func thePermanentNoteIsNotASeriousLeak() {
        let env = Exposure.Environment(
            pin: pin(newYork, city: "New York", country: "US", zone: "America/New_York"),
            ip: ip(newark, city: "Newark", country: "US"),
            deviceTimeZone: TimeZone(identifier: "America/New_York")!,
            now: now
        )
        let reading = Exposure.grade(env)
        #expect(reading.score == 100)
        #expect(reading.serious.isEmpty)
        #expect(reading.alarm == nil)
        #expect(reading.worst == nil)
    }

    @Test func theAlarmNamesTheWorstThingAndCountsTheRest() {
        let env = Exposure.Environment(
            pin: pin(tokyo, city: "Tokyo", country: "JP", zone: "Asia/Tokyo"),
            ip: ip(newYork, city: "New York", country: "US"),
            deviceTimeZone: TimeZone(identifier: "America/New_York")!,
            deviceIsStationary: true,
            simulatedSpeed: 20,
            isSimulating: true,
            now: now
        )
        let reading = Exposure.grade(env)
        #expect(reading.serious.count == 4)
        #expect(reading.worst?.kind == .ip)
        #expect(reading.alarm?.contains("3 more") == true)
    }

    @Test func egressAdviceNamesTheCity() {
        let place = pin(newYork, city: "New York", country: "US", zone: "America/New_York")
        #expect(place.egressAdvice.contains("New York"))
        #expect(place.egressAdvice.hasPrefix("Set your VPN to"))
    }
}
