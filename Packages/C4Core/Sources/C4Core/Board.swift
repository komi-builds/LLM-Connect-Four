/// A column index. **0-based everywhere in code** (0...6). Prompts and visible UI
/// show 1...7; the conversion happens only in `BoardEncoder` and the views.
public typealias Column = Int

/// The two sides, named by move order. The encoder relabels them to "you" (`O`) and
/// "opponent" (`X`); the UI maps them to human and AI.
public enum Disc: String, Sendable, Codable, Hashable, CaseIterable {
  case first
  case second

  public var opponent: Disc { self == .first ? .second : .first }
}

/// One cell on the board. `row` 0 is the bottom row.
public struct Cell: Sendable, Codable, Hashable {
  public var column: Column
  public var row: Int

  public init(column: Column, row: Int) {
    self.column = column
    self.row = row
  }
}

/// How a finished game ended.
public enum GameOutcome: Sendable, Codable, Hashable {
  case win(Disc)
  case draw
}

public enum BoardError: Error, Equatable, Sendable {
  case illegalMove(Column, ply: Int)
}

/// A 6×7 Connect Four position as a bitboard (Pascal Pons layout).
///
/// Each column uses 7 bits (6 playable rows plus one sentinel bit on top), so bit
/// `column * 7 + row` is the cell at `(column, row)` with row 0 at the bottom.
/// `mask` holds every disc; `position` holds the discs of the side to move.
public struct Board: Sendable, Hashable, CustomStringConvertible {
  public static let columnCount = 7
  public static let rowCount = 6
  public static let allColumns: [Column] = Array(0..<7)
  static let bitsPerColumn = 7

  /// Every move played so far, in order.
  public private(set) var moves: [Column] = []
  /// Discs of the side to move.
  public private(set) var position: UInt64 = 0
  /// Every disc on the board.
  public private(set) var mask: UInt64 = 0
  /// Set as soon as a move completes four in a row.
  public private(set) var winner: Disc?

  public init() {}

  /// Replays `moves` from the empty board.
  public init(moves: some Sequence<Column>) throws(BoardError) {
    for column in moves {
      guard canPlay(column) else { throw .illegalMove(column, ply: self.moves.count) }
      drop(column)
    }
  }

  // MARK: Queries

  public var plyCount: Int { moves.count }
  public var toMove: Disc { moves.count.isMultiple(of: 2) ? .first : .second }
  public var isDraw: Bool { winner == nil && moves.count == Board.columnCount * Board.rowCount }
  public var isGameOver: Bool { winner != nil || isDraw }
  public var outcome: GameOutcome? {
    if let winner { return .win(winner) }
    return isDraw ? .draw : nil
  }
  /// A unique key for this position, for transposition tables.
  public var key: UInt64 { position &+ mask }

  /// True if `column` is on the board, not full, and the game is not over.
  public func canPlay(_ column: Column) -> Bool {
    guard (0..<Board.columnCount).contains(column), winner == nil else { return false }
    return mask & Board.topMask(column) == 0
  }

  /// Legal columns in left-to-right order. Empty once the game is over.
  public var legalMoves: [Column] { Board.allColumns.filter(canPlay) }

  /// Number of discs in `column`, which is also the row the next disc lands in.
  public func height(of column: Column) -> Int {
    (mask & Board.columnMask(column)).nonzeroBitCount
  }

  /// The disc at `(column, row)`, row 0 at the bottom, or nil if empty.
  public func disc(atColumn column: Column, row: Int) -> Disc? {
    let bit = UInt64(1) << UInt64(column * Board.bitsPerColumn + row)
    guard mask & bit != 0 else { return nil }
    return position & bit != 0 ? toMove : toMove.opponent
  }

  public subscript(cell: Cell) -> Disc? { disc(atColumn: cell.column, row: cell.row) }

  /// Bitboard of one side's discs.
  public func bits(for disc: Disc) -> UInt64 {
    disc == toMove ? position : position ^ mask
  }

