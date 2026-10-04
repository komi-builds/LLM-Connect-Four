import C4AI
import C4Core
import Foundation
import Testing

@testable import C4Bench

/// Games between `a` and `b`: `wins` for a, `draws`, `losses` for a.
func games(_ a: String, _ b: String, wins: Int, draws: Int = 0, losses: Int) -> [PairResult] {
  Array(repeating: PairResult(a: a, b: b, scoreA: 1), count: wins)
    + Array(repeating: PairResult(a: a, b: b, scoreA: 0.5), count: draws)
    + Array(repeating: PairResult(a: a, b: b, scoreA: 0), count: losses)
}

/// Independent reference: gradient ascent on the log-likelihood in log-strength space,
/// with the prior added as explicit virtual draws against the reference.
func gradientFit(_ results: [PairResult], reference: String, priorDraws: Double) -> [String: Double]
{
  let ids = Set(results.flatMap { [$0.a, $0.b] }).union([reference]).sorted()
  var weights: [(String, String, Double, Double)] = results.map { ($0.a, $0.b, $0.scoreA, 1) }
  for id in ids where id != reference {
    weights.append((id, reference, 0.5 * priorDraws, priorDraws))
  }
  var theta = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0.0) })
  for _ in 0..<100_000 {
    var gradient = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0.0) })
    for (a, b, score, n) in weights {
      let p = 1 / (1 + exp(theta[b]! - theta[a]!))
      gradient[a]! += score - n * p
      gradient[b]! -= score - n * p
    }
    for id in ids where id != reference { theta[id]! += 0.05 * gradient[id]! }
  }
  // theta is ln(gamma); Elo = 400 * log10(gamma ratio)
  return theta.mapValues { 1000 + 400 * ($0 - theta[reference]!) / log(10) }
}

@Suite struct BradleyTerryTests {
  @Test func twoPlayersThreeToOne() {
    let ratings = BradleyTerry.fit(
      games("A", "B", wins: 3, losses: 1), reference: "B", priorDraws: 0)
    #expect(ratings["B"] == 1000)
    #expect(abs(ratings["A"]! - (1000 + 400 * log10(3.0))) < 1e-6)
    #expect(abs(ratings["A"]! - 1190.8485) < 1e-3)
  }

  @Test func drawsAreHalfAWin() {
    let ratings = BradleyTerry.fit(
      games("A", "B", wins: 1, draws: 2, losses: 1), reference: "B", priorDraws: 0)
    #expect(abs(ratings["A"]! - 1000) < 1e-6)
    // All draws: equal, with the prior too.
    let allDraws = BradleyTerry.fit(games("A", "B", wins: 0, draws: 10, losses: 0), reference: "B")
    #expect(abs(allDraws["A"]! - 1000) < 1e-6)
  }

  @Test func twoPlayersWithPriorByHand() {
    // A beats B 3-1, one virtual draw: W_A = 3.5, W_B = 1.5, n = 5, so gamma ratio 3.5/1.5.
    let ratings = BradleyTerry.fit(
      games("A", "B", wins: 3, losses: 1), reference: "B", priorDraws: 1)
    #expect(abs(ratings["A"]! - (1000 + 400 * log10(3.5 / 1.5))) < 1e-6)
  }

  @Test func threePlayersMatchIndependentSolver() {
    var results: [PairResult] = []
    results += games("A", "R", wins: 4, draws: 1, losses: 1)
    results += games("B", "R", wins: 1, losses: 4)
    results += games("A", "B", wins: 3, losses: 1)
    for priorDraws in [0.0, 1.0] {
      let fitted = BradleyTerry.fit(results, reference: "R", priorDraws: priorDraws)
      let expected = gradientFit(results, reference: "R", priorDraws: priorDraws)
      for id in ["A", "B", "R"] {
        #expect(abs(fitted[id]! - expected[id]!) < 1e-3, "\(id) prior \(priorDraws)")
      }
    }
  }

  @Test func priorKeepsUnbeatenPlayersFinite() {
    var results = games("Top", "R", wins: 20, losses: 0)
    results += games("Bottom", "R", wins: 0, losses: 20)
    let ratings = BradleyTerry.fit(results, reference: "R")
    #expect(ratings["Top"]!.isFinite && ratings["Bottom"]!.isFinite)
    #expect(ratings["Top"]! > 1000 && ratings["Bottom"]! < 1000)
    // Closed form: W = 20.5, n = 21, gamma = 20.5 / 0.5.
    #expect(abs(ratings["Top"]! - (1000 + 400 * log10(41.0))) < 1e-4)
  }

