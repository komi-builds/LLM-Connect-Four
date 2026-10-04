import C4Core
import Foundation

/// Anything that can choose a move: the LLM, the engine, random, or the mock.
///
/// A turn is a stream of events. The UI and the bench consume the same stream, which is
/// how the Thinking panel shows thinking live. Every stream ends with exactly one
/// `.decided` or `.failed`, then finishes. Cancelling the consuming task must stop
/// generation promptly (providers check `Task.isCancelled` on every token).
public protocol MoveProvider: Sendable {
    /// Short display name, for example "Qwen3 4B Instruct" or "Minimax d4".
    var name: String { get }
    func move(_ context: TurnContext) -> AsyncStream<TurnEvent>
}

/// A provider that must be loaded before use (the LLM).
public protocol LoadableMoveProvider: MoveProvider {
    /// Downloads if needed, loads, caches the static prefix and warms up. Reports progress
    /// on any thread. Safe to call again after `unload()`.
    func load(progress: @escaping @Sendable (LoadProgress) -> Void) async throws
    func unload() async
    var isReady: Bool { get async }
    /// Warms the static prefix for `context`'s style and variant, so the first move after a
    /// style change doesn't pay for it. Call after `load` and whenever style or variant
    /// change. The default does nothing.
    func prepare(for context: TurnContext) async throws
}

extension LoadableMoveProvider {
    public func prepare(for context: TurnContext) async throws {}
}

/// Load progress, shown as the "Warming up… 63%" pill.
public struct LoadProgress: Sendable, Hashable {
    public enum Phase: String, Sendable, Hashable {
        case downloading, loading, warmingUp, ready
    }

    public var phase: Phase
    /// Overall fraction 0...1 across all phases.
    public var fraction: Double
    /// Download speed, when downloading.
    public var bytesPerSecond: Double?

    public init(phase: Phase, fraction: Double, bytesPerSecond: Double? = nil) {
        self.phase = phase
        self.fraction = fraction
        self.bytesPerSecond = bytesPerSecond
    }
}

/// Everything a provider needs for one turn. The side to move on `board` is the AI.
public struct TurnContext: Sendable, Hashable {
    public var board: Board
    public var style: ThinkingStyle
    public var profile: DifficultyProfile
    public var variant: PromptVariant
    /// Token budget for reasoning (Explain) or thoughts (Deep think). Ignored by Instinct.
    public var thinkingBudget: Int
    public var gameSeed: UInt64
    /// Facts added by the Hard self-check re-prompt (§3.5); empty otherwise.
    public var extraFacts: [String]

    public init(
        board: Board,
        style: ThinkingStyle = .explain,
        profile: DifficultyProfile = .moderate,
        variant: PromptVariant = .default,
        thinkingBudget: Int? = nil,
        gameSeed: UInt64,
        extraFacts: [String] = []
    ) {
        self.board = board
        self.style = style
        self.profile = profile
        self.variant = variant
        self.thinkingBudget = thinkingBudget ?? style.defaultBudget
        self.gameSeed = gameSeed
        self.extraFacts = extraFacts
    }

    public var aiDisc: Disc { board.toMove }
    /// `Seeds.move(gameSeed:ply:)` for this turn.
    public var seed: UInt64 { Seeds.move(gameSeed: gameSeed, ply: board.plyCount) }
}

/// One event in a turn.
public enum TurnEvent: Sendable, Hashable {
    /// The exact prompt for this move (for the "What the model sees" inspector).
    case prompt(Prompt)
    /// A token of Deep-think content (inside `<think>…</think>`).
    case thinkingToken(String)
    /// A token of visible reasoning (Explain, or after `</think>`).
    case reasoningToken(String)
    /// The model's current lean. Emitted at least once before `.decided`.
    case distribution(ColumnDistribution)
    /// The final move. Terminal.
    case decided(AIMove)
    /// Something failed (out of memory, model error). Terminal. Never caused by bad
    /// output; `FallbackMoveProvider` turns this into an engine move.
    case failed(MoveError)
}

public struct MoveError: Error, Sendable, Hashable, Codable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// A probability per column. Always 7 entries, index = 0-based column; columns that are
/// not offered are 0 and listed in `masked`.
public struct ColumnDistribution: Sendable, Hashable, Codable {
    public var probabilities: [Double]
    /// Columns excluded from the answer: full, or masked by difficulty (Hard).
    public var masked: Set<Column>

