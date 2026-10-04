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

public enum PuzzleGenerator {
    /// Generates puzzles from seeded random playouts, each verified by the engine.
    public static func generate(seed: UInt64, perCategory: Int) -> [Puzzle] {
        fatalError("TODO: agent G")
    }

    /// Re-derives the solution set with the engine and compares. True if the puzzle is valid.
    public static func check(_ puzzle: Puzzle) -> Bool {
        fatalError("TODO: agent G")
    }
}
