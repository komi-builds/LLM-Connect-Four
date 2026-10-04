/// A tactical mistake, measured after the fact.
public enum Blunder: String, Sendable, Codable, Hashable, CaseIterable {
  /// The mover could have won immediately and didn't.
  case missedWin
  /// The opponent threatened an immediate win, the mover couldn't win first, and the
  /// mover didn't block it.
  case missedBlock
}

/// Short-range tactical facts. Used for prompt facts (§3.6), Hard's legal-move mask, the
/// self-check (§3.5) and blunder counting in the bench. All results are 0-based columns in
/// ascending order.
public enum Tactics {
  /// Playable cells (one per non-full column) as a bitboard.
  private static func playable(_ board: Board) -> UInt64 {
    var result: UInt64 = 0
    for column in Board.allColumns where board.canPlay(column) {
      result |= (board.mask &+ Board.bottomMask(column)) & Board.columnMask(column)
    }
    return result
  }

  /// Empty cells that would complete four for `discs`.
  private static func winningCells(_ discs: UInt64, _ mask: UInt64) -> UInt64 {
    var r = (discs << 1) & (discs << 2) & (discs << 3)
    for h: UInt64 in [7, 6, 8] {
      var q = (discs << h) & (discs << (2 * h))
      r |= q & (discs << (3 * h))
      r |= q & (discs >> h)
      q = (discs >> h) & (discs >> (2 * h))
      r |= q & (discs << h)
      r |= q & (discs >> (3 * h))
    }
    let all = Board.allColumns.reduce(UInt64(0)) { $0 | Board.columnMask($1) }
    return r & (all ^ mask)
  }

  private static func columns(of cells: UInt64) -> [Column] {
    Board.allColumns.filter { cells & Board.columnMask($0) != 0 }
  }

  /// Columns where `disc` would complete four with its next disc, whoever is to move.
  /// Empty once the game is over.
  public static func immediateWins(_ board: Board, for disc: Disc) -> [Column] {
    guard !board.isGameOver else { return [] }
    let wins = winningCells(board.bits(for: disc), board.mask) & playable(board)
    return columns(of: wins)
  }

  /// Columns the side to move must play to stop the opponent's immediate wins, which are
  /// exactly the opponent's immediate winning columns. With two threats both columns are
  /// returned (blocking only one still loses).
  public static func mustBlock(_ board: Board) -> [Column] {
    immediateWins(board, for: board.toMove.opponent)
  }

  /// Legal moves for the side to move after which the opponent can win immediately
  /// (including by playing on top of the disc just dropped). A winning move is never unsafe.
  public static func unsafeMoves(_ board: Board) -> [Column] {
    board.legalMoves.filter { column in
      let next = board.dropping(column)
      return !immediateWins(next, for: next.toMove).isEmpty
    }
  }

  /// For each legal move of the side to move, how many immediate winning squares it would
  /// create for the side to move (new threats only, not ones that already existed).
  /// Columns with zero are omitted. Winning moves end the game and so create none.
  public static func threatsCreated(_ board: Board) -> [Column: Int] {
    let mover = board.toMove
    let before = Set(immediateWins(board, for: mover))
    var result: [Column: Int] = [:]
    for column in board.legalMoves {
      let next = board.dropping(column)
      guard !next.isGameOver else { continue }
      let after = immediateWins(next, for: mover)
      let created = after.filter { !before.contains($0) }.count
      if created > 0 { result[column] = created }
    }
    return result
  }

  /// Classifies the move `column` played by the side to move on `board`, or nil if it was
  /// not a blunder. When the opponent has two threats, blocking either one is not a
  /// `missedBlock`.
  public static func blunder(on board: Board, played column: Column) -> Blunder? {
    guard !board.isGameOver else { return nil }
    let wins = immediateWins(board, for: board.toMove)
    if !wins.isEmpty {
      return wins.contains(column) ? nil : .missedWin
    }
    let threats = mustBlock(board)
    if !threats.isEmpty && !threats.contains(column) { return .missedBlock }
    return nil
  }
}
