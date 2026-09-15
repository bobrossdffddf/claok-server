import Foundation

/// Which way Cloak gets a pairing record, for a given iOS version.
///
/// This used to be a `#available` check buried in the middle of the pairing
/// code. That works, but it cannot be tested: the compiler resolves it against
/// whatever the machine is running, so there is no way to ask what a phone on
/// iOS 18 would do without holding one. Every version-dependent decision in the
/// app is now this one function, taking the version as a number, so all of them
/// can be answered on a computer with no phone attached.
public enum PairingRoute: String, Sendable, Equatable, CaseIterable {
    /// A record handed over by the computer that installed Cloak, carried
    /// inside the app itself. Needs no cooperation from iOS at all, so it works
    /// on every version and is why the desktop installer exists.
    case stored

    /// Ask this phone's own lockdown service, on its fixed port, through the
    /// reflector. No discovery and no Bonjour.
    case lockdown

    /// iOS 27 and later only: the phone pairs outward to something advertising
    /// itself as a computer. Does not exist before 27.
    case pairableHost

    /// The original route, through the pairing service iOS advertises. Depends
    /// on Wi-Fi, Local Network permission and multicast all working.
    case discovery

    public var name: String {
        switch self {
        case .stored: "Record from the installer"
        case .lockdown: "Direct, over lockdown"
        case .pairableHost: "Phone pairs outward"
        case .discovery: "Found on the network"
        }
    }
}

public enum PairingPlan {
    /// The oldest iOS Cloak runs on.
    ///
    /// Not a preference. The app is built on `@Observable`, which does not
    /// exist before iOS 17, and iOS will not install a build whose deployment
    /// target is above the system version. Going lower is a rewrite of every
    /// model in the app rather than a setting.
    public static let minimumSupportedMajor = 17

    /// Where the pairable-host flow is the first and only sensible route.
    public static let pairableHostMajor = 27

    /// From here the lockdown record is refused over the network (26.4 on),
    /// so a remote pairing record is preferred when one exists.
    public static let outwardPairingMajor = 26

    /// Everything worth trying, in order, on this version of iOS.
    ///
    /// A stored record ends it: there is nothing to negotiate, so nothing else
    /// is attempted. Otherwise lockdown goes first because it asks least of the
    /// phone, then whatever else that version can do.
    public static func routes(iOSMajor: Int, hasStoredRecord: Bool) -> [PairingRoute] {
        if hasStoredRecord {
            return [.stored]
        }

        // On iOS 27 the phone answers a connection to its own lockdown port
        // with a plain refusal even through the reflector (measured on a real
        // device: 10.7.0.1:62078 -> ECONNREFUSED on every handshake variant), so
        // asking it first only costs time and a confusing first error. The
        // outward pairing route is the one that works there.
        if iOSMajor >= pairableHostMajor {
            return [.pairableHost, .discovery]
        }
        // iOS 26 is split: early builds answer lockdown, later ones (26.4 on,
        // and measured on a friend's phone: "tls handshake eof" then
        // "connection reset" on 10.7.0.1) refuse it the way 27 does. So
        // lockdown is still tried first, and the outward pairing route comes
        // next instead of the old discovery route, which needs the very
        // thing that is refusing.
        // Below 27 the outward route cannot complete: the "Devices" list in
        // Developer Mode that the phone would pair from does not exist
        // (confirmed on 26.6.2, the screen is just the switch). SideStore's
        // fix for 26.4+ is inbound remote pairing, which is the discovery
        // route here, so that is what 26 gets after lockdown.
        return [.lockdown, .discovery]
    }

    /// Whether Cloak can run at all on this version.
    public static func isSupported(iOSMajor: Int) -> Bool {
        iOSMajor >= minimumSupportedMajor
    }

    /// What the phone this is running on reports.
    public static var currentMajor: Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    /// A one line account of what this version will do, for the diagnostics
    /// screen and for the report the test harness prints.
    public static func explain(iOSMajor: Int, hasStoredRecord: Bool) -> String {
        guard isSupported(iOSMajor: iOSMajor) else {
            return "iOS \(iOSMajor): not supported, Cloak needs \(minimumSupportedMajor) or later"
        }
        let names = routes(iOSMajor: iOSMajor, hasStoredRecord: hasStoredRecord)
            .map(\.name)
            .joined(separator: ", then ")
        return "iOS \(iOSMajor)\(hasStoredRecord ? " with a record" : " with no record"): \(names)"
    }
}
