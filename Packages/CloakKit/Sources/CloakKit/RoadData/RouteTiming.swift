import Foundation
import os

/// Where the time in a route build actually goes.
///
/// Every number in the speed work came from here rather than from a guess:
/// the Apple Maps call, each Overpass request with the mirror that answered
/// and the bytes it sent, the parse, the merge and the speed profile. Plain
/// notices, so they show up in Console against a phone with nothing attached,
/// which is where the slow routes were.
public enum RouteTiming {
    public static let log = Logger(subsystem: "app.cloak.ios", category: "route-timing")

    public static func now() -> ContinuousClock.Instant { ContinuousClock.now }

    /// Milliseconds since a start mark.
    public static func since(_ start: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - start) / .milliseconds(1))
    }

    /// Says how long a step took and what it was.
    public static func done(_ name: StaticString, _ start: ContinuousClock.Instant, _ detail: String = "") {
        log.notice("\(name, privacy: .public) \(since(start))ms \(detail, privacy: .public)")
    }
}
