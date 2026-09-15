import Foundation

/// Every number a person reads is in miles, feet and miles per hour. The
/// engine works in metres and metres per second, and this is the one place
/// the two meet, so nothing else has a conversion factor typed into it.
public enum Units {
    public static let metresPerMile = 1609.344
    public static let feetPerMetre = 3.28084
    public static let mphPerMetrePerSecond = 2.236936

    public static func mph(_ metresPerSecond: Double) -> Double {
        metresPerSecond * mphPerMetrePerSecond
    }

    public static func metresPerSecond(mph: Double) -> Double {
        mph / mphPerMetrePerSecond
    }

    /// "350 ft" under a fifth of a mile, "0.4 mi" above it, "12 mi" once
    /// the tenths stop meaning anything.
    public static func distance(_ metres: Double) -> String {
        let miles = metres / metresPerMile
        if metres < 300 { return "\(Int((metres * feetPerMetre).rounded())) ft" }
        if miles < 10 { return String(format: "%.1f mi", miles) }
        return String(format: "%.0f mi", miles)
    }

    /// Small distances, for drift and accuracy: always feet.
    public static func feet(_ metres: Double) -> String {
        "\(Int((metres * feetPerMetre).rounded())) ft"
    }

    public static func speed(_ metresPerSecond: Double) -> String {
        String(format: "%.0f mph", mph(metresPerSecond))
    }
}
