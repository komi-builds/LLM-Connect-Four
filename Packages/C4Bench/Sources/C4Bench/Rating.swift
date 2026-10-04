import C4AI
import C4Core
import Foundation

/// One game's result between two contestant ids. `scoreA` is 1, 0.5 or 0.
public struct PairResult: Sendable, Hashable, Codable {
  public var a: String
  public var b: String
  public var scoreA: Double

  public init(a: String, b: String, scoreA: Double) {
    self.a = a
    self.b = b
    self.scoreA = scoreA
  }
}

/// Bradley-Terry maximum-likelihood ratings over all games (§5.3), fitted with the MM
/// algorithm. Draws count as half a win. A weak prior (`priorDraws` virtual draws for each
/// contestant against the reference) keeps players who won or lost every game finite.
/// Reported on an Elo-like scale (400 · log10) with the reference fixed at 1000.
public enum BradleyTerry {
  /// Fits ratings on the Elo scale (`1000 + 400 * log10(gamma / gamma_ref)`).
  ///
  /// The reference is always part of the fit, even if it never appears in `results`, and
  /// every other contestant gets `priorDraws` virtual draws against it. That connects the
  /// comparison graph, so the fit is always well defined while `priorDraws > 0`. With
  /// `priorDraws == 0`, contestants in a component that never meets the reference have no
  /// defined rating relative to it (they come out at whatever the iteration reaches), and
  /// players who won or lost every game diverge towards infinity (the iteration is capped).
  /// The result does not depend on the order of `results`.
  public static func fit(
    _ results: [PairResult], reference: String = Contestant.reference.id, priorDraws: Double = 1,
    iterations: Int = 10_000, tolerance: Double = 1e-10
  ) -> [String: Double] {
    let problem = BTProblem(results, reference: reference)
    var n = [Double](repeating: 0, count: problem.k * problem.k)
    var w = [Double](repeating: 0, count: problem.k)
    problem.accumulate(indices: nil, into: &n, &w)
    problem.addPrior(priorDraws, to: &n, &w)
    let gammas = BTProblem.solve(
      k: problem.k, reference: problem.reference, n: n, w: w, start: nil, iterations: iterations,
      tolerance: tolerance)
    return problem.ratings(from: gammas)
  }

  /// 95% confidence interval per contestant from `resamples` bootstrap resamples of the
  /// games (seeded, so reproducible). The interval is the 2.5th to 97.5th percentile of
  /// the refitted ratings, widened if needed to include the point estimate (the prior can
  /// pull resampled fits slightly to one side). The reference gets a zero-width interval.
  public static func bootstrap(
    _ results: [PairResult], reference: String = Contestant.reference.id, priorDraws: Double = 1,
    resamples: Int = 1000, seed: UInt64 = 0
  ) -> [String: ClosedRange<Double>] {
    let problem = BTProblem(results, reference: reference)
    let k = problem.k
    var n0 = [Double](repeating: 0, count: k * k)
    var w0 = [Double](repeating: 0, count: k)
    problem.accumulate(indices: nil, into: &n0, &w0)
    problem.addPrior(priorDraws, to: &n0, &w0)
    let pointGammas = BTProblem.solve(
      k: k, reference: problem.reference, n: n0, w: w0, start: nil, iterations: 10_000,
      tolerance: 1e-10)
    let point = problem.ratings(from: pointGammas)
    let count = problem.gameCount
    guard count > 0, resamples > 0 else {
      return point.mapValues { $0...$0 }
    }
    var rng = SplitMix64(seed: seed)
    var samples = [[Double]](repeating: [], count: k)
    for index in 0..<k { samples[index].reserveCapacity(resamples) }
    var indices = [Int](repeating: 0, count: count)
    var n = n0
    var w = w0
    for _ in 0..<resamples {
      for i in 0..<count { indices[i] = Int(rng.next() % UInt64(count)) }
      for i in 0..<n.count { n[i] = 0 }
      for i in 0..<k { w[i] = 0 }
      problem.accumulate(indices: indices, into: &n, &w)
      problem.addPrior(priorDraws, to: &n, &w)
      let gammas = BTProblem.solve(
        k: k, reference: problem.reference, n: n, w: w, start: pointGammas, iterations: 2_000,
        tolerance: 1e-8)
      for i in 0..<k {
        samples[i].append(400 * log10(gammas[i] / gammas[problem.reference]) + 1000)
      }
    }
    var out: [String: ClosedRange<Double>] = [:]
    for (i, id) in problem.ids.enumerated() {
      let sorted = samples[i].sorted()
      let p = point[id] ?? 1000
      let low = min(percentile(sorted, 0.025), p)
      let high = max(percentile(sorted, 0.975), p)
      out[id] = low...high
    }
    return out
  }