    public init(probabilities: [Double], masked: Set<Column>) {
        precondition(probabilities.count == Board.columnCount)
        self.probabilities = probabilities
        self.masked = masked
    }

    /// Softmax over `logits` restricted to `allowed`. Temperature only matters for sampling,
    /// so the displayed distribution is always at temperature 1.
    public static func softmax(logits: [Double], allowed: [Column]) -> ColumnDistribution {
        precondition(logits.count == Board.columnCount && !allowed.isEmpty)
        let maxLogit = allowed.map { logits[$0] }.max()!
        var probabilities = [Double](repeating: 0, count: Board.columnCount)
        for column in allowed { probabilities[column] = Foundation.exp(logits[column] - maxLogit) }
        let total = probabilities.reduce(0, +)
        for column in allowed { probabilities[column] /= total }
        let masked = Set(Board.allColumns).subtracting(allowed)
        return ColumnDistribution(probabilities: probabilities, masked: masked)
    }

    /// Highest-probability column; ties break toward the centre.
    public var argmax: Column {
        Engine.columnOrder.filter { !masked.contains($0) }.max { probabilities[$0] < probabilities[$1] }!
    }

    /// Samples a column. `temperature` 0 means greedy (argmax).
    public func sample(temperature: Double, using rng: inout some RandomNumberGenerator) -> Column {
        guard temperature > 0 else { return argmax }
        let allowed = Board.allColumns.filter { !masked.contains($0) && probabilities[$0] > 0 }
        let weights = allowed.map { Foundation.pow(probabilities[$0], 1 / temperature) }
        let total = weights.reduce(0, +)
        var r = Double(rng.next() >> 11) * 0x1.0p-53 * total
        for (column, weight) in zip(allowed, weights) {
            r -= weight
            if r < 0 { return column }
        }
        return allowed.last ?? argmax
    }
}

/// Where a move came from.
public enum MoveSource: String, Sendable, Hashable, Codable {
    /// The model's first answer.
    case model
    /// The model's second answer, after the Hard self-check re-prompt.
    case modelAfterSelfCheck
    /// An error occurred and the depth-2 engine played instead.
    case fallback
}

public struct MoveTimings: Sendable, Hashable, Codable {
    public var prefillMs: Double
    public var timeToFirstTokenMs: Double
    public var decodeTokensPerSecond: Double
    public var totalMs: Double
    public var generatedTokens: Int
    /// False if the static-prefix KV cache could not be reused for this move.
    public var prefixCacheHit: Bool

    public init(
        prefillMs: Double = 0, timeToFirstTokenMs: Double = 0, decodeTokensPerSecond: Double = 0,
        totalMs: Double = 0, generatedTokens: Int = 0, prefixCacheHit: Bool = false
    ) {
        self.prefillMs = prefillMs
        self.timeToFirstTokenMs = timeToFirstTokenMs
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.totalMs = totalMs
        self.generatedTokens = generatedTokens
        self.prefixCacheHit = prefixCacheHit
    }
}

/// The outcome of one AI turn.
public struct AIMove: Sendable, Hashable, Codable {
    public var column: Column
    public var distribution: ColumnDistribution
    /// Deep-think content (without the tags).
    public var thinking: String
    /// Visible reasoning text.
    public var reasoning: String
    public var source: MoveSource
    public var timings: MoveTimings
    /// Before any masking, was the model's top choice a legal column? Nil for non-LLM
    /// providers. Measures whether the model actually understands the board (§3.3.6).
    public var unmaskedTopChoiceLegal: Bool?

    public init(
        column: Column, distribution: ColumnDistribution, thinking: String = "", reasoning: String = "",
        source: MoveSource = .model, timings: MoveTimings = MoveTimings(), unmaskedTopChoiceLegal: Bool? = nil
    ) {
        self.column = column
        self.distribution = distribution
        self.thinking = thinking
        self.reasoning = reasoning
        self.source = source
        self.timings = timings
        self.unmaskedTopChoiceLegal = unmaskedTopChoiceLegal
    }
}

extension AsyncStream where Element == TurnEvent {
    /// Drains the stream and returns the final move, or throws the failure.
    public func finalMove() async throws -> AIMove {
        for await event in self {
            switch event {
            case .decided(let move): return move
            case .failed(let error): throw error
            default: continue
            }
        }
        throw CancellationError()
    }
}

extension Duration {
    /// This duration in milliseconds.
    public var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
