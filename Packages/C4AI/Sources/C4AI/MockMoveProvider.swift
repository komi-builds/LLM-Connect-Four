import C4Core
import Foundation

/// A stand-in for the LLM. Emits a fake prompt, fake thinking/reasoning tokens, a drifting
/// distribution and a move, on a timer. The UI and the bench are built against this and
/// never wait for MLX. Deterministic for a given context seed.
public struct MockMoveProvider: LoadableMoveProvider {
  public var name: String
  /// Delay between streamed tokens.
  public var tokenDelay: Duration
  /// Simulated load time.
  public var loadDuration: Duration
  /// If set, every turn fails with this message (to exercise the fallback path).
  public var failure: String?

  public init(
    name: String = "Mock Model", tokenDelay: Duration = .milliseconds(30),
    loadDuration: Duration = .seconds(2), failure: String? = nil
  ) {
    self.name = name
    self.tokenDelay = tokenDelay
    self.loadDuration = loadDuration
    self.failure = failure
  }

  public var isReady: Bool { get async { true } }

  public func load(progress: @escaping @Sendable (LoadProgress) -> Void) async throws {
    let steps = 20
    for step in 0...steps {
      try await Task.sleep(for: loadDuration / steps)
      let fraction = Double(step) / Double(steps)
      let phase: LoadProgress.Phase =
        fraction < 0.6 ? .downloading : fraction < 0.9 ? .loading : .warmingUp
      progress(
        LoadProgress(
          phase: phase, fraction: fraction, bytesPerSecond: phase == .downloading ? 42e6 : nil))
    }
    progress(LoadProgress(phase: .ready, fraction: 1))
  }

  public func unload() async {}

  public func move(_ context: TurnContext) -> AsyncStream<TurnEvent> {
    let provider = self
    return AsyncStream { continuation in
      let task = Task {
        await provider.run(context, continuation)
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func run(_ context: TurnContext, _ out: AsyncStream<TurnEvent>.Continuation) async {
    let start = ContinuousClock.now
    var rng = SplitMix64(seed: context.seed)
    let board = context.board
    let allowed = board.legalMoves
    guard !allowed.isEmpty else {
      out.yield(.failed(MoveError("no legal moves")))
      return
    }

    out.yield(.prompt(Self.fakePrompt(board: board, allowed: allowed, variant: context.variant)))

    // Centre-leaning random logits, re-drawn as "thinking" progresses.
    func logits() -> [Double] {
      Board.allColumns.map { 1.5 - Double(abs($0 - 3)) * 0.4 + rng.nextUnit() * 1.5 }
    }
    var distribution = ColumnDistribution.softmax(logits: logits(), allowed: allowed)
    out.yield(.distribution(distribution))

    var thinking = ""
    var reasoning = ""
    var tokens = 0
    let words: [String]
    switch context.style {
    case .instinct: words = []
    case .explain: words = Self.reasoningWords
    case .deepThink: words = Self.thinkingWords + Self.reasoningWords
    }
    let thinkingCount = context.style == .deepThink ? Self.thinkingWords.count : 0

    for (index, word) in words.enumerated() {
      do { try await Task.sleep(for: tokenDelay) } catch { return }
      let token = word + " "
      tokens += 1
      if index < thinkingCount {
        thinking += token
        out.yield(.thinkingToken(token))
      } else {
        reasoning += token
        out.yield(.reasoningToken(token))
      }
      if index % 6 == 5 {
        distribution = ColumnDistribution.softmax(logits: logits(), allowed: allowed)
        out.yield(.distribution(distribution))
      }
    }

    if let failure {
      out.yield(.failed(MoveError(failure)))
      return
    }
    if Task.isCancelled { return }

    let column = distribution.sample(temperature: context.profile.columnTemperature, using: &rng)
    let totalMs = (ContinuousClock.now - start).milliseconds
    let timings = MoveTimings(
      prefillMs: 40, timeToFirstTokenMs: 60, decodeTokensPerSecond: tokens > 0 ? 38 : 0,
      totalMs: totalMs,
      generatedTokens: tokens, prefixCacheHit: true)
    out.yield(
      .decided(
        AIMove(
          column: column, distribution: distribution,
          thinking: thinking.trimmingCharacters(in: .whitespaces),
          reasoning: reasoning.trimmingCharacters(in: .whitespaces), source: .model,
          timings: timings,
          unmaskedTopChoiceLegal: true)))
  }

  static let thinkingWords =
    "Okay, let me look at the board. X has two in the middle, so I should watch the diagonal. If I play the centre I keep options open on both sides. Column 4 lands on row 2, which does not give X a square on row 3."
    .split(separator: " ").map(String.init)
  static let reasoningWords =
    "The centre column keeps the most lines open and no immediate threat needs blocking, so I build there."
    .split(separator: " ").map(String.init)

  static func fakePrompt(board: Board, allowed: [Column], variant: PromptVariant) -> Prompt {
    let rows = (0..<Board.rowCount).reversed().map { row in
      "\(row + 1)  "
        + Board.allColumns.map {
          BoardEncoder.symbol(board.disc(atColumn: $0, row: row), sideToMove: board.toMove)
        }.joined(separator: " ")
    }
    let user =
      (["Board (row 6 at top):", "   1 2 3 4 5 6 7"] + rows + [
        "", "Legal columns: " + allowed.map(BoardEncoder.label).joined(separator: " "),
      ]).joined(separator: "\n")
    return Prompt(
      system: "You are an expert Connect Four player. You are O. Your opponent is X. (mock prompt)",
      user: user, facts: [], allowedColumns: allowed, variantID: variant.id, version: 0)
  }
}
