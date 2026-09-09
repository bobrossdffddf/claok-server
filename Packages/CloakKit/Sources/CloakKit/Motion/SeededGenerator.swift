import Foundation

public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    public mutating func double(in range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) * (1.0 / 9007199254740992.0)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }

    public mutating func chance(_ probability: Double) -> Bool {
        double(in: 0...1) < probability
    }

    public mutating func gaussian(mean: Double, deviation: Double) -> Double {
        let u1 = max(double(in: 0...1), 1e-12)
        let u2 = double(in: 0...1)
        return mean + deviation * sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}
