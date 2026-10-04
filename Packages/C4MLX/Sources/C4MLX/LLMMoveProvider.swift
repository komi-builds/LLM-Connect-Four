import C4AI
import C4Core
import Foundation
import Synchronization
import os

/// Errors from loading or running the LLM. Reported to callers as `MoveError` during a
/// turn, and thrown directly from `load(progress:)`.
public enum LLMProviderError: Error, Sendable, CustomStringConvertible {
  case tooLarge(sizeGB: Double)
  case notLoaded
  case rejectedTokenizer(ColumnConstraintError)

  public var description: String {
    switch self {
    case .tooLarge(let size):
      "The model needs about \(size) GB, more than 60% of this Mac's memory, so it won't be loaded."
    case .notLoaded: "The model is not loaded."
    case .rejectedTokenizer(let error): error.description
    }
  }
}

/// The LLM opponent, running in-process with MLX (§3). One generation at a time.
///
/// Turn pipeline: build prompt → reuse the cached static-prefix KV → stream reasoning /
/// thoughts within the budget → append `"Column: "` → one forward step with every logit
/// except the allowed digits set to −∞ → softmax → sample or argmax → `.decided`.
/// Errors are reported as `.failed`; wrap in `FallbackMoveProvider` for the engine fallback.
///
/// Every MLX call is in `MLXSession`; this type only orchestrates tokens. A turn runs
/// synchronously on the actor once started, so turns, loads and unloads never interleave.
public actor LLMMoveProvider: LoadableMoveProvider {
  public let spec: ModelSpec
  public nonisolated var name: String { spec.name }

  /// Reasoning-text sampling (§12): temperature 0.3, top-p 0.9, repetition penalty 1.1.
  public static let reasoningTemperature: Float = 0.3
  public static let reasoningTopP: Float = 0.9
  public static let repetitionPenalty: Float = 1.1

  private let promptBuilder: @Sendable (TurnContext) -> Prompt
  private let modelDirectory: URL?
  private var session: MLXSession?
  private var loading: Task<Void, any Error>?
  /// Milliseconds spent in the last successful load: download + weights, then warm-up.
  public private(set) var lastLoadTimings: (loadMs: Double, warmUpMs: Double)?
  private let logger = Logger(subsystem: "com.komi.LLMConnectFour", category: "llm")

  /// - Parameters:
  ///   - modelDirectory: load from this local folder instead of the Hub (no network).
  ///   - promptBuilder: the prompt source. Production uses `PromptBuilder`; tests and
  ///     tools inject their own.
  public init(
    spec: ModelSpec, modelDirectory: URL? = nil,
    promptBuilder: @escaping @Sendable (TurnContext) -> Prompt = { PromptBuilder.build(for: $0) }
  ) {
    self.spec = spec
    self.modelDirectory = modelDirectory
    self.promptBuilder = promptBuilder
  }

  public var isReady: Bool { session != nil }

  /// The digit tokens found at load time, for diagnostics.
  public var digitTokens: DigitTokenMap? { session?.digits }

  /// The Hub cache folder holding `id`, if it was downloaded before. Pass it as
  /// `modelDirectory` to load with no network access.
  public static func cachedModelDirectory(for id: String) -> URL? {
    MLXSession.cachedSnapshotDirectory(for: id)
  }

  /// Active, peak and cached MLX GPU memory in MB (process-wide), for diagnostics.
  public static func memoryReport() -> (activeMB: Int, peakMB: Int, cacheMB: Int) {
    MLXSession.memoryReport()
  }

  // MARK: Load / unload

  /// Downloads (if needed), loads, discovers digit tokens, prefills and caches the static
  /// system prefix, and runs one throwaway step to compile the Metal kernels.
  public func load(progress: @escaping @Sendable (LoadProgress) -> Void) async throws {
    if session != nil { return }
    if let loading { return try await loading.value }
    let task = Task { try await performLoad(progress: progress) }
    loading = task
    defer { loading = nil }
    try await task.value
  }

  private func performLoad(progress: @escaping @Sendable (LoadProgress) -> Void) async throws {
    if spec.memoryVerdict() == .refuse { throw LLMProviderError.tooLarge(sizeGB: spec.sizeGB) }
    let clock = ContinuousClock()
    let start = clock.now
    progress(LoadProgress(phase: modelDirectory == nil ? .downloading : .loading, fraction: 0))

    let meter = DownloadMeter()
    let loaded: MLXSession
    do {
      loaded = try await MLXSession.load(id: spec.id, directory: modelDirectory) { hub in
        guard let update = meter.update(hub) else { return }
        progress(
          LoadProgress(
            phase: .downloading, fraction: 0.85 * update.fraction, bytesPerSecond: update.rate))
      }
    } catch let error as ColumnConstraintError {
      throw LLMProviderError.rejectedTokenizer(error)
    }
    try Task.checkCancellation()
    let loadedAt = clock.now
    progress(LoadProgress(phase: .warmingUp, fraction: 0.9))
    session = loaded

    do {
      try warmUp(TurnContext(board: Board(), style: .explain, gameSeed: 0))
    } catch {
      session = nil
      loaded.release()
      throw error
    }
    progress(LoadProgress(phase: .ready, fraction: 1))
    lastLoadTimings = ((loadedAt - start).milliseconds, (clock.now - loadedAt).milliseconds)
    logger.info(
      "\(self.spec.id, privacy: .public) ready: load \((loadedAt - start).milliseconds) ms, warm-up \((clock.now - loadedAt).milliseconds) ms"
    )
  }

  public func unload() async {
    loading?.cancel()
    session?.release()
    session = nil
    MLXSession.clearMemory()
  }

  /// Prefills and caches the static prefix for `context`'s variant and style, and runs a
  /// throwaway answer step so the Metal kernels are compiled. Called by `load` for the
  /// default style; the app can call it again when the style or variant changes.
  public func prepare(for context: TurnContext) throws {
    try warmUp(context)
  }

  private func warmUp(_ context: TurnContext) throws {
    guard let session else { throw LLMProviderError.notLoaded }
    let prompt = promptBuilder(context)
    let plan = try plan(for: context, prompt: prompt, session: session)
    let first = try session.startTurn(
      prompt: plan.promptTokens, prefixKey: plan.prefixKey, prefixTokens: plan.prefixTokens,
      seed: 0,
      reasoningTemperature: Self.reasoningTemperature, topP: Self.reasoningTopP,
      repetitionPenalty: Self.repetitionPenalty)
    // One single-token decode step and one multi-token step compile the remaining kernels.
    let token = session.sampleReasoningToken(first.logits)
    _ = try session.feed([token])
    _ = session.digitLogits(try session.feed(session.encode("\n" + session.digits.answerPrefix)))
    session.endTurn()
  }

  /// Token counts for `context`'s prompt: the cached static prefix and the whole prompt
  /// (including the forced answer prefix for Instinct). For diagnostics and the bench.
  public func promptTokenCounts(for context: TurnContext) throws -> (prefix: Int, total: Int) {
    guard let session else { throw LLMProviderError.notLoaded }
    let plan = try plan(for: context, prompt: promptBuilder(context), session: session)
    return (plan.prefixTokens.count, plan.promptTokens.count)
  }

  // MARK: Moves

  public nonisolated func move(_ context: TurnContext) -> AsyncStream<TurnEvent> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: TurnEvent.self, bufferingPolicy: .unbounded)
    let task = Task { await self.play(context, continuation: continuation) }
    continuation.onTermination = { _ in task.cancel() }
    return stream
  }

  private func play(_ context: TurnContext, continuation: AsyncStream<TurnEvent>.Continuation) {
    defer { continuation.finish() }
    let prompt = promptBuilder(context)
    continuation.yield(.prompt(prompt))
    do {
      let move = try runTurn(context, prompt: prompt) { continuation.yield($0) }
      continuation.yield(.distribution(move.distribution))
      continuation.yield(.decided(move))
    } catch is CancellationError {
      continuation.yield(.failed(MoveError("Cancelled")))
    } catch let error as MoveError {
      continuation.yield(.failed(error))
    } catch {
      logger.error("turn failed: \(String(describing: error), privacy: .public)")
      continuation.yield(.failed(MoveError(String(describing: error))))
    }
    session?.endTurn()
  }

  /// The token layout of one turn.
  private struct TurnPlan {
    var promptTokens: [Int]
    var prefixTokens: [Int]
    var prefixKey: String
    /// Deep think on a model that supports it.
    var deepThink: Bool
    var thinkTags: (open: String, close: String)?
  }

  private func templateArgs(deepThink: Bool) -> [String: any Sendable] {
    var args: [String: any Sendable] = [:]
    for (key, value) in spec.chatTemplateArgs ?? [:] {
      switch value {
      case "$deepThink": args[key] = deepThink
      case "true": args[key] = true
      case "false": args[key] = false
      default: args[key] = value
      }
    }
    return args
  }

  private func plan(for context: TurnContext, prompt: Prompt, session: MLXSession) throws
    -> TurnPlan
  {
    let deepThink = context.style == .deepThink && spec.thinking
    let args = templateArgs(deepThink: deepThink)
    let argsKey = args.keys.sorted().map { "\($0)=\(args[$0]!)" }.joined(separator: ",")
    let prefixKey = argsKey + "\u{1F}" + prompt.system
    var tokens = try session.chatTokens(
      system: prompt.system, user: prompt.user, templateArgs: args)
    let prefix = try session.staticPrefixTokens(
      key: prefixKey, system: prompt.system, templateArgs: args)

    var tags: (open: String, close: String)?
    if let thinkTags = spec.thinkTags, thinkTags.count == 2 { tags = (thinkTags[0], thinkTags[1]) }
    // Is a think block left open by the generation prompt (thinking-only templates)?
    var openThink = false
    if let tags {
      let tail = session.decode(Array(tokens.suffix(12)))
      if let open = tail.range(of: tags.open, options: .backwards) {
        openThink = tail.range(of: tags.close, range: open.upperBound..<tail.endIndex) == nil
      }
    }
    if let tags, deepThink, !openThink {
      tokens += session.encode(tags.open + "\n")
    } else if let tags, !deepThink, openThink {
      tokens += session.encode("\n" + tags.close + "\n\n")
    }
    if context.style == .instinct {
      tokens += session.encode(session.digits.answerPrefix)
    }
    return TurnPlan(
      promptTokens: tokens, prefixTokens: prefix, prefixKey: prefixKey, deepThink: deepThink,
      thinkTags: tags)
  }

  private enum Phase { case thinking, reasoning }

  /// Runs one turn synchronously. Throws on error or cancellation.
  private func runTurn(_ context: TurnContext, prompt: Prompt, emit: (TurnEvent) -> Void) throws
    -> AIMove
  {
    guard let session else { throw LLMProviderError.notLoaded }
    guard !prompt.allowedColumns.isEmpty else { throw MoveError("No allowed columns") }
    try Task.checkCancellation()
    let clock = ContinuousClock()
    let start = clock.now
    let plan = try plan(for: context, prompt: prompt, session: session)
    let first = try session.startTurn(
      prompt: plan.promptTokens, prefixKey: plan.prefixKey, prefixTokens: plan.prefixTokens,
      seed: context.seed, reasoningTemperature: Self.reasoningTemperature, topP: Self.reasoningTopP,
      repetitionPenalty: Self.repetitionPenalty)
    var timings = MoveTimings(prefillMs: first.prefillMs, prefixCacheHit: first.prefixHit)

    var answerLogits = first.logits
    var thinking = ""
    var reasoning = ""
    if context.style != .instinct {
      let result = try generate(
        context: context, plan: plan, session: session, logits: first.logits, emit: emit,
        clock: clock,
        start: start)
      answerLogits = result.logits
      thinking = result.thinking
      reasoning = result.reasoning
      timings.generatedTokens = result.generated
      timings.timeToFirstTokenMs = result.firstTokenMs
      timings.decodeTokensPerSecond = result.tokensPerSecond
    }
    try Task.checkCancellation()

    let digitLogits = session.digitLogits(answerLogits)
    let topLegal = ColumnConstraint.unmaskedTopChoiceLegal(
      digitLogits: digitLogits, board: context.board)
    let distribution = ColumnDistribution.softmax(
      logits: digitLogits, allowed: prompt.allowedColumns)
    var rng = SplitMix64(seed: context.seed)
    let column = distribution.sample(temperature: context.profile.columnTemperature, using: &rng)
    timings.totalMs = (clock.now - start).milliseconds
    if context.style == .instinct { timings.timeToFirstTokenMs = timings.totalMs }
    return AIMove(
      column: column, distribution: distribution, thinking: thinking, reasoning: reasoning,
      source: .model,
      timings: timings, unmaskedTopChoiceLegal: topLegal)
  }

  private struct Generation {
    var logits: Logits
    var thinking: String
    var reasoning: String
    var generated: Int
    var firstTokenMs: Double
    var tokensPerSecond: Double
  }

  /// Streams thoughts and/or reasoning within the budgets, then forces the answer prefix.
  /// Returns the logits at the answer position.
  private func generate(
    context: TurnContext, plan: TurnPlan, session: MLXSession, logits initial: Logits,
    emit: (TurnEvent) -> Void, clock: ContinuousClock, start: ContinuousClock.Instant
  ) throws -> Generation {
    let marker = "Column:"
    let answer = session.encode(session.digits.answerPrefix)
    let closeTag = plan.thinkTags?.close ?? "</think>"
    // Deep think: thoughts use the context budget, then Explain's budget for reasoning.
    // Other styles (including Deep think on a non-thinking model): reasoning only, with
    // the context budget (§2: "fall back to Explain with a longer budget").
    var phase: Phase = plan.deepThink ? .thinking : .reasoning
    var budget = max(1, context.thinkingBudget)
    let reasoningBudget = plan.deepThink ? ThinkingStyle.explain.defaultBudget : budget

    var logits = initial
    var fed: [Int] = []  // every token fed after the prompt
    var phaseTokens: [Int] = []  // tokens of the current phase, including an unfed last one
    var thinking = ""
    var reasoning = ""
    var emittedReasoning = 0  // characters of `reasoning` already emitted
    var emittedThinking = 0
    var generated = 0
    var firstToken: ContinuousClock.Instant?

    func emitReasoning(final: Bool) {
      // Hold back a tail that could be the start of "Column:" so it never flickers in.
      var hold = 0
      if !final {
        for k in stride(from: min(marker.count, reasoning.count), through: 1, by: -1)
        where reasoning.hasSuffix(marker.prefix(k)) {
          hold = k
          break
        }
      }
      let end = reasoning.count - hold
      if end > emittedReasoning {
        let delta = String(reasoning.dropFirst(emittedReasoning).prefix(end - emittedReasoning))
        emit(.reasoningToken(delta))
        emittedReasoning = end
      }
    }

    while true {
      try Task.checkCancellation()
      let token = session.sampleReasoningToken(logits)
      if firstToken == nil { firstToken = clock.now }

      if session.stopTokens.contains(token) {
        // The model ended its turn without answering: close what is open and answer.
        var tail: [Int] = []
        if phase == .thinking { tail += session.encode("\n" + closeTag + "\n\n") }
        if !reasoning.isEmpty && !reasoning.hasSuffix("\n") { tail += session.encode("\n") }
        logits = try session.feed(tail + answer)
        fed += tail + answer
        break
      }
      generated += 1
      phaseTokens.append(token)
      let text = session.decode(phaseTokens)

      if phase == .thinking {
        if let close = text.range(of: closeTag) {
          thinking = String(text[..<close.lowerBound])
          if thinking.count > emittedThinking {
            emit(.thinkingToken(String(thinking.dropFirst(emittedThinking))))
            emittedThinking = thinking.count
          }
          thinking = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
          // Reasoning starts after the tag; feed this token and continue.
          logits = try session.feed([token])
          fed.append(token)
          phase = .reasoning
          phaseTokens = []
          budget = reasoningBudget
          continue
        }
        let visible = text.replacingOccurrences(of: plan.thinkTags?.open ?? "<think>", with: "")
        if visible.count > emittedThinking {
          emit(.thinkingToken(String(visible.dropFirst(emittedThinking))))
          emittedThinking = visible.count
        }
        thinking = visible
        if phaseTokens.count >= budget {
          // Budget hit: close the tag ourselves and move on to reasoning.
          let tail = [token] + session.encode("\n" + closeTag + "\n\n")
          logits = try session.feed(tail)
          fed += tail
          thinking = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
          phase = .reasoning
          phaseTokens = []
          budget = reasoningBudget
          continue
        }
        logits = try session.feed([token])
        fed.append(token)
        continue
      }

      // Reasoning phase.
      if let markerRange = text.range(of: marker) {
        // The model is answering itself. Stop here and force the answer prefix;
        // its digit text is never trusted, the masked step decides.
        let kept = String(text[..<markerRange.lowerBound])
        reasoning = kept
        // Longest run of this phase's tokens whose text is a prefix of `kept`.
        var keep = phaseTokens.count - 1
        while keep > 0, !kept.hasPrefix(session.decode(Array(phaseTokens.prefix(keep)))) {
          keep -= 1
        }
        let extra = String(kept.dropFirst(session.decode(Array(phaseTokens.prefix(keep))).count))
        let alreadyFed = phaseTokens.count - 1
        let drop = alreadyFed - keep
        let suffix = (extra.isEmpty ? [] : session.encode(extra)) + answer
        if drop > 0 && !session.canTrim {
          let base = plan.promptTokens + fed.dropLast(drop)
          logits = try session.restart(with: Array(base) + suffix)
        } else {
          session.trim(drop)
          logits = try session.feed(suffix)
        }
        break
      }
      reasoning = text
      emitReasoning(final: false)
      if phaseTokens.count >= budget {
        let newline = reasoning.hasSuffix("\n") ? [] : session.encode("\n")
        logits = try session.feed([token] + newline + answer)
        break
      }
      logits = try session.feed([token])
      fed.append(token)
    }
    emitReasoning(final: true)
    let end = clock.now
    let firstMs = firstToken.map { ($0 - start).milliseconds } ?? 0
    let decodeSeconds = firstToken.map { ($0.duration(to: end)).milliseconds / 1000 } ?? 0
    return Generation(
      logits: logits, thinking: thinking,
      reasoning: reasoning.trimmingCharacters(in: .whitespacesAndNewlines),
      generated: generated, firstTokenMs: firstMs,
      tokensPerSecond: decodeSeconds > 0 ? Double(max(0, generated - 1)) / decodeSeconds : 0)
  }
}

