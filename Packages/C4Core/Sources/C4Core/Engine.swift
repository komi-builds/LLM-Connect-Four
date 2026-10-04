/// Alpha-beta minimax with a transposition table. Deterministic: ties break toward the
/// centre (column order 3, 2, 4, 1, 5, 0, 6).
///
/// Scores are from the side to move's point of view: positive is good for the side to
/// move, larger magnitude means a faster win or loss. A score of 0 means no forced result
/// within the depth (or a heuristic evaluation, if one is used).
public struct Engine: Sendable {
    /// Centre-first search order.
    public static let columnOrder: [Column] = [3, 2, 4, 1, 5, 0, 6]

    /// Search depth in plies. Anchors use 1, 2, 4, 6; the Engine opponent uses 2 / 4 / 7.
    public let depth: Int

    public init(depth: Int) {
        precondition(depth >= 1)
        self.depth = depth
    }

    /// The best legal move for the side to move.
    /// - Precondition: the game is not over.
    public func bestMove(_ board: Board) -> Column {
        fatalError("TODO: agent A")
    }

    /// The score of every legal move for the side to move, searched to `depth`.
    public func scores(_ board: Board) -> [Column: Int] {
        fatalError("TODO: agent A")
    }
}
