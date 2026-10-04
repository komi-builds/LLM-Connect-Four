import Foundation

/// Puzzle categories for the bench (§5.2).
public enum PuzzleCategory: String, Sendable, Codable, Hashable, CaseIterable {
  case winIn1 = "win-in-1"
  case blockIn1 = "block-in-1"
  case avoidBlunder = "avoid-the-blunder"
  case winIn3 = "win-in-3"
}

/// One position with its set of correct answers. Serialised in `puzzles.json`; see
/// `Resources/schemas/puzzles.schema.json`.
public struct Puzzle: Sendable, Codable, Hashable, Identifiable {
  /// Stable id, for example `"win-in-1-007"`.
  public var id: String
  public var category: PuzzleCategory
  /// Moves from the empty board (0-based). The side to move is the solver.
  public var moves: [Column]
  /// Every correct column (0-based), ascending.
  public var solutions: [Column]

  public init(id: String, category: PuzzleCategory, moves: [Column], solutions: [Column]) {
    self.id = id
    self.category = category
    self.moves = moves
    self.solutions = solutions
  }

  public var board: Board { try! Board(moves: moves) }
}

/// Generates and verifies bench puzzles (§5.2). Everything here is a pure function of the
/// seed: playouts use `SplitMix64` and verification uses the deterministic `Engine`.
public enum PuzzleGenerator {
  /// Engine depth used to decide avoid-the-blunder solutions.
  static let avoidDepth = 6
  /// Engine depth for win-in-3 (the winning drop is ply 3).
  static let winIn3Depth = 3
  /// Preferred length range of the move list.
  static let moveRange = 6...30

  public static func moveRangeContains(_ count: Int) -> Bool { moveRange.contains(count) }

  /// Generates puzzles from seeded random playouts, each verified by the engine. Returns
  /// `perCategory` puzzles per category (fewer if a category is too rare within the attempt
  /// budget), ordered by category then index. Ids are `"<category>-NNN"`, 1-based.
  public static func generate(seed: UInt64, perCategory: Int) -> [Puzzle] {
    var result: [Puzzle] = []
    var seenKeys = Set<UInt64>()
    for (index, category) in PuzzleCategory.allCases.enumerated() {
      var rng = SplitMix64(seed: seed &+ UInt64(index + 1) &* 0xD6E8_FEB8_6659_FD93)
      var found = 0
      var attempts = 0
      let maxAttempts = 3_000_000
      while found < perCategory && attempts < maxAttempts {
        attempts += 1
        guard let (moves, board) = playout(&rng) else { continue }
        guard let solutions = solutions(for: category, board) else { continue }
        // Dedupe by position key, also against the mirrored position.
        let key = board.key
        let mirrorKey = mirrored(moves).key
        guard !seenKeys.contains(key), !seenKeys.contains(mirrorKey) else { continue }
        seenKeys.insert(key)
        seenKeys.insert(mirrorKey)
        found += 1
        let number = String(found)
        let padded = String(repeating: "0", count: max(0, 3 - number.count)) + number
        result.append(
          Puzzle(
            id: "\(category.rawValue)-\(padded)", category: category, moves: moves,
            solutions: solutions))
      }
    }
    return result
  }

  /// Re-derives the solution set with the engine and compares. True if the puzzle is valid.
  public static func check(_ puzzle: Puzzle) -> Bool {
    guard let board = try? Board(moves: puzzle.moves), !board.isGameOver else { return false }
    guard puzzle.solutions == puzzle.solutions.sorted(),
      Set(puzzle.solutions).count == puzzle.solutions.count, !puzzle.solutions.isEmpty
    else { return false }
    guard let derived = solutions(for: puzzle.category, board) else { return false }
    return derived == puzzle.solutions
  }

  /// The JSON used for `puzzles.json`: a stable layout with one puzzle per line, sorted keys.
  public static func encode(_ puzzles: [Puzzle]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let lines = try puzzles.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
    return Data(("[\n  " + lines.joined(separator: ",\n  ") + "\n]\n").utf8)
  }

  // MARK: Internals

  /// A random playout of a random target length, or nil if the game ended early.
  private static func playout(_ rng: inout SplitMix64) -> (moves: [Column], board: Board)? {
    let target = Int(rng.next() % UInt64(moveRange.count)) + moveRange.lowerBound
    var board = Board()
    for _ in 0..<target {
      let legal = board.legalMoves
      guard !legal.isEmpty else { return nil }
      board = board.dropping(legal[Int(rng.next() % UInt64(legal.count))])
      if board.isGameOver { return nil }
    }
    return (board.moves, board)
  }

  private static func mirrored(_ moves: [Column]) -> Board {
    try! Board(moves: moves.map { Board.columnCount - 1 - $0 })
  }

  /// The sorted solution columns if `board` is a valid puzzle of `category`, else nil.
  static func solutions(for category: PuzzleCategory, _ board: Board) -> [Column]? {
    guard !board.isGameOver, moveRange.contains(board.plyCount) else { return nil }
    let wins = Tactics.immediateWins(board, for: board.toMove)
    let threats = Tactics.mustBlock(board)
    switch category {
    case .winIn1:
      return wins.isEmpty ? nil : wins
    case .blockIn1:
      return wins.isEmpty && threats.count == 1 ? threats : nil
    case .avoidBlunder:
      guard wins.isEmpty, threats.isEmpty else { return nil }
      let unsafe = Set(Tactics.unsafeMoves(board))
      guard !unsafe.isEmpty, unsafe.count < board.legalMoves.count else { return nil }
      let scores = Engine(depth: avoidDepth).scores(board)
      let best = scores.values.max()!
      let solutions = scores.filter { $0.value == best }.keys.sorted()
      guard !solutions.isEmpty, solutions.allSatisfy({ !unsafe.contains($0) }) else { return nil }
      return solutions
    case .winIn3:
      guard wins.isEmpty else { return nil }
      let scores = Engine(depth: winIn3Depth).scores(board)
      let solutions = scores.filter { $0.value == 997 }.keys.sorted()
      return solutions.isEmpty ? nil : solutions
    }
  }
}
