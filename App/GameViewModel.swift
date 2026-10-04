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

  let provider: any MoveProvider
  /// Hugging Face id recorded in traces; nil for non-LLM providers such as the mock.
  let providerModelID: String?
  private(set) var loadProgress: LoadProgress?
  private(set) var isModelReady: Bool
  private(set) var loadError: String?
  /// True while a human move is waiting for the model to finish loading.
  private(set) var isWaitingForModel = false

  // MARK: Settings (changeable only between games)

  let models: [ModelSpec]
  var difficulty: Difficulty {
    didSet {
      defaults.set(difficulty.rawValue, forKey: Keys.difficulty)
    }
  }
  var style: ThinkingStyle {
    didSet {
      defaults.set(style.rawValue, forKey: Keys.style)
    }
  }
  var selectedModelID: String? {
    didSet {
      defaults.set(selectedModelID, forKey: Keys.model)
      if style == .deepThink, !canDeepThink { style = .explain }
    }
  }
  var showThinking: Bool {
    didSet { defaults.set(showThinking, forKey: Keys.showThinking) }
  }

  /// Minimum time between the human's drop and the AI's drop, so the human's disc
  /// finishes its animation first. Zero in tests.
  @ObservationIgnored var minimumAIDelay: Duration
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var aiTask: Task<Void, Never>?
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var turnToken = 0
  private(set) var isAITurnActive = false

  private enum Keys {
    static let difficulty = "difficulty"
    static let style = "thinkingStyle"
    static let model = "modelID"
    static let showThinking = "showThinking"
  }

  init(
    provider: any MoveProvider = MockMoveProvider(),
    providerModelID: String? = nil,
    models: [ModelSpec] = ModelRegistry.bundled(),
    defaults: UserDefaults = .standard,
    minimumAIDelay: Duration = .milliseconds(450),
    loadImmediately: Bool = true
  ) {
    self.provider = provider
    self.providerModelID = providerModelID
    self.models = models
    self.defaults = defaults
    self.minimumAIDelay = minimumAIDelay
    let difficulty =
      defaults.string(forKey: Keys.difficulty).flatMap(Difficulty.init(rawValue:)) ?? .moderate
    let style =
      defaults.string(forKey: Keys.style).flatMap(ThinkingStyle.init(rawValue:)) ?? .explain
    let storedModel = defaults.string(forKey: Keys.model)
    let modelID =
      models.contains(where: { $0.id == storedModel })
      ? storedModel : (models.first(where: \.isDefault) ?? models.first)?.id
    self.difficulty = difficulty
    self.style = style
    self.selectedModelID = modelID
    self.showThinking = defaults.object(forKey: Keys.showThinking) as? Bool ?? true
    self.isModelReady = !(provider is any LoadableMoveProvider)
    let seed = UInt64.random(in: .min ... .max)
    self.record = GameRecord(
      opponentName: provider.name, modelID: providerModelID, style: style, difficulty: difficulty,
      variantID: PromptVariant.default.id, gameSeed: seed)
    if self.style == .deepThink, !canDeepThink { self.style = .explain }
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

  /// Display name for the opponent: the selected model's name, else the provider's.
  var opponentName: String { selectedModel?.name ?? provider.name }

  // MARK: Loading

  /// Starts loading a `LoadableMoveProvider` in the background. Safe to call again.
  func startLoading() {
    guard let loadable = provider as? any LoadableMoveProvider, loadTask == nil, !isModelReady
    else { return }
    loadError = nil
    loadProgress = LoadProgress(phase: .loading, fraction: 0)
    gameLog.info("loading provider \(loadable.name, privacy: .public)")
    loadTask = Task {
      do {
        // The load is finite, so holding `self` until it ends is fine.
        try await loadable.load { progress in
          Task { @MainActor in self.receive(progress) }
        }
        self.isModelReady = true
        self.loadProgress = LoadProgress(phase: .ready, fraction: 1)
        gameLog.info("provider ready")
      } catch {
        self.loadError = error.localizedDescription
        self.loadTask = nil
        gameLog.error("load failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  private func receive(_ progress: LoadProgress) {
    guard !isModelReady else { return }
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
    board = Board()
    aiTurn = nil
    lastDropPly = nil
    record = GameRecord(
      opponentName: provider.name, modelID: providerModelID, style: effectiveStyle,
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
    let context = TurnContext(
      board: board, style: effectiveStyle, profile: .profile(for: difficulty), variant: .default,
      thinkingBudget: style == .deepThink && !canDeepThink
        ? ThinkingStyle.explain.defaultBudget * 2 : nil,
      gameSeed: gameSeed)
    turnToken += 1
    let token = turnToken
    let started = ContinuousClock.now
    aiTurn = AITurn(ply: board.plyCount)
    isAITurnActive = true
    isWaitingForModel = !isModelReady
    aiTask = Task { [weak self] in
      await self?.runAITurn(context, token: token, started: started)
    }
  }

  private func runAITurn(_ context: TurnContext, token: Int, started: ContinuousClock.Instant) async
  {
    // Wait for the model if the human was quicker than the load.
    if !isModelReady {
      if loadTask == nil { startLoading() }
      isWaitingForModel = true
      await loadTask?.value
      guard token == turnToken, !Task.isCancelled else { return }
      isWaitingForModel = false
    }

    var decided: AIMove?
    for await event in provider.move(context) {
      guard token == turnToken, !Task.isCancelled else { return }
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
    guard token == turnToken, !Task.isCancelled else { return }

    let move: AIMove
    if let decided, board.canPlay(decided.column) {
      move = decided
    } else {
      // Temporary stand-in until the integration step wires FallbackMoveProvider.
      move = Self.fallbackMove(on: board, reasoning: aiTurn?.reasoning ?? "")
    }

    let elapsed = ContinuousClock.now - started
    if elapsed < minimumAIDelay {
      try? await Task.sleep(for: minimumAIDelay - elapsed)
      guard token == turnToken, !Task.isCancelled else { return }
    }

    record.traces.append(
      MoveTrace(
        context: context, provider: provider.name, modelID: providerModelID, prompt: aiTurn?.prompt,
        move: move))
    aiTurn?.move = move
    aiTurn?.distribution = move.distribution
    isAITurnActive = false
    aiTask = nil
    apply(move.column)
  }

  /// Centre-first legal column with `source: .fallback`.
  static func fallbackMove(on board: Board, reasoning: String) -> AIMove {
    let legal = board.legalMoves
    let column = Engine.columnOrder.first(where: board.canPlay) ?? legal[0]
    var probabilities = [Double](repeating: 0, count: Board.columnCount)
    probabilities[column] = 1
    let distribution = ColumnDistribution(
      probabilities: probabilities, masked: Set(Board.allColumns).subtracting(legal))
    return AIMove(
      column: column, distribution: distribution, reasoning: reasoning, source: .fallback)
  }

  #if DEBUG
    /// Sets up a finished position for screenshots and previews. Not a game action.
    func setPosition(_ moves: [Column], aiTurn: AITurn?) {
      cancelAITurn()
      board = (try? Board(moves: moves)) ?? Board()
      record.moves = board.moves
      record.outcome = board.outcome
      self.aiTurn = aiTurn
      lastDropPly = nil
    }
  #endif
}
