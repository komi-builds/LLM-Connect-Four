import C4AI
import C4Core
import Foundation
import Observation
import os

let gameLog = Logger(subsystem: "com.komi.LLMConnectFour", category: "game")

/// The game loop: human moves, async AI turn, cancellation (§1).
///
/// The human always moves first. The AI turn starts the moment the human's disc lands and
/// runs as a cancellable `Task` that consumes the provider's `TurnEvent` stream. If the
/// provider must be loaded, loading starts at launch; a human move made before it is ready
/// waits ("Warming up… 63%") and then plays.
@MainActor
@Observable
final class GameViewModel {
  /// Live state of the current (or most recent) AI turn, shown in the Thinking panel.
  struct AITurn: Equatable {
    /// Ply of the AI move this turn produces.
    var ply: Int
    var prompt: Prompt?
    var thinking = ""
    var reasoning = ""
    var thinkingTokens = 0
    var reasoningTokens = 0
    var distribution: ColumnDistribution?
    var move: AIMove?
    var error: String?

    var isStreaming: Bool { move == nil && error == nil }
  }

  enum Status: Equatable {
    case humanTurn
    case warmingUp
    case aiThinking
    case gameOver(GameOutcome)
  }

  // MARK: Game state

  private(set) var board = Board()
  let humanDisc: Disc = .first
  var aiDisc: Disc { humanDisc.opponent }
  private(set) var record: GameRecord
  private(set) var aiTurn: AITurn?
  /// Ply of the most recent drop, used by the view to animate only the newest disc.
  private(set) var lastDropPly: Int?

  // MARK: Provider and loading

  /// The model provider for the selected model (the MLX LLM in the app, a mock in tests).
  /// Rebuilt by `providerFactory` when the model changes between games.
  private(set) var provider: any MoveProvider
  /// Hugging Face id recorded in traces; nil for non-LLM providers.
  private(set) var providerModelID: String?
  @ObservationIgnored private let providerFactory: @MainActor (ModelSpec) -> any MoveProvider
  private(set) var loadProgress: LoadProgress?
  private(set) var isModelReady: Bool
  private(set) var loadError: String?
  /// True while a human move is waiting for the model to finish loading.
  private(set) var isWaitingForModel = false

  // MARK: Settings (changeable only between games)

  /// Who the human plays: the language model, or the minimax engine as a non-LLM reference.
  enum Opponent: String, CaseIterable, Identifiable {
    case model, engine
    var id: String { rawValue }
  }

  /// Models from `models.json`, then custom ids added in Settings.
  var models: [ModelSpec] { bundledModels + customModelIDs.map(ModelSpec.custom(id:)) }
  @ObservationIgnored private let bundledModels: [ModelSpec]

  var difficulty: Difficulty {
    didSet {
      defaults.set(difficulty.rawValue, forKey: Keys.difficulty)
    }
  }
  var style: ThinkingStyle {
    didSet {
      defaults.set(style.rawValue, forKey: Keys.style)
      if oldValue != style { prepareProvider() }
    }
  }
  var selectedModelID: String? {
    didSet {
      defaults.set(selectedModelID, forKey: Keys.model)
      if style == .deepThink, !canDeepThink { style = .explain }
      if isConfigured, oldValue != selectedModelID { switchModel() }
    }
  }
  var showThinking: Bool {
    didSet { defaults.set(showThinking, forKey: Keys.showThinking) }
  }
  var opponent: Opponent {
    didSet {
      defaults.set(opponent.rawValue, forKey: Keys.opponent)
      if isConfigured, oldValue != opponent { newGame() }
    }
  }
  /// Token budget for Deep think thoughts (§12: 128 to 2048, default 512).
  var deepThinkBudget: Int {
    didSet { defaults.set(deepThinkBudget, forKey: Keys.deepThinkBudget) }
  }
  /// Extra `mlx-community/...` ids typed in Settings.
  var customModelIDs: [String] {
    didSet { defaults.set(customModelIDs, forKey: Keys.customModels) }
  }

