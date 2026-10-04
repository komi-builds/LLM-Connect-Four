import C4Core

/// Turns a board into text the model can read without doing perception work (§3.1).
///
/// Rules: fixed perspective (the side to move is `O`, the opponent `X`), only `X`, `O` and
/// `.` separated by spaces, columns 1–7, rows 1 (bottom) to 6 (top) printed top-down, and
/// pre-computed landing rows. This is the only place 0-based columns become 1-based.
public enum BoardEncoder {
    /// The 6×7 grid with a column header, as in §3.1.
    public static func grid(_ board: Board) -> String {
        fatalError("TODO: agent B")
    }

    /// The per-column list (bottom → top) with the landing row of each legal column.
    public static func columns(_ board: Board) -> String {
        fatalError("TODO: agent B")
    }

    /// "Moves so far: X4 O4 X3 … (11 total)", labelled from the side to move's perspective.
    public static func history(_ board: Board) -> String {
        fatalError("TODO: agent B")
    }

    /// "X", "O" or "." for a cell, from the side to move's perspective.
    public static func symbol(_ disc: Disc?, sideToMove: Disc) -> String {
        guard let disc else { return "." }
        return disc == sideToMove ? "O" : "X"
    }

    /// 0-based column to the 1-based label used in prompts and the UI.
    public static func label(_ column: Column) -> String { String(column + 1) }
}
