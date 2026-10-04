import C4Core

/// Turns a board into text the model can read without doing perception work (§3.1).
///
/// Rules: fixed perspective (the side to move is `O`, the opponent `X`), only `X`, `O` and
/// `.` separated by spaces, columns 1–7, rows 1 (bottom) to 6 (top) printed top-down, and
/// pre-computed landing rows. This is the only place 0-based columns become 1-based.
public enum BoardEncoder {
  /// The 6×7 grid with a column header, as in §3.1.
  public static func grid(_ board: Board) -> String {
    let side = board.toMove
    var lines = ["Board (row 6 at top):", "   1 2 3 4 5 6 7"]
    for row in (0..<Board.rowCount).reversed() {
      let cells = Board.allColumns.map {
        symbol(board.disc(atColumn: $0, row: row), sideToMove: side)
      }
      lines.append("\(row + 1)  " + cells.joined(separator: " "))
    }
    return lines.joined(separator: "\n")
  }

  /// The per-column list (bottom → top) with the landing row of each legal column.
  ///
  /// One column per line: `3: X O → lands row 3`, `1: empty → lands row 1`, or
  /// `5: O X O X O X → full`. Discs are listed bottom to top.
  public static func columns(_ board: Board) -> String {
    let side = board.toMove
    var lines = ["Columns (bottom → top):"]
    for column in Board.allColumns {
      let height = board.height(of: column)
      let discs = (0..<height).map {
        symbol(board.disc(atColumn: column, row: $0), sideToMove: side)
      }
      let contents = discs.isEmpty ? "empty" : discs.joined(separator: " ")
      let status = height >= Board.rowCount ? "full" : "lands row \(height + 1)"
      lines.append("\(label(column)): \(contents) → \(status)")
    }
    return lines.joined(separator: "\n")
  }

  /// "Moves so far: X4 O4 X3 … (11 total)", labelled from the side to move's perspective.
  ///
  /// All moves are listed (at most 42, which is short), so there is no truncation. An empty
  /// board gives "Moves so far: none".
  public static func history(_ board: Board) -> String {
    guard !board.moves.isEmpty else { return "Moves so far: none" }
    let side = board.toMove
    let moves = board.moves.enumerated().map { index, column in
      let mover: Disc = index.isMultiple(of: 2) ? .first : .second
      return symbol(mover, sideToMove: side) + label(column)
    }
    return "Moves so far: " + moves.joined(separator: " ") + " (\(board.moves.count) total)"
  }

  /// "X", "O" or "." for a cell, from the side to move's perspective.
  public static func symbol(_ disc: Disc?, sideToMove: Disc) -> String {
    guard let disc else { return "." }
    return disc == sideToMove ? "O" : "X"
  }

  /// 0-based column to the 1-based label used in prompts and the UI.
  public static func label(_ column: Column) -> String { String(column + 1) }
}