  /// Minimum time between the human's drop and the AI's drop, so the human's disc
  /// finishes its animation first. Zero in tests.
  @ObservationIgnored var minimumAIDelay: Duration
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var aiTask: Task<Void, Never>?
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var turnToken = 0
  private(set) var isAITurnActive = false
  /// Where finished games are saved. Nil (the default) saves nothing, so tests stay clean;
  /// the app sets `GameStore.default`.
  @ObservationIgnored var gameStore: GameStore?

  @ObservationIgnored private var isConfigured = false
  /// Bumped on every model switch, so a late load result for an old provider is ignored.
  @ObservationIgnored private var providerGeneration = 0

  private enum Keys {
    static let difficulty = "difficulty"
    static let style = "thinkingStyle"
    static let model = "modelID"
    static let showThinking = "showThinking"
    static let opponent = "opponent"
    static let deepThinkBudget = "deepThinkBudget"
    static let customModels = "customModelIDs"
  }

  /// - Parameters:
  ///   - provider: a fixed provider to start with (tests). Nil builds one for the selected
  ///     model with `providerFactory`.
  ///   - providerFactory: makes the provider for a model. The app passes the MLX LLM; the
  ///     default is the mock, so previews and tests never load a model.
  init(
    provider: (any MoveProvider)? = nil,
    providerModelID: String? = nil,
    providerFactory: @escaping @MainActor (ModelSpec) -> any MoveProvider = {
      MockMoveProvider(name: $0.name)
    },
    models: [ModelSpec] = ModelRegistry.bundled(),
    defaults: UserDefaults = .standard,
    minimumAIDelay: Duration = .milliseconds(450),
    loadImmediately: Bool = true
  ) {
    self.providerFactory = providerFactory
    self.bundledModels = models
    self.defaults = defaults
    self.minimumAIDelay = minimumAIDelay
    let customIDs = defaults.stringArray(forKey: Keys.customModels) ?? []
    let allModels = models + customIDs.map(ModelSpec.custom(id:))
    let difficulty =
      defaults.string(forKey: Keys.difficulty).flatMap(Difficulty.init(rawValue:)) ?? .moderate
    let style =
      defaults.string(forKey: Keys.style).flatMap(ThinkingStyle.init(rawValue:)) ?? .explain
    let storedModel = defaults.string(forKey: Keys.model)
    let selected =
      allModels.first(where: { $0.id == storedModel })
      ?? allModels.first(where: \.isDefault) ?? allModels.first
    self.customModelIDs = customIDs
    self.difficulty = difficulty
    self.style = style
    self.selectedModelID = selected?.id
    self.showThinking = defaults.object(forKey: Keys.showThinking) as? Bool ?? true
    self.opponent =
      defaults.string(forKey: Keys.opponent).flatMap(Opponent.init(rawValue:)) ?? .model
    let budget = defaults.integer(forKey: Keys.deepThinkBudget)
    self.deepThinkBudget =
      ThinkingStyle.deepThinkBudgetRange.contains(budget)
      ? budget : ThinkingStyle.deepThink.defaultBudget

    let initial: any MoveProvider
    if let provider {
      initial = provider
      self.providerModelID = providerModelID
    } else if let selected {
      initial = providerFactory(selected)
      self.providerModelID = selected.id
    } else {
      initial = MockMoveProvider()
      self.providerModelID = nil
    }
    self.provider = initial
    self.isModelReady = !(initial is any LoadableMoveProvider)
    let seed = UInt64.random(in: .min ... .max)
    self.record = GameRecord(
      opponentName: initial.name, modelID: providerModelID, style: style, difficulty: difficulty,
      variantID: PromptVariant.default.id, gameSeed: seed)
    if self.style == .deepThink, !canDeepThink { self.style = .explain }
    record.opponentName = opponentName
    record.modelID = traceModelID
    isConfigured = true
    if loadImmediately { startLoading() }
  }

  // MARK: Derived state

