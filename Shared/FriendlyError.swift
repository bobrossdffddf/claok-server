import Foundation

/// Turns the bridge's raw failures into something a person can act on.
///
/// The underlying text is genuinely useful when something novel goes wrong, so
/// it is kept and shown behind a disclosure rather than thrown away.
public struct FriendlyError: Sendable, Equatable {
    public var headline: String
    public var advice: String
    public var technical: String

    public init(headline: String, advice: String, technical: String) {
        self.headline = headline
        self.advice = advice
        self.technical = technical
    }

    public static func make(_ raw: String) -> FriendlyError {
        let text = raw.lowercased()

        // Order matters: the most specific cause first.
        if text.contains("no local network") || text.contains("haslocalnetwork") {
            return FriendlyError(
                headline: "Turn on Wi-Fi",
                advice: "iOS only offers the service Cloak needs while the phone has a Wi-Fi connection. It does not have to join a network. Personal Hotspot works too.",
                technical: raw
            )
        }

        if text.contains("connection refused") {
            return FriendlyError(
                headline: "Nothing was listening",
                advice: "iOS is not offering its pairing service on this network yet. Turn Wi-Fi on, wait a moment, and try again.",
                technical: raw
            )
        }

        if text.contains("connectionreset") || text.contains("reset by peer") {
            return FriendlyError(
                headline: "Your phone hung up",
                advice: "iOS answered and then refused. This normally clears after pairing again from scratch.",
                technical: raw
            )
        }

        if text.contains("timed out") || text.contains("timeout") {
            return FriendlyError(
                headline: "No answer",
                advice: "Your phone did not reply in time. Check Wi-Fi is on, then try again.",
                technical: raw
            )
        }

        if text.contains("not advertising") || text.contains("no remembered port") {
            return FriendlyError(
                headline: "Cannot find your phone",
                advice: "Allow Cloak local network access in Settings, make sure Wi-Fi is on, and try again.",
                technical: raw
            )
        }

        if text.contains("loopback tunnel is not running") || text.contains("vpn") {
            return FriendlyError(
                headline: "The tunnel is not running",
                advice: "Cloak needs its local tunnel to reach iOS. Approve the VPN prompt for Cloak and try again.",
                technical: raw
            )
        }

        if text.contains("developer image") || text.contains("dtservicehub") || text.contains("not mounted") {
            return FriendlyError(
                headline: "The developer image is not mounted",
                advice: "iOS hides the location service until this is loaded. Cloak will try to mount it for you, which takes a minute or two.",
                technical: raw
            )
        }

        if text.contains("handshake") || text.contains("pair verify") || text.contains("pair setup") {
            return FriendlyError(
                headline: "Pairing did not complete",
                advice: "Pair again from scratch, and make sure Cloak stays open while you are in Settings.",
                technical: raw
            )
        }

        if text.contains("developer mode") {
            return FriendlyError(
                headline: "Developer Mode is off",
                advice: "Turn it on in Settings, Privacy & Security, then restart your phone.",
                technical: raw
            )
        }

        return FriendlyError(
            headline: "That did not work",
            advice: "Try again. If it keeps happening, pair from scratch.",
            technical: raw
        )
    }
}
