/// Alpha-beta negamax with a transposition table. Deterministic: columns are searched in
/// `columnOrder` (3, 2, 4, 1, 5, 0, 6) and ties go to the earlier column in that order.
///
/// Scores are from the side to move's point of view, and `depth` counts plies:
/// - A win the side to move can force in `n` plies (its own winning drop is ply 1) scores
///   `1000 - n`. A loss in `n` plies scores `-(1000 - n)`. So faster wins and slower losses
///   score higher; every decided score has magnitude above 900 for depths below 100.
/// - A drawn full board scores 0.
/// - A non-terminal position at the depth limit scores a heuristic in -400...400: for every
///   four-cell window holding discs of only one side, 3 for two discs and 12 for three
///   (positive for the side to move, negative for the opponent), plus centre control
///   (disc weight 0, 1, 2, 3, 2, 1, 0 by column, mine minus theirs).
/// - An immediate win is always seen (depth >= 1) and a single immediate threat is always
///   blocked at depth >= 2, because the opponent's win then lands inside the horizon.
public struct Engine: Sendable {
  /// Centre-first search order.
  public static let columnOrder: [Column] = [3, 2, 4, 1, 5, 0, 6]

  /// Search depth in plies. Anchors use 1, 2, 4, 6; the Engine opponent uses 2 / 4 / 7.
  public let depth: Int

  public init(depth: Int) {
    precondition(depth >= 1)
    self.depth = depth
  }

  /// The best legal move for the side to move: the highest `scores` entry, ties going to
  /// the column that comes first in `columnOrder`.
  /// - Precondition: the game is not over.
  public func bestMove(_ board: Board) -> Column {
    precondition(!board.isGameOver, "game is over")
    var searcher = Searcher(depth: depth)
    var best = -1
    var bestScore = Int.min
    for column in Engine.columnOrder where board.canPlay(column) {
      // Only a strictly better score matters, so search with alpha = bestScore.
      let alpha = bestScore == Int.min ? -Searcher.inf : bestScore
      let s = searcher.rootScore(board, column, alpha: alpha, beta: Searcher.inf)
      if s > bestScore {
        bestScore = s
        best = column
      }
    }
    return best
  }

  /// The score of every legal move for the side to move, searched to `depth`.
  /// Empty once the game is over.
  public func scores(_ board: Board) -> [Column: Int] {
    var searcher = Searcher(depth: depth)
    var result: [Column: Int] = [:]
    for column in Engine.columnOrder where board.canPlay(column) {
      result[column] = searcher.rootScore(
        board, column, alpha: -Searcher.inf, beta: Searcher.inf)
    }
    return result
  }
}

// MARK: - Search

private struct Searcher {
  static let inf = 100_000
  static let winScore = 1000
  static let order = Engine.columnOrder

  struct Entry {
    var key: UInt64 = 0
    var value: Int16 = 0
    /// 0 empty, 1 exact, 2 lower bound, 3 upper bound.
    var flag: UInt8 = 0
  }

  let depth: Int
  var table: [Entry]
  let tableMask: Int

  init(depth: Int) {
    self.depth = depth
    let bits = depth <= 2 ? 8 : min(20, 6 + 2 * depth)
    table = [Entry](repeating: Entry(), count: 1 << bits)
    tableMask = (1 << bits) - 1
  }

  static let fullMask: UInt64 = (0..<7).reduce(0) { $0 | Board.columnMask($1) }
  static let bottomAll: UInt64 = (0..<7).reduce(0) { $0 | Board.bottomMask($1) }

  /// Empty cells that would complete four for `p`.
  @inline(__always)
  static func winningSquares(_ p: UInt64, _ m: UInt64) -> UInt64 {
    var r = (p << 1) & (p << 2) & (p << 3)
    for h: UInt64 in [7, 6, 8] {
      var q = (p << h) & (p << (2 * h))
      r |= q & (p << (3 * h))
      r |= q & (p >> h)
      q = (p >> h) & (p >> (2 * h))
      r |= q & (p << h)
      r |= q & (p >> (3 * h))
    }
    return r & (fullMask ^ m)
  }