  /// True if the side to move wins immediately by playing `column`.
  public func isWinningMove(_ column: Column) -> Bool {
    guard canPlay(column) else { return false }
    let p = position | ((mask &+ Board.bottomMask(column)) & Board.columnMask(column))
    return Board.hasFour(p)
  }

  /// True if `disc` would complete four by dropping into `column`, regardless of
  /// whose turn it is.
  public func wouldWin(_ disc: Disc, playing column: Column) -> Bool {
    guard canPlay(column) else { return false }
    let p = bits(for: disc) | ((mask &+ Board.bottomMask(column)) & Board.columnMask(column))
    return Board.hasFour(p)
  }

  // MARK: Moves

  /// Drops a disc for the side to move. Returns the row it landed in.
  /// - Precondition: `canPlay(column)`.
  @discardableResult
  public mutating func drop(_ column: Column) -> Int {
    precondition(canPlay(column), "illegal move \(column)")
    let mover = toMove
    let row = height(of: column)
    position ^= mask
    mask |= mask &+ Board.bottomMask(column)
    moves.append(column)
    if Board.hasFour(position ^ mask) { winner = mover }
    return row
  }

  /// A copy with `column` played.
  public func dropping(_ column: Column) -> Board {
    var copy = self
    copy.drop(column)
    return copy
  }

  /// Takes back the last move.
  /// - Precondition: at least one move has been played.
  public mutating func undo() {
    guard let column = moves.popLast() else { preconditionFailure("nothing to undo") }
    let columnBits = mask & Board.columnMask(column)
    let top = UInt64(1) << UInt64(63 - columnBits.leadingZeroBitCount)
    mask &= ~top
    position ^= mask
    winner = nil
  }

  // MARK: Winning line

  /// Every cell that is part of a four-in-a-row for the winner, or nil if no one has won.
  public var winningCells: Set<Cell>? {
    guard let winner else { return nil }
    var cells = Set<Cell>()
    let directions = [(1, 0), (0, 1), (1, 1), (1, -1)]
    for c in 0..<Board.columnCount {
      for r in 0..<Board.rowCount {
        for (dc, dr) in directions {
          let line = (0..<4).map { Cell(column: c + dc * $0, row: r + dr * $0) }
          let inside = line.allSatisfy {
            (0..<Board.columnCount).contains($0.column) && (0..<Board.rowCount).contains($0.row)
          }
          if inside, line.allSatisfy({ self[$0] == winner }) {
            cells.formUnion(line)
          }
        }
      }
    }
    return cells
  }

  // MARK: Bit helpers

  public static func bottomMask(_ column: Column) -> UInt64 {
    UInt64(1) << UInt64(column * bitsPerColumn)
  }

  public static func topMask(_ column: Column) -> UInt64 {
    UInt64(1) << UInt64(rowCount - 1 + column * bitsPerColumn)
  }

  public static func columnMask(_ column: Column) -> UInt64 {
    ((UInt64(1) << UInt64(rowCount)) - 1) << UInt64(column * bitsPerColumn)
  }

  /// True if the bitboard `p` contains four in a row in any direction.
  public static func hasFour(_ p: UInt64) -> Bool {
    for shift in [UInt64(bitsPerColumn), UInt64(bitsPerColumn - 1), UInt64(bitsPerColumn + 1), 1] {
      let m = p & (p >> shift)
      if m & (m >> (2 * shift)) != 0 { return true }
    }
    return false
  }

  // MARK: Debug

  /// Rows top-down, `1` = first player, `2` = second, `.` = empty.
  public var description: String {
    (0..<Board.rowCount).reversed().map { row in
      Board.allColumns.map { column in
        switch disc(atColumn: column, row: row) {
        case .first: "1"
        case .second: "2"
        case nil: "."
        }
      }.joined(separator: " ")
    }.joined(separator: "\n")
  }
}

extension Board: Codable {
  /// Encoded as its move list, so a board round-trips exactly.
  public init(from decoder: any Decoder) throws {
    let moves = try decoder.singleValueContainer().decode([Column].self)
    try self.init(moves: moves)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(moves)
  }
}
