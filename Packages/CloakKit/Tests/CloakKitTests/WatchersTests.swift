import Testing
import Foundation
@testable import CloakKit

@Suite("Watchers")
struct WatchersTests {
    let newYork = Coordinate(latitude: 40.7128, longitude: -74.0060)
    let losAngeles = Coordinate(latitude: 34.0522, longitude: -118.2437)
    let now = Date(timeIntervalSince1970: 1_758_000_000)

    func watcher(_ id: String) -> Watcher { Watcher.known.first { $0.id == id }! }

    var farIP: Exposure {
        Exposure.grade(Exposure.Environment(
            pin: Exposure.PinPlace(coordinate: newYork, city: "New York", countryCode: "US", timeZone: TimeZone(identifier: "America/New_York")),
            ip: Exposure.IPPlace(address: "203.0.113.7", coordinate: losAngeles, city: "Los Angeles", countryCode: "US", checkedAt: now),
            deviceTimeZone: TimeZone(identifier: "America/New_York")!,
            deviceIsStationary: true,
            simulatedSpeed: 0,
            isSimulating: true,
            now: now
        ))
    }

    var clean: Exposure {
        Exposure.grade(Exposure.Environment(
            pin: Exposure.PinPlace(coordinate: newYork, city: "New York", countryCode: "US", timeZone: TimeZone(identifier: "America/New_York")),
            ip: Exposure.IPPlace(address: "203.0.113.7", coordinate: newYork, city: "New York", countryCode: "US", checkedAt: now),
            deviceTimeZone: TimeZone(identifier: "America/New_York")!,
            deviceIsStationary: true,
            simulatedSpeed: 0,
            isSimulating: true,
            now: now
        ))
    }

    @Test func datingAppIsExposedByFarIP() {
        let verdicts = Watcher.judge(installed: [watcher("tinder")], against: farIP)
        #expect(verdicts.first?.standing == .exposed)
        #expect(verdicts.first?.open.first?.kind == .ip)
    }

    @Test func datingAppIsCoveredWhenIPMatches() {
        let verdicts = Watcher.judge(installed: [watcher("tinder")], against: clean)
        #expect(verdicts.first?.standing == .covered)
    }

    @Test func softwareFlagReadersAlwaysKnow() {
        let verdicts = Watcher.judge(installed: [watcher("pokemongo")], against: clean)
        #expect(verdicts.first?.standing == .alwaysKnows)
    }

    @Test func life360IsCoveredWhenParked() {
        let verdicts = Watcher.judge(installed: [watcher("life360")], against: clean)
        #expect(verdicts.first?.standing == .covered)
    }

    @Test func life360IsExposedByAStillPhoneOnADrive() {
        let driving = Exposure.grade(Exposure.Environment(
            pin: Exposure.PinPlace(coordinate: newYork, city: "New York", countryCode: "US", timeZone: TimeZone(identifier: "America/New_York")),
            ip: Exposure.IPPlace(address: "203.0.113.7", coordinate: newYork, city: "New York", countryCode: "US", checkedAt: now),
            deviceTimeZone: TimeZone(identifier: "America/New_York")!,
            deviceIsStationary: true,
            simulatedSpeed: 18,
            isSimulating: true,
            now: now
        ))
        let verdicts = Watcher.judge(installed: [watcher("life360")], against: driving)
        #expect(verdicts.first?.standing == .exposed)
        #expect(verdicts.first?.open.first?.kind == .motion)
    }

    @Test func worstStandingSortsFirst() {
        let verdicts = Watcher.judge(installed: [watcher("netflix"), watcher("pokemongo"), watcher("tinder")], against: farIP)
        #expect(verdicts.map(\.standing) == [.alwaysKnows, .exposed, .covered])
    }

    @Test func nothingInstalledIsNothingToJudge() {
        #expect(Watcher.judge(installed: [], against: farIP).isEmpty)
    }

    @Test func everyKnownWatcherHasAScheme() {
        for w in Watcher.known {
            #expect(w.scheme.hasSuffix("://"))
            #expect(!w.note.isEmpty)
        }
    }
}