  /// Score of playing `column` for the side to move on `board`, within (alpha, beta).
  mutating func rootScore(_ board: Board, _ column: Column, alpha: Int, beta: Int) -> Int {
    let p = board.position
    let m = board.mask
    let bit = (m &+ Board.bottomMask(column)) & Board.columnMask(column)
    if Searcher.winningSquares(p, m) & bit != 0 { return Searcher.winScore - 1 }
    return Searcher.lift(
      negamax(p ^ m, m | bit, depth: depth - 1, alpha: -beta - 1, beta: -alpha + 1))
  }

  /// Converts a child's score to the parent's view: negate, and push decided scores one
  /// ply further from the root.
  @inline(__always)
  static func lift(_ c: Int) -> Int {
    if c > 500 { return -(c - 1) }
    if c < -500 { return -(c + 1) }
    return -c
  }

  /// `p` is the side to move's discs, `m` all discs.
  mutating func negamax(_ p: UInt64, _ m: UInt64, depth: Int, alpha: Int, beta: Int) -> Int {
    let possible = (m &+ Searcher.bottomAll) & Searcher.fullMask
    if possible == 0 { return 0 }
    if depth == 0 { return Searcher.evaluate(p, m) }
    if Searcher.winningSquares(p, m) & possible != 0 { return Searcher.winScore - 1 }

    var forced = possible
    if depth >= 2 {
      let threats = Searcher.winningSquares(p ^ m, m) & possible
      if threats != 0 {
        if threats & (threats &- 1) != 0 { return -(Searcher.winScore - 2) }
        forced = threats
      }
    }

    var alpha = alpha
    var beta = beta
    let key = p &+ m
    let index = Int(truncatingIfNeeded: (key &* 0x9E37_79B9_7F4A_7C15) >> 40) & tableMask
    let entry = table[index]
    if entry.flag != 0 && entry.key == key {
      let v = Int(entry.value)
      switch entry.flag {
      case 1: return v
      case 2: alpha = max(alpha, v)
      default: beta = min(beta, v)
      }
      if alpha >= beta { return v }
    }
    let originalAlpha = alpha

    var best = -Searcher.inf
    for column in Searcher.order {
      let bit = forced & Board.columnMask(column)
      if bit == 0 { continue }
      let s = Searcher.lift(
        negamax(p ^ m, m | bit, depth: depth - 1, alpha: -beta - 1, beta: -alpha + 1))
      if s > best {
        best = s
        if s > alpha { alpha = s }
        if alpha >= beta { break }
      }
    }

    var stored = Entry(key: key, value: Int16(best), flag: 1)
    if best <= originalAlpha {
      stored.flag = 3
    } else if best >= beta {
      stored.flag = 2
    }
    table[index] = stored
    return best
  }

  // MARK: Heuristic

  static let windows: [UInt64] = {
    var result: [UInt64] = []
    let dirs = [(1, 0), (0, 1), (1, 1), (1, -1)]
    for c in 0..<7 {
      for r in 0..<6 {
        for (dc, dr) in dirs {
          let ec = c + 3 * dc
          let er = r + 3 * dr
          guard (0..<7).contains(ec), (0..<6).contains(er) else { continue }
          var w: UInt64 = 0
          for i in 0..<4 { w |= 1 << UInt64((c + i * dc) * 7 + r + i * dr) }
          result.append(w)
        }
      }
    }
    return result
  }()

  static let columnMasks: [UInt64] = (0..<7).map { Board.columnMask($0) }
  static let columnWeights = [0, 1, 2, 3, 2, 1, 0]

  /// Heuristic for a non-terminal position, from the side to move's view.
  static func evaluate(_ p: UInt64, _ m: UInt64) -> Int {
    let o = p ^ m
    var score = 0
    for w in windows {
      let mine = (p & w).nonzeroBitCount
      let theirs = (o & w).nonzeroBitCount
      if theirs == 0 {
        if mine == 2 {
          score += 3
        } else if mine == 3 {
          score += 12
        }
      } else if mine == 0 {
        if theirs == 2 {
          score -= 3
        } else if theirs == 3 {
          score -= 12
        }
      }
    }
    for c in 0..<7 where columnWeights[c] != 0 {
      let diff = (p & columnMasks[c]).nonzeroBitCount - (o & columnMasks[c]).nonzeroBitCount
      score += columnWeights[c] * diff
    }
    return max(-400, min(400, score))
  }
}