  var gameSeed: UInt64 { record.gameSeed }
  var selectedModel: ModelSpec? { models.first { $0.id == selectedModelID } }
  /// Deep think needs a model with native thinking. Without a registry, allow it.
  var canDeepThink: Bool { selectedModel?.thinking ?? true }
  /// The style actually sent to the provider.
  var effectiveStyle: ThinkingStyle { style == .deepThink && !canDeepThink ? .explain : style }

  var isHumanTurn: Bool { !board.isGameOver && board.toMove == humanDisc && !isAITurnActive }
  var isGameInProgress: Bool { board.plyCount > 0 && !board.isGameOver }
  var canChangeSettings: Bool { !isGameInProgress && !isAITurnActive }
  var winningCells: Set<Cell> { board.winningCells ?? [] }
  /// The AI is producing tokens right now (pauses the background drift).
  var isAIStreaming: Bool { isAITurnActive && !isWaitingForModel }

  var status: Status {
    if let outcome = board.outcome { return .gameOver(outcome) }
    if isWaitingForModel { return .warmingUp }
    if isAITurnActive { return .aiThinking }
    return .humanTurn
  }

  func canDrop(_ column: Column) -> Bool { isHumanTurn && board.canPlay(column) }

  /// Display name for the opponent: the engine, the selected model, or the provider.
  var opponentName: String {
    switch opponent {
    case .engine: "Minimax d\(DifficultyProfile.profile(for: difficulty).engineDepth)"
    case .model: selectedModel?.name ?? provider.name
    }
  }

  /// The model id recorded in traces: nil when the engine plays.
  var traceModelID: String? { opponent == .engine ? nil : providerModelID }

  /// The settings a turn would use right now, on the empty board.
  private func turnContext(on board: Board, gameSeed: UInt64) -> TurnContext {
    let budget: Int? =
      switch (style, canDeepThink) {
      case (.deepThink, true): deepThinkBudget
      // Models that can't think fall back to Explain with a longer budget (§2).
      case (.deepThink, false): ThinkingStyle.explain.defaultBudget * 2
      default: nil
      }
    return TurnContext(
      board: board, style: effectiveStyle, profile: .profile(for: difficulty), variant: .default,
      thinkingBudget: budget, gameSeed: gameSeed)
  }

  // MARK: Loading

  /// Starts loading a `LoadableMoveProvider` in the background, after unloading `previous`
  /// (so two models are never resident at once). Safe to call again.
  func startLoading(unloading previous: (any LoadableMoveProvider)? = nil) {
    guard let loadable = provider as? any LoadableMoveProvider, loadTask == nil, !isModelReady
    else { return }
    loadError = nil
    loadProgress = LoadProgress(phase: .loading, fraction: 0)
    gameLog.info("loading provider \(loadable.name, privacy: .public)")
    let context = turnContext(on: Board(), gameSeed: 0)
    let generation = providerGeneration
    loadTask = Task {
      do {
        await previous?.unload()
        // The load is finite, so holding `self` until it ends is fine.
        try await loadable.load { progress in
          Task { @MainActor in self.receive(progress, generation: generation) }
        }
        try Task.checkCancellation()
        guard generation == self.providerGeneration else { return }
        // Warm the prefix for the current style so the first move doesn't pay for it.
        try? await loadable.prepare(for: context)
        self.isModelReady = true
        self.loadProgress = LoadProgress(phase: .ready, fraction: 1)
        gameLog.info("provider ready")
      } catch is CancellationError {
        gameLog.info("load cancelled")
      } catch {
        guard generation == self.providerGeneration else { return }
        self.loadError = String(describing: error)
        self.loadTask = nil
        gameLog.error("load failed: \(String(describing: error), privacy: .public)")
      }
    }
  }

  /// Replaces the provider with one for the newly selected model and loads it. Only reachable
  /// between games, because the model menu is disabled during one.
  private func switchModel() {
    guard let spec = selectedModel else { return }
    cancelAITurn()
    loadTask?.cancel()
    loadTask = nil
    let previous = provider as? any LoadableMoveProvider
    providerGeneration += 1
    provider = providerFactory(spec)
    providerModelID = spec.id
    isModelReady = !(provider is any LoadableMoveProvider)
    loadProgress = nil
    loadError = nil
    gameLog.info("switching model to \(spec.id, privacy: .public)")
    newGame()
    if previous != nil || !isModelReady { startLoading(unloading: previous) }
  }

