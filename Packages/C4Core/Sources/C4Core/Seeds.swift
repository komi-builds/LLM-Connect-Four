/// Deterministic seeding, so any game (including any benchmark game) can be replayed.
public enum Seeds {
    /// The RNG seed for one move: `hash(gameSeed, ply)`.
    public static func move(gameSeed: UInt64, ply: Int) -> UInt64 {
        var rng = SplitMix64(seed: gameSeed ^ (UInt64(truncatingIfNeeded: ply) &* 0x9E37_79B9_7F4A_7C15))
        return rng.next()
    }
}

/// A small, fast, seedable generator (SplitMix64). Stable across platforms and releases,
/// unlike `SystemRandomNumberGenerator`.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A uniform double in [0, 1).
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }
}
