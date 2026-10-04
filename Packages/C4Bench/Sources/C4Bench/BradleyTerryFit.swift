import C4Core
import Foundation

/// Indexed game data and the MM solver behind `BradleyTerry`.
struct BTProblem {
  /// Sorted unique contestant ids (the reference is always included).
  let ids: [String]
  let reference: Int
  var k: Int { ids.count }
  private let a: [Int]
  private let b: [Int]
  private let score: [Double]
  var gameCount: Int { a.count }

  init(_ results: [PairResult], reference referenceID: String) {
    var set: Set<String> = [referenceID]
    for result in results {
      set.insert(result.a)
      set.insert(result.b)
    }
    ids = set.sorted()
    let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
    reference = index[referenceID]!
    var a: [Int] = []
    var b: [Int] = []
    var score: [Double] = []
    for result in results where result.a != result.b {
      a.append(index[result.a]!)
      b.append(index[result.b]!)
      score.append(result.scoreA)
    }
    self.a = a
    self.b = b
    self.score = score
  }

  /// Adds the games at `indices` (all games when nil) to the pair counts `n` (symmetric,
  /// row-major k x k) and the scores `w`.
  func accumulate(indices: [Int]?, into n: inout [Double], _ w: inout [Double]) {
    let k = self.k
    func add(_ g: Int) {
      let i = a[g]
      let j = b[g]
      n[i * k + j] += 1
      n[j * k + i] += 1
      w[i] += score[g]
      w[j] += 1 - score[g]
    }
    if let indices {
      for g in indices { add(g) }
    } else {
      for g in 0..<gameCount { add(g) }
    }
  }

  /// `draws` virtual draws between every non-reference contestant and the reference.
  func addPrior(_ draws: Double, to n: inout [Double], _ w: inout [Double]) {
    guard draws > 0 else { return }
    let k = self.k
    for i in 0..<k where i != reference {
      n[i * k + reference] += draws
      n[reference * k + i] += draws
      w[i] += 0.5 * draws
      w[reference] += 0.5 * draws
    }
  }

  /// MM iteration (Hunter 2004). Returns strengths with the reference normalised to 1.
  static func solve(
    k: Int, reference: Int, n: [Double], w: [Double], start: [Double]?, iterations: Int,
    tolerance: Double
  ) -> [Double] {
    var gamma = start ?? [Double](repeating: 1, count: k)
    var next = gamma
    let floor = 1e-300
    for _ in 0..<max(iterations, 1) {
      for i in 0..<k {
        var denominator = 0.0
        let row = i * k
        for j in 0..<k {
          let games = n[row + j]
          if games == 0 { continue }
          let total = gamma[i] + gamma[j]
          if total > 0 { denominator += games / total }
        }
        next[i] = denominator > 0 ? max(w[i] / denominator, floor) : gamma[i]
      }
      let scale = next[reference]
      var change = 0.0
      for i in 0..<k {
        next[i] /= scale
        change = max(change, abs(next[i] - gamma[i]) / gamma[i])
      }
      swap(&gamma, &next)
      if change < tolerance { break }
    }
    return gamma
  }

  func ratings(from gammas: [Double]) -> [String: Double] {
    var out: [String: Double] = [:]
    for (i, id) in ids.enumerated() {
      out[id] = 1000 + 400 * log10(gammas[i] / gammas[reference])
    }
    out[ids[reference]] = 1000
    return out
  }
}