  /// Warms the static prefix for the current style, in the background.
  private func prepareProvider() {
    guard isConfigured, isModelReady, let loadable = provider as? any LoadableMoveProvider else {
      return
    }
    let context = turnContext(on: Board(), gameSeed: 0)
    Task { try? await loadable.prepare(for: context) }
  }

  private func receive(_ progress: LoadProgress, generation: Int) {
    guard !isModelReady, generation == providerGeneration else { return }
    // Progress callbacks hop to the main actor independently; never go backwards.
    if let current = loadProgress, progress.fraction < current.fraction { return }
    loadProgress = progress
  }

  // MARK: Moves

  /// The human drops a disc. Ignored unless it is the human's turn and the column is open.
  func humanDrop(_ column: Column) {
    guard canDrop(column) else { return }
    apply(column)
    if !board.isGameOver { startAITurn() }
  }

  /// Cancels any AI turn and starts a fresh game with the current settings.
  func newGame() {
    cancelAITurn()
    // An abandoned game is worth keeping once the model has played in it.
    if record.outcome == nil, !record.traces.isEmpty { saveRecord() }
    board = Board()
    aiTurn = nil
    lastDropPly = nil
    record = GameRecord(
      opponentName: opponentName, modelID: traceModelID, style: effectiveStyle,
      difficulty: difficulty,
      variantID: PromptVariant.default.id, gameSeed: UInt64.random(in: .min ... .max))
    gameLog.info("new game")
  }

  /// Waits for the running AI turn, if any (for tests and scripted demos).
  func waitForAITurn() async {
    await aiTask?.value
  }

  private func apply(_ column: Column) {
    if board.plyCount == 0 {
      // Settings are locked from the first move on, so stamp them now.
      record.startedAt = Date()
      record.style = effectiveStyle
      record.difficulty = difficulty
      record.opponentName = opponentName
      record.modelID = traceModelID
    }
    board.drop(column)
    lastDropPly = board.plyCount - 1
    record.moves = board.moves
    if let outcome = board.outcome {
      record.outcome = outcome
      record.finishedAt = Date()
      gameLog.info(
        "game over after \(self.board.plyCount) plies: \(String(describing: outcome), privacy: .public)"
      )
      saveRecord()
    }
  }

