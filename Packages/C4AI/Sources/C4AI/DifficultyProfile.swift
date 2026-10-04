import C4Core

public enum Difficulty: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case easy, moderate, hard

    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}

/// Which `Tactics` facts go into the prompt.
public enum FactLevel: String, Sendable, Hashable, Codable {
    /// No facts.
    case none
    /// Immediate wins and must-blocks.
    case winsAndBlocks
    /// Wins, blocks, unsafe moves and threats it can create.
    case full
}

/// Everything difficulty controls, in one place (§3.6). The model always chooses the move;
/// difficulty only changes how much help it gets and how freely it samples.
public struct DifficultyProfile: Sendable, Hashable, Codable {
    public var difficulty: Difficulty
    public var facts: FactLevel
    /// Mask out moves that hand the opponent an immediate win, unless every move does.
    public var maskUnsafeMoves: Bool
    /// Column sampling temperature. 0 means greedy.
    public var columnTemperature: Double
    /// Re-prompt once if the model missed an immediate win or forced block (§3.5).
    public var selfCheck: Bool
    /// Depth for the non-LLM Engine opponent at this level.
    public var engineDepth: Int

    public init(
        difficulty: Difficulty, facts: FactLevel, maskUnsafeMoves: Bool, columnTemperature: Double,
        selfCheck: Bool, engineDepth: Int
    ) {
        self.difficulty = difficulty
        self.facts = facts
        self.maskUnsafeMoves = maskUnsafeMoves
        self.columnTemperature = columnTemperature
        self.selfCheck = selfCheck
        self.engineDepth = engineDepth
    }

    public static let easy = DifficultyProfile(
        difficulty: .easy, facts: .none, maskUnsafeMoves: false, columnTemperature: 1.0,
        selfCheck: false, engineDepth: 2)
    public static let moderate = DifficultyProfile(
        difficulty: .moderate, facts: .winsAndBlocks, maskUnsafeMoves: false, columnTemperature: 0.5,
        selfCheck: false, engineDepth: 4)
    public static let hard = DifficultyProfile(
        difficulty: .hard, facts: .full, maskUnsafeMoves: true, columnTemperature: 0,
        selfCheck: true, engineDepth: 7)

    public static func profile(for difficulty: Difficulty) -> DifficultyProfile {
        switch difficulty {
        case .easy: .easy
        case .moderate: .moderate
        case .hard: .hard
        }
    }

    /// Columns the model may answer with on `board`: all legal moves, minus unsafe ones on
    /// Hard (unless every legal move is unsafe).
    public func allowedColumns(on board: Board) -> [Column] {
        fatalError("TODO: agent B")
    }
}
