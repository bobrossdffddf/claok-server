import Testing
import Foundation
@testable import CloakKit

/// What every version of iOS will do, answered without a phone.
///
/// The version behaviour used to be a `#available` check, which the compiler
/// resolves against whatever machine is running it, so there was no way to ask
/// what iOS 18 would do short of finding a phone on iOS 18. Taking the version
/// as a number means every version can be asked here.
@Suite("iOS version coverage")
struct PairingPlanTests {
    /// Every version from the oldest supported to well past the newest.
    static let versions = Array(PairingPlan.minimumSupportedMajor...32)

    @Test func everySupportedVersionHasSomethingToTry() {
        for major in Self.versions {
            let routes = PairingPlan.routes(iOSMajor: major, hasStoredRecord: false)
            #expect(!routes.isEmpty, "iOS \(major) has no route at all")
        }
    }

    /// The one that matters. A record handed over by the installer works
    /// everywhere, because nothing about it depends on what iOS will agree to
    /// do. This is what makes versions below 27 work.
    @Test func aRecordFromTheInstallerIsEnoughOnEveryVersion() {
        for major in Self.versions {
            let routes = PairingPlan.routes(iOSMajor: major, hasStoredRecord: true)
            #expect(routes == [.stored], "iOS \(major) did not take the record")
        }
    }

    /// Below 27 lockdown is tried first, because it asks least of the phone:
    /// a fixed port, no discovery, no Wi-Fi. From 27 the phone refuses its own
    /// lockdown port even through the reflector (measured on a real device),
    /// so it is not tried at all there and the outward route goes first.
    @Test func firstRouteMatchesWhatThePhoneWillAnswer() {
        for major in Self.versions {
            let routes = PairingPlan.routes(iOSMajor: major, hasStoredRecord: false)
            if major >= PairingPlan.pairableHostMajor {
                #expect(routes.first == .pairableHost, "iOS \(major) did not try outward pairing first")
                #expect(!routes.contains(.lockdown), "iOS \(major) still tries the refused lockdown port")
            } else {
                #expect(routes.first == .lockdown, "iOS \(major) did not try lockdown first")
            }
        }
    }

    /// The outward-pairing flow only exists from 27: below that there is no
    /// Devices list for the phone to pair from, so offering it is offering
    /// something that cannot happen.
    @Test func pairableHostOnlyExistsFromTwentySeven() {
        for major in Self.versions {
            let routes = PairingPlan.routes(iOSMajor: major, hasStoredRecord: false)
            let offered = routes.contains(.pairableHost)
            #expect(
                offered == (major >= PairingPlan.pairableHostMajor),
                "iOS \(major) got pairableHost = \(offered)"
            )
        }
    }

    /// Whatever else happens, there is always a last resort: discovery
    /// everywhere, and on 26 the outward route sits behind it.
    @Test func thereIsAlwaysAFallback() {
        for major in Self.versions {
            let routes = PairingPlan.routes(iOSMajor: major, hasStoredRecord: false)
            #expect(routes.contains(.discovery), "iOS \(major) has no fallback")
            #expect(routes.count >= 2, "iOS \(major) has only one route")
        }
    }

    @Test func versionsBelowSeventeenAreHonestlyUnsupported() {
        for major in 9...16 {
            #expect(!PairingPlan.isSupported(iOSMajor: major))
            #expect(PairingPlan.explain(iOSMajor: major, hasStoredRecord: true).contains("not supported"))
        }
        for major in Self.versions {
            #expect(PairingPlan.isSupported(iOSMajor: major))
        }
    }

    /// Prints the matrix. Not an assertion, a thing to read.
    @Test func printTheMatrix() {
        var lines: [String] = ["", "iOS support matrix", String(repeating: "-", count: 60)]
        for major in Self.versions {
            lines.append("  " + PairingPlan.explain(iOSMajor: major, hasStoredRecord: true))
            lines.append("  " + PairingPlan.explain(iOSMajor: major, hasStoredRecord: false))
        }
        lines.append(String(repeating: "-", count: 60))
        print(lines.joined(separator: "\n"))
        #expect(true)
    }
}