  @Test func referenceIsExactlyThousandAndAnchorsTheFit() {
    let results = games("A", "B", wins: 5, losses: 2)
    // The reference never played: it still anchors through the prior.
    let ratings = BradleyTerry.fit(results, reference: "R")
    #expect(ratings["R"] == 1000)
    #expect(ratings["A"]! > ratings["B"]!)
    #expect(ratings.count == 3)
    let expected = gradientFit(results, reference: "R", priorDraws: 1)
    #expect(abs(ratings["A"]! - expected["A"]!) < 1e-3)
    #expect(abs(ratings["B"]! - expected["B"]!) < 1e-3)
  }

  @Test func contestantsWhoNeverMetTheReferenceAreConnectedThroughOthers() {
    var results = games("A", "R", wins: 3, losses: 3)
    results += games("B", "A", wins: 4, losses: 1)
    let ratings = BradleyTerry.fit(results, reference: "R")
    #expect(ratings["B"]! > ratings["A"]!)
    let expected = gradientFit(results, reference: "R", priorDraws: 1)
    #expect(abs(ratings["B"]! - expected["B"]!) < 1e-3)
  }

  @Test func emptyAndOrderIndependent() {
    #expect(BradleyTerry.fit([]) == [Contestant.reference.id: 1000])
    var results = games("A", "R", wins: 4, draws: 1, losses: 1)
    results += games("B", "R", wins: 1, losses: 4)
    results += games("B", "A", wins: 1, draws: 2, losses: 2)
    let baseline = BradleyTerry.fit(results, reference: "R")
    var rng = SplitMix64(seed: 7)
    for _ in 0..<5 {
      let shuffled = results.shuffled(using: &rng)
      let fitted = BradleyTerry.fit(shuffled, reference: "R")
      for (id, value) in baseline { #expect(abs(fitted[id]! - value) < 1e-9) }
    }
  }

  // MARK: Bootstrap

  /// Seeded synthetic results from known strengths (Elo offsets) against random opponents.
  func synthetic(count: Int, seed: UInt64) -> [PairResult] {
    let strengths = ["R": 0.0, "A": 150, "B": -120, "C": 300, "D": 40]
    let ids = strengths.keys.sorted()
    var rng = SplitMix64(seed: seed)
    var results: [PairResult] = []
    for _ in 0..<count {
      let i = Int(rng.next() % UInt64(ids.count))
      var j = Int(rng.next() % UInt64(ids.count - 1))
      if j >= i { j += 1 }
      let p = 1 / (1 + pow(10, (strengths[ids[j]]! - strengths[ids[i]]!) / 400))
      let u = rng.nextUnit()
      let score: Double = u < p * 0.9 ? 1 : (u < p * 0.9 + 0.2 ? 0.5 : 0)
      results.append(PairResult(a: ids[i], b: ids[j], scoreA: score))
    }
    return results
  }

  @Test func bootstrapIsDeterministicAndContainsPoint() {
    let results = synthetic(count: 300, seed: 1)
    let first = BradleyTerry.bootstrap(results, reference: "R", resamples: 200, seed: 42)
    let second = BradleyTerry.bootstrap(results, reference: "R", resamples: 200, seed: 42)
    let other = BradleyTerry.bootstrap(results, reference: "R", resamples: 200, seed: 43)
    #expect(first == second)
    #expect(first != other)
    let point = BradleyTerry.fit(results, reference: "R")
    for (id, interval) in first {
      #expect(interval.contains(point[id]!), "\(id)")
    }
    #expect(first["R"] == 1000...1000)
  }

  @Test func bootstrapNarrowsWithMoreGames() {
    let small = BradleyTerry.bootstrap(
      synthetic(count: 150, seed: 2), reference: "R", resamples: 300, seed: 5)
    let large = BradleyTerry.bootstrap(
      synthetic(count: 2400, seed: 2), reference: "R", resamples: 300, seed: 5)
    for id in ["A", "B", "C", "D"] {
      let smallWidth = small[id]!.upperBound - small[id]!.lowerBound
      let largeWidth = large[id]!.upperBound - large[id]!.lowerBound
      #expect(largeWidth < smallWidth, "\(id)")
    }
  }

  @Test func bootstrapOfEmptyResultsIsDegenerate() {
    #expect(BradleyTerry.bootstrap([], reference: "R") == ["R": 1000...1000])
  }

  @Test func bootstrapSpeed() {
    let results = synthetic(count: 2000, seed: 3)
    // Ten contestants: relabel a third of the games to five more opponents.
    let widened = results.enumerated().map { index, result -> PairResult in
      index % 3 == 0 ? PairResult(a: result.a + "2", b: result.b, scoreA: result.scoreA) : result
    }
    #expect(Set(widened.flatMap { [$0.a, $0.b] }).count == 10)
    let clock = ContinuousClock()
    let start = clock.now
    let intervals = BradleyTerry.bootstrap(widened, reference: "R", resamples: 1000, seed: 9)
    let seconds = (clock.now - start).milliseconds / 1000
    print("bootstrap 1000 resamples, 2000 games, 10 contestants: \(seconds) s")
    #expect(intervals.count == 10)
    #expect(seconds < 30)
  }
}
