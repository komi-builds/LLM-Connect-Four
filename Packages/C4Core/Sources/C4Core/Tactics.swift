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
    /// Columns where `disc` would complete four with its next disc, whoever is to move.
    public static func immediateWins(_ board: Board, for disc: Disc) -> [Column] {
        fatalError("TODO: agent A")
    }

    /// Columns the side to move must play to stop the opponent's immediate wins.
    public static func mustBlock(_ board: Board) -> [Column] {
        fatalError("TODO: agent A")
    }

    /// Legal moves for the side to move after which the opponent can win immediately
    /// (including by playing on top of the disc just dropped).
    public static func unsafeMoves(_ board: Board) -> [Column] {
        fatalError("TODO: agent A")
    }

    /// For each legal move of the side to move, how many immediate winning squares it would
    /// create for the side to move (new threats only, not ones that already existed).
    /// Columns with zero are omitted.
    public static func threatsCreated(_ board: Board) -> [Column: Int] {
        fatalError("TODO: agent A")
    }

    /// Classifies the move `column` played by the side to move on `board`, or nil if it was
    /// not a blunder.
    public static func blunder(on board: Board, played column: Column) -> Blunder? {
        fatalError("TODO: agent A")
    }
}
