import Foundation

/// When this copy of Cloak stops being allowed to run.
///
/// A free Apple ID signs an app for seven days. The exact moment it expires is
/// written into the provisioning profile Apple issued, as ExpirationDate, so
/// reading it there is the honest answer rather than counting seven days from
/// an install date nobody recorded.
public struct SignatureInfo: Sendable, Equatable {
    public var expires: Date
    public var signedTo: String?

    public init(expires: Date, signedTo: String?) {
        self.expires = expires
        self.signedTo = signedTo
    }

    public var secondsLeft: TimeInterval { expires.timeIntervalSinceNow }

    public var daysLeft: Int { max(0, Int(ceil(secondsLeft / 86_400))) }

    public var hasExpired: Bool { secondsLeft <= 0 }

    /// The seven day window as a fraction still remaining, for the ring.
    public var fractionLeft: Double {
        min(1, max(0, secondsLeft / (7 * 86_400)))
    }

    public var isUrgent: Bool { secondsLeft < 2 * 86_400 }

    /// Read once. The profile is inside the bundle, so it cannot change while
    /// the app is running, and this was being called several times a second
    /// from view bodies during a drive, each call opening the file and running
    /// a plist parse over it.
    nonisolated(unsafe) private static var cached: SignatureInfo??

    public static func fromBundle() -> SignatureInfo? {
        if let cached { return cached }
        let value = readBundle()
        cached = value
        return value
    }

    private static func readBundle() -> SignatureInfo? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return parse(data)
    }

    /// Lifts the plain XML plist out of the CMS envelope, the same trick the
    /// app group reader uses, and reads the two dates.
    public static func parse(_ data: Data) -> SignatureInfo? {
        guard let open = data.range(of: Data("<plist".utf8)),
              let close = data.range(of: Data("</plist>".utf8), in: open.lowerBound..<data.endIndex) else {
            return nil
        }
        let xml = data[open.lowerBound..<close.upperBound]
        guard let profile = try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil) as? [String: Any],
              let expires = profile["ExpirationDate"] as? Date else {
            return nil
        }
        let name = profile["Name"] as? String
        return SignatureInfo(expires: expires, signedTo: name)
    }
}
