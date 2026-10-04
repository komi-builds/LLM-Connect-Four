import C4Core
import Foundation

/// Stable 64-bit string hashing (FNV-1a finished with SplitMix64), so keys and seeds never
/// depend on Swift's per-process randomised `hashValue`.
enum StableHash {
  static func hash(_ text: String) -> UInt64 {
    var h: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in text.utf8 {
      h ^= UInt64(byte)
      h = h &* 0x0000_0100_0000_01B3
    }
    var rng = SplitMix64(seed: h)
    return rng.next()
  }

  static func hex(_ value: UInt64) -> String {
    let digits = String(value, radix: 16)
    return String(repeating: "0", count: 16 - digits.count) + digits
  }
}

/// Varied two-move openings (§5.2). Every game starts from one, and each opening is played
/// with both colours, so greedy runs are not repeats of the same game.
public enum Openings {
  /// All 49 two-move openings `[first disc's column, second disc's column]`, in a fixed
  /// shuffled order so that a short suite (for example 7 openings in Quick) still covers
  /// varied positions rather than only the leftmost columns.
  public static let all: [[Column]] = {
    var list: [[Column]] = []
    for a in Board.allColumns { for b in Board.allColumns { list.append([a, b]) } }
    var rng = SplitMix64(seed: 0xC4C4_0BE7_0000_0001)
    for i in stride(from: list.count - 1, to: 0, by: -1) {
      let j = Int(rng.next() % UInt64(i + 1))
      list.swapAt(i, j)
    }
    return list
  }()

  /// The opening for game `index` of a pairing. Games `2k` and `2k+1` use the same opening
  /// with the colours swapped: the pairing's first-listed contestant plays `Disc.first` in
  /// even games and `Disc.second` in odd ones.
  public static func opening(forGame index: Int) -> (moves: [Column], listedFirstPlaysFirst: Bool) {
    (all[(index / 2) % all.count], index.isMultiple(of: 2))
  }
}

/// Deterministic game seeds: `hash(opening, colour, preset, contestant ids, game index)`.
public enum BenchSeeds {
  public static func gameSeed(
    preset: SuitePreset, first: Contestant, second: Contestant, opening: [Column], gameIndex: Int
  ) -> UInt64 {
    // The colours are implied by the order of `first` and `second`, and are spelled out so
    // that the key reads clearly in a debugger.
    let key = [
      preset.rawValue, "first=" + first.id, "second=" + second.id,
      "opening=" + opening.map(String.init).joined(separator: ","), "index=\(gameIndex)",
    ].joined(separator: ";")
    return StableHash.hash(key)
  }

  /// The seed for one contestant's attempt at one puzzle.
  public static func puzzleSeed(puzzleID: String, contestant: Contestant) -> UInt64 {
    StableHash.hash("puzzle;\(puzzleID);\(contestant.id)")
  }
}