  /// Linear-interpolated percentile of an ascending array.
  static func percentile(_ sorted: [Double], _ q: Double) -> Double {
    guard !sorted.isEmpty else { return 1000 }
    let position = q * Double(sorted.count - 1)
    let lower = Int(position.rounded(.down))
    let upper = min(lower + 1, sorted.count - 1)
    let fraction = position - Double(lower)
    return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
  }
}

/// One leaderboard row (§5.4). Optional columns are nil when not measured (anchors have no
/// tok/s, puzzles may not have been run, …).
public struct RatingRow: Sendable, Hashable, Codable, Identifiable {
  public var contestant: Contestant
  public var rank: Int
  public var rating: Double
  public var ciLow: Double
  public var ciHigh: Double
  /// True if this row's interval overlaps the row above it.
  public var tiedWithPrevious: Bool
  public var games: Int
  public var wins: Int
  public var draws: Int
  public var losses: Int
  /// Accuracy per puzzle category (keyed by `PuzzleCategory.rawValue`), 0...1.
  public var puzzleAccuracy: [String: Double]
  public var puzzleOverall: Double?
  public var winRateVsD4: Double?
  public var blundersPerGame: Double?
  public var wouldBeIllegalRate: Double?
  public var medianMoveMs: Double?
  public var tokensPerSecond: Double?
  public var loadTimeMs: Double?
  public var peakRAMGB: Double?
  public var sizeGB: Double?

  public var id: String { contestant.id }

  public init(
    contestant: Contestant, rank: Int, rating: Double, ciLow: Double, ciHigh: Double,
    tiedWithPrevious: Bool = false, games: Int, wins: Int, draws: Int, losses: Int,
    puzzleAccuracy: [String: Double] = [:], puzzleOverall: Double? = nil,
    winRateVsD4: Double? = nil,
    blundersPerGame: Double? = nil, wouldBeIllegalRate: Double? = nil, medianMoveMs: Double? = nil,
    tokensPerSecond: Double? = nil, loadTimeMs: Double? = nil, peakRAMGB: Double? = nil,
    sizeGB: Double? = nil
  ) {
    self.contestant = contestant
    self.rank = rank
    self.rating = rating
    self.ciLow = ciLow
    self.ciHigh = ciHigh
    self.tiedWithPrevious = tiedWithPrevious
    self.games = games
    self.wins = wins
    self.draws = draws
    self.losses = losses
    self.puzzleAccuracy = puzzleAccuracy
    self.puzzleOverall = puzzleOverall
    self.winRateVsD4 = winRateVsD4
    self.blundersPerGame = blundersPerGame
    self.wouldBeIllegalRate = wouldBeIllegalRate
    self.medianMoveMs = medianMoveMs
    self.tokensPerSecond = tokensPerSecond
    self.loadTimeMs = loadTimeMs
    self.peakRAMGB = peakRAMGB
    self.sizeGB = sizeGB
  }
}

public enum ReportFormat: String, Sendable, Hashable, Codable, CaseIterable {
  case md, csv, json
}
