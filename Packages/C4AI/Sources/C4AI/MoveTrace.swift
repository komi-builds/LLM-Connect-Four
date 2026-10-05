import C4Core
import Foundation

/// Everything about one AI move, so it can be inspected or reproduced (§2, §4, §5).
public struct MoveTrace: Sendable, Hashable, Codable, Identifiable {
  public var id: UUID
  /// Moves before this one (0-based). The side to move is the AI.
  public var movesBefore: [Column]
  public var ply: Int { movesBefore.count }
  /// Provider display name ("Qwen3 4B Instruct", "Minimax d4", …).
  public var provider: String
  /// Hugging Face id for LLM moves, nil otherwise.
  public var modelID: String?
  public var style: ThinkingStyle
  public var difficulty: Difficulty
  public var variantID: String
  public var promptVersion: Int
  /// The exact prompt. Nil for non-LLM providers.
  public var prompt: Prompt?
  public var gameSeed: UInt64
  public var seed: UInt64
  public var move: AIMove
  public var createdAt: Date

  public init(
    id: UUID = UUID(), movesBefore: [Column], provider: String, modelID: String?,
    style: ThinkingStyle,
    difficulty: Difficulty, variantID: String, promptVersion: Int, prompt: Prompt?,
    gameSeed: UInt64,
    seed: UInt64, move: AIMove, createdAt: Date = Date()
  ) {
    self.id = id
    self.movesBefore = movesBefore
    self.provider = provider
    self.modelID = modelID
    self.style = style
    self.difficulty = difficulty
    self.variantID = variantID
    self.promptVersion = promptVersion
    self.prompt = prompt
    self.gameSeed = gameSeed
    self.seed = seed
    self.move = move
    self.createdAt = createdAt
  }

  /// Builds a trace from a finished turn.
  public init(
    context: TurnContext, provider: String, modelID: String?, prompt: Prompt?, move: AIMove
  ) {
    self.init(
      movesBefore: context.board.moves, provider: provider, modelID: modelID, style: context.style,
      difficulty: context.profile.difficulty, variantID: context.variant.id,
      promptVersion: prompt?.version ?? PromptBuilder.version, prompt: prompt,
      gameSeed: context.gameSeed,
      seed: context.seed, move: move)
  }
}

/// A played game in the app, saved as JSON under Application Support/games/ (last 200 kept).
public struct GameRecord: Sendable, Hashable, Codable, Identifiable {
  public var id: UUID
  public var startedAt: Date
  public var finishedAt: Date?
  public var humanDisc: Disc
  public var opponentName: String
  public var modelID: String?
  public var style: ThinkingStyle
  public var difficulty: Difficulty
  public var variantID: String
  public var gameSeed: UInt64
  public var moves: [Column]
  /// One per AI move, in order.
  public var traces: [MoveTrace]
  public var outcome: GameOutcome?

  public init(
    id: UUID = UUID(), startedAt: Date = Date(), finishedAt: Date? = nil, humanDisc: Disc = .first,
    opponentName: String, modelID: String?, style: ThinkingStyle, difficulty: Difficulty,
    variantID: String,
    gameSeed: UInt64, moves: [Column] = [], traces: [MoveTrace] = [], outcome: GameOutcome? = nil
  ) {
    self.id = id
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.humanDisc = humanDisc
    self.opponentName = opponentName
    self.modelID = modelID
    self.style = style
    self.difficulty = difficulty
    self.variantID = variantID
    self.gameSeed = gameSeed
    self.moves = moves
    self.traces = traces
    self.outcome = outcome
  }
}