/// Turns the Hub's byte-based `Progress` into a fraction and a smoothed bytes-per-second.
private final class DownloadMeter: Sendable {
  private struct State {
    var lastBytes: Int64 = 0
    var lastTime: ContinuousClock.Instant?
    var rate: Double?
  }
  private let state = Mutex(State())

  func update(_ progress: Progress) -> (fraction: Double, rate: Double?)? {
    let total = progress.totalUnitCount
    guard total > 0 else { return nil }
    // The Hub's snapshot progress is a parent whose children are files weighted by
    // byte size. A parent's `completedUnitCount` only moves when a whole file finishes;
    // in-flight bytes show up only in `fractionCompleted`.
    let fraction = min(1, max(0, progress.fractionCompleted))
    let done = Int64(fraction * Double(total))
    let now = ContinuousClock.now
    let rate: Double? = state.withLock { s in
      if let last = s.lastTime {
        let seconds = (now - last).milliseconds / 1000
        if seconds >= 0.5 {
          let instant = Double(done - s.lastBytes) / seconds
          s.rate = s.rate.map { 0.6 * $0 + 0.4 * instant } ?? instant
          s.lastBytes = done
          s.lastTime = now
        }
      } else {
        s.lastBytes = done
        s.lastTime = now
      }
      return s.rate
    }
    // No speed for a cached snapshot (1/1) or once everything has arrived.
    return (fraction, total > 1 && fraction < 1 ? rate : nil)
  }
}