  private func saveRecord() {
    guard let gameStore else { return }
    do { try gameStore.save(record) } catch {
      gameLog.error("saving game failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func cancelAITurn() {
    turnToken += 1
    aiTask?.cancel()
    aiTask = nil
    isAITurnActive = false
    isWaitingForModel = false
  }

  private func startAITurn() {
    let context = turnContext(on: board, gameSeed: gameSeed)
    turnToken += 1
    let token = turnToken
    let started = ContinuousClock.now
    let usesModel = opponent == .model
    aiTurn = AITurn(ply: board.plyCount)
    isAITurnActive = true
    isWaitingForModel = usesModel && !isModelReady
    // Errors (never bad output) become a depth-2 engine move with `source: .fallback`.
    let turnProvider: any MoveProvider =
      usesModel
      ? Self.withFallback(provider) : EngineMoveProvider(depth: context.profile.engineDepth)
    aiTask = Task { [weak self] in
      await self?.runAITurn(context, provider: turnProvider, token: token, started: started)
    }
  }

  private static func withFallback<P: MoveProvider>(_ provider: P) -> any MoveProvider {
    FallbackMoveProvider(provider)
  }

  private func runAITurn(
    _ context: TurnContext, provider turnProvider: any MoveProvider, token: Int,
    started: ContinuousClock.Instant
  ) async {
    // Wait for the model if the human was quicker than the load.
    if isWaitingForModel {
      if loadTask == nil { startLoading() }
      await loadTask?.value
      guard token == turnToken, !Task.isCancelled else { return }
      isWaitingForModel = false
      if !isModelReady {
        // The load failed: stop here and let the banner offer Retry.
        isAITurnActive = false
        aiTask = nil
        aiTurn = nil
        return
      }
    }

    var traceContext = context
    var decided = await attempt(context, with: turnProvider, token: token)
    guard token == turnToken, !Task.isCancelled else { return }

    // Hard: if the model missed an immediate win or block, ask once more (§3.5).
    if let first = decided,
      let (recheck, blunder) = SelfCheck.recheck(after: first, context: context)
    {
      let what = blunder == .missedWin ? "missed an immediate win" : "missed a forced block"
      let note = "Self-check: column \(first.column + 1) \(what), so the model was asked again."
      aiTurn?.thinking = ""
      aiTurn?.reasoning = note + "\n\n"
      aiTurn?.thinkingTokens = 0
      aiTurn?.reasoningTokens = 0
      gameLog.info("self-check after \(blunder.rawValue, privacy: .public)")
      if var again = await attempt(recheck, with: turnProvider, token: token) {
        if again.source == .model { again.source = .modelAfterSelfCheck }
        again.timings.totalMs += first.timings.totalMs
        again.timings.generatedTokens += first.timings.generatedTokens
        decided = again
        traceContext = recheck
      }
      guard token == turnToken, !Task.isCancelled else { return }
    }

    var move: AIMove
    if let decided, board.canPlay(decided.column) {
      move = decided
    } else {
      // Defensive only: the mask makes an unplayable answer impossible.
      move = Self.fallbackMove(on: board, reasoning: aiTurn?.reasoning ?? "")
    }

    let elapsed = ContinuousClock.now - started
    if elapsed < minimumAIDelay {
      try? await Task.sleep(for: minimumAIDelay - elapsed)
      guard token == turnToken, !Task.isCancelled else { return }
    }

    record.traces.append(
      MoveTrace(
        context: traceContext, provider: turnProvider.name, modelID: traceModelID,
        prompt: aiTurn?.prompt, move: move))
    aiTurn?.move = move
    aiTurn?.distribution = move.distribution
    isAITurnActive = false
    aiTask = nil
    apply(move.column)
  }

  /// Streams one attempt into `aiTurn` and returns its move, or nil if it failed or the turn
  /// is no longer current.
  private func attempt(_ context: TurnContext, with turnProvider: any MoveProvider, token: Int)
    async -> AIMove?
  {
    var decided: AIMove?
    for await event in turnProvider.move(context) {
      guard token == turnToken, !Task.isCancelled else { return nil }
      switch event {
      case .prompt(let prompt):
        aiTurn?.prompt = prompt
      case .thinkingToken(let text):
        aiTurn?.thinking += text
        aiTurn?.thinkingTokens += 1
      case .reasoningToken(let text):
        aiTurn?.reasoning += text
        aiTurn?.reasoningTokens += 1
      case .distribution(let distribution):
        aiTurn?.distribution = distribution
      case .decided(let move):
        decided = move
      case .failed(let error):
        aiTurn?.error = error.message
        gameLog.error("AI turn failed: \(error.message, privacy: .public)")
      }
    }
    return decided
  }

  /// The depth-2 engine's move with `source: .fallback`.
  static func fallbackMove(on board: Board, reasoning: String) -> AIMove {
    let legal = board.legalMoves
    let column = Engine(depth: 2).bestMove(board)
    var probabilities = [Double](repeating: 0, count: Board.columnCount)
    probabilities[column] = 1
    let distribution = ColumnDistribution(
      probabilities: probabilities, masked: Set(Board.allColumns).subtracting(legal))
    return AIMove(
      column: column, distribution: distribution, reasoning: reasoning, source: .fallback)
  }

  #if DEBUG
    /// Sets up a finished position for screenshots and previews. Not a game action.
    func setPosition(_ moves: [Column], aiTurn: AITurn?, style: ThinkingStyle? = nil) {
      cancelAITurn()
      if let style { record.style = style }
      board = (try? Board(moves: moves)) ?? Board()
      record.moves = board.moves
      record.outcome = board.outcome
      self.aiTurn = aiTurn
      lastDropPly = nil
    }
  #endif
}
