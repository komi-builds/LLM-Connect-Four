import C4AI
import C4Core
import Darwin
import Foundation
import os

/// Maps a contestant to the provider that plays for it. The runner calls this once per
/// anchor and once per distinct model id (contestants that share a model id share one
/// loaded provider).
public typealias ProviderFactory = @Sendable (Contestant) -> any MoveProvider

public enum BenchProviders {
  /// Random and Minimax anchors are built in; `llm` makes the provider for a model id.
  public static func standard(
    llm: @escaping @Sendable (_ modelID: String) -> any MoveProvider
  ) -> ProviderFactory {
    { contestant in
      switch contestant.kind {
      case .random: RandomMoveProvider()
      case .minimax(let depth): EngineMoveProvider(depth: depth)
      case .llm(let modelID, _, _, _): llm(modelID)
      }
    }
  }
}

/// What to run. `contestants` are the contestants being measured (LLM configurations);
/// anchors come from the preset.
public struct BenchConfiguration: Sendable {
  public var preset: SuitePreset
  public var contestants: [Contestant]
  public var puzzles: [Puzzle]
  /// Model list, used for sizes (round-robin memory check).
  public var models: [ModelSpec]
  public var machine: MachineInfo
  public var includePuzzles = true
  public var includeGames = true
  /// Overrides the preset's anchors (Quick: Random, d2, d4; Standard and Full: all five).
  public var anchors: [Contestant]
  /// Overrides the preset's games per anchor (Quick 14, Standard and Full 50).
  public var gamesPerAnchor: Int
  /// Games per pair in the round robin (Full only).
  public var gamesPerPair: Int
  /// Round-robin pairs are only played when both models fit together under this size.
  public var roundRobinLimitGB: Double
  /// Anchors that play each other so the scale does not depend on LLM games alone.
  public var calibrationAnchors: [Contestant]
  /// Games per anchor pair in the calibration round robin. 0 turns it off. Engines only, so
  /// it is fast, and like every game it is played once and then reused from disk.
  public var calibrationGamesPerPair: Int

  public init(
    preset: SuitePreset, contestants: [Contestant], puzzles: [Puzzle] = BenchPuzzles.bundled(),
    models: [ModelSpec] = ModelRegistry.bundled(), machine: MachineInfo = .current
  ) {
    self.preset = preset
    self.contestants = contestants
    self.puzzles = puzzles
    self.models = models
    self.machine = machine
    self.anchors = Self.defaultAnchors(for: preset)
    self.gamesPerAnchor = Self.defaultGamesPerAnchor(for: preset)
    self.gamesPerPair = 14
    self.roundRobinLimitGB = 6
    self.calibrationAnchors = Contestant.anchors
    self.calibrationGamesPerPair = 14
  }

  public static func defaultAnchors(for preset: SuitePreset) -> [Contestant] {
    preset == .quick ? [.random, .minimax(2), .minimax(4)] : Contestant.anchors
  }

  public static func defaultGamesPerAnchor(for preset: SuitePreset) -> Int {
    preset == .quick ? 14 : 50
  }
}

/// A live snapshot for the CLI and for the app's run sheet.
public struct BenchProgress: Sendable {
  public enum Phase: Sendable, Hashable {
    case loading(model: String, fraction: Double)
    case puzzles(contestant: String)
    case game(first: String, second: String)
    case finished
  }

  public var phase: Phase
  /// Counts include work that was already on disk, so a resumed run starts part way.
  public var gamesDone: Int
  public var gamesTotal: Int
  public var puzzlesDone: Int
  public var puzzlesTotal: Int
  /// Estimated seconds left, from the pace of model moves so far. Nil until known.
  public var etaSeconds: Double?
  /// The board of the game in progress, for a live mini-board.
  public var currentBoard: Board?
  public var message: String?
}

public struct BenchSummary: Sendable {
  public var gamesPlayed = 0
  /// Games found on disk and skipped.
  public var gamesResumed = 0
  public var puzzlesAnswered = 0
  public var puzzlesResumed = 0
  public var cancelled = false
  public var notes: [String] = []
  public var seconds: Double = 0
}

public enum BenchError: Error, CustomStringConvertible {
  case loadFailed(model: String, underlying: String)
  public var description: String {
    switch self {
    case .loadFailed(let model, let underlying): "could not load \(model): \(underlying)"
    }
  }
}

/// Runs puzzles and games for a set of contestants and saves each finished game and puzzle
/// answer as it completes (§5.2, §5.5). Provider-agnostic: pass the real LLM, the mock, or
/// anything else through the factory. Task cancellation stops after the current move;
/// everything finished is already saved, and a rerun skips it.
public struct BenchRunner: Sendable {
  public let configuration: BenchConfiguration
  public let store: BenchStore
  public let providers: ProviderFactory

  public init(
    configuration: BenchConfiguration, store: BenchStore, providers: @escaping ProviderFactory
  ) {
    self.configuration = configuration
    self.store = store
    self.providers = providers
  }

  public func run(progress: @escaping @Sendable (BenchProgress) -> Void = { _ in }) async throws
    -> BenchSummary
  {
    let activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .idleSystemSleepDisabled], reason: "Connect Four benchmark")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    let session = BenchSession(
      configuration: configuration, store: store, factory: providers, report: progress)
    do {
      try await session.execute()
    } catch is CancellationError {
      session.summary.cancelled = true
    } catch {
      await session.unloadAll()
      throw error
    }
    await session.unloadAll()
    session.finish()
    return session.summary
  }

  /// Every game this configuration would play, in order, without running anything.
  public func plannedGames() -> [PlannedGame] {
    BenchSession(configuration: configuration, store: store, factory: providers, report: { _ in })
      .plan().games
  }
}

/// One game in the plan.
public struct PlannedGame: Sendable, Hashable {
  public var first: Contestant
  public var second: Contestant
  public var opening: [Column]
  public var index: Int
  public var seed: UInt64
  public var preset: SuitePreset
}

// MARK: - Session

private final class BenchSession {
  let config: BenchConfiguration
  let store: BenchStore
  let factory: ProviderFactory
  let report: @Sendable (BenchProgress) -> Void
  static let log = Logger(subsystem: "com.komi.LLMConnectFour", category: "bench")

  var summary = BenchSummary()
  var providerCache: [String: any MoveProvider] = [:]
  var loadables: [String: any LoadableMoveProvider] = [:]
  var loadedModels: Set<String> = []
  var loadTimesMs: [String: Double] = [:]
  var representative: [String: Contestant] = [:]

  var gamesDone = 0
  var gamesTotal = 0
  var puzzlesDone = 0
  var puzzlesTotal = 0
  var gamesFinishedThisSession = 0
  var modelMovesInFinishedGames = 0
  var busySeconds = 0.0
  var busyUnits = 0
  var finishedSeeds: Set<UInt64> = []
  var startedAt = Date()

  init(
    configuration: BenchConfiguration, store: BenchStore, factory: @escaping ProviderFactory,
    report: @escaping @Sendable (BenchProgress) -> Void
  ) {
    self.config = configuration
    self.store = store
    self.factory = factory
    self.report = report
  }

  // MARK: Plan

  var llmContestants: [Contestant] {
    var seen = Set<String>()
    return config.contestants.filter { !$0.isAnchor && seen.insert($0.id).inserted }
  }

  func games(_ a: Contestant, _ b: Contestant, count: Int) -> [PlannedGame] {
    (0..<count).map { index in
      let (opening, aFirst) = Openings.opening(forGame: index)
      let (first, second) = aFirst ? (a, b) : (b, a)
      return PlannedGame(
        first: first, second: second, opening: opening, index: index,
        seed: BenchSeeds.gameSeed(
          first: first, second: second, opening: opening, gameIndex: index),
        preset: config.preset)
    }
  }

  func sizeGB(_ modelID: String) -> Double {
    config.models.first { $0.id == modelID }?.sizeGB ?? 0
  }

  func modelID(of contestant: Contestant) -> String? {
    if case .llm(let id, _, _, _) = contestant.kind { return id }
    return nil
  }

  struct Plan {
    var games: [PlannedGame] = []
    var anchorGames: [String: [PlannedGame]] = [:]
    var pairGames: [(a: Contestant, b: Contestant, games: [PlannedGame])] = []
    var calibrationGames: [PlannedGame] = []
    var notes: [String] = []
  }

  func plan() -> Plan {
    var plan = Plan()
    guard config.includeGames else { return plan }
    let anchors = config.calibrationAnchors
    if config.calibrationGamesPerPair > 0 {
      for i in anchors.indices {
        for j in anchors.indices where j > i {
          plan.calibrationGames += games(
            anchors[i], anchors[j], count: config.calibrationGamesPerPair)
        }
      }
      plan.games += plan.calibrationGames
    }
    for contestant in llmContestants {
      let list = config.anchors.flatMap { games(contestant, $0, count: config.gamesPerAnchor) }
      plan.anchorGames[contestant.id] = list
      plan.games += list
    }
    if config.preset == .full {
      let llms = llmContestants
      for i in llms.indices {
        for j in llms.indices where j > i {
          let ids = Set([modelID(of: llms[i]), modelID(of: llms[j])].compactMap { $0 })
          let combined = ids.map(sizeGB).reduce(0, +)
          if combined >= config.roundRobinLimitGB {
            plan.notes.append(
              "round robin skipped for \(llms[i].displayName) vs \(llms[j].displayName): combined size \(String(format: "%.1f", combined)) GB is not under \(String(format: "%.0f", config.roundRobinLimitGB)) GB"
            )
            continue
          }
          let list = games(llms[i], llms[j], count: config.gamesPerPair)
          plan.pairGames.append((llms[i], llms[j], list))
          plan.games += list
        }
      }
    }
    return plan
  }

  // MARK: Execute

  func execute() async throws {
    startedAt = Date()
    finishedSeeds = store.finishedGameSeeds()
    let plan = plan()
    summary.notes += plan.notes
    for note in plan.notes { emit(.puzzles(contestant: ""), message: note) }

    let puzzles = config.includePuzzles ? config.puzzles : []
    var answered: [String: Set<String>] = [:]
    for contestant in llmContestants {
      let done = store.answeredPuzzleIDs(for: contestant)
      answered[contestant.id] = done
      puzzlesDone += puzzles.filter { done.contains($0.id) }.count
      summary.puzzlesResumed += puzzles.filter { done.contains($0.id) }.count
    }
    puzzlesTotal = puzzles.count * llmContestants.count
    gamesTotal = plan.games.count
    gamesDone = plan.games.filter { finishedSeeds.contains($0.seed) }.count
    summary.gamesResumed = gamesDone

    // Group contestants by model so each model is loaded once.
    var order: [String] = []
    var byModel: [String: [Contestant]] = [:]
    for contestant in llmContestants {
      guard let id = modelID(of: contestant) else { continue }
      if byModel[id] == nil {
        order.append(id)
        representative[id] = contestant
      }
      byModel[id, default: []].append(contestant)
    }

    // Anchor calibration first: engines only, nothing to load.
    for game in plan.calibrationGames where !finishedSeeds.contains(game.seed) {
      try await play(game)
    }

    for modelID in order {
      let contestants = byModel[modelID]!
      let hasWork = contestants.contains { contestant in
        puzzles.contains { !(answered[contestant.id] ?? []).contains($0.id) }
          || (plan.anchorGames[contestant.id] ?? []).contains { !finishedSeeds.contains($0.seed) }
      }
      guard hasWork else { continue }
      try await ensureLoaded([modelID])
      for contestant in contestants {
        let todo = puzzles.filter { !(answered[contestant.id] ?? []).contains($0.id) }
        try await runPuzzles(contestant, todo)
        for game in plan.anchorGames[contestant.id] ?? [] where !finishedSeeds.contains(game.seed) {
          try await play(game)
        }
      }
    }

    for pair in plan.pairGames {
      let todo = pair.games.filter { !finishedSeeds.contains($0.seed) }
      guard !todo.isEmpty else { continue }
      let ids = Set([modelID(of: pair.a), modelID(of: pair.b)].compactMap { $0 })
      try await ensureLoaded(ids)
      for game in todo { try await play(game) }
    }
  }

  func finish() {
    summary.seconds = Date().timeIntervalSince(startedAt)
    emit(.finished, board: nil)
  }

  // MARK: Providers and loading

  func provider(for contestant: Contestant) -> any MoveProvider {
    let key = modelID(of: contestant) ?? contestant.id
    if let cached = providerCache[key] { return cached }
    let made = factory(contestant)
    providerCache[key] = made
    return made
  }

  func ensureLoaded(_ ids: Set<String>) async throws {
    for id in loadedModels.subtracting(ids) {
      await loadables[id]?.unload()
      loadedModels.remove(id)
    }
    for id in ids.sorted() where !loadedModels.contains(id) {
      guard let contestant = representative[id] else { continue }
      if let loadable = provider(for: contestant) as? any LoadableMoveProvider {
        loadables[id] = loadable
        let name = contestant.modelName ?? id
        let start = ContinuousClock.now
        emit(.loading(model: name, fraction: 0))
        let base = snapshot(.loading(model: name, fraction: 0))
        let report = report
        do {
          try await loadable.load { p in
            var update = base
            update.phase = .loading(model: name, fraction: p.fraction)
            report(update)
          }
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          throw BenchError.loadFailed(model: name, underlying: "\(error)")
        }
        loadTimesMs[id] = (ContinuousClock.now - start).milliseconds
        Self.log.info("loaded \(id, privacy: .public) in \(self.loadTimesMs[id] ?? 0) ms")
      }
      loadedModels.insert(id)
    }
  }

  func unloadAll() async {
    for id in loadedModels { await loadables[id]?.unload() }
    loadedModels.removeAll()
    loadables.removeAll()
  }

  // MARK: Turns

  func settings(_ contestant: Contestant) -> (ThinkingStyle, DifficultyProfile, PromptVariant) {
    switch contestant.kind {
    case .llm(_, let style, let difficulty, let variantID):
      return (style, .profile(for: difficulty), PromptVariant(id: variantID) ?? .default)
    default:
      return (.instinct, .moderate, .default)
    }
  }

  func runPuzzles(_ contestant: Contestant, _ todo: [Puzzle]) async throws {
    guard !todo.isEmpty else { return }
    let (style, baseProfile, variant) = settings(contestant)
    // Puzzles measure the model's first answer, so the self-check is off.
    var profile = baseProfile
    profile.selfCheck = false
    let wrapped = FallbackMoveProvider(BoxedProvider(provider(for: contestant)))
    for puzzle in todo {
      try checkCancelled()
      let board = puzzle.board
      emit(.puzzles(contestant: contestant.displayName), board: board)
      let context = TurnContext(
        board: board, style: style, profile: profile, variant: variant,
        gameSeed: BenchSeeds.puzzleSeed(puzzleID: puzzle.id, contestant: contestant))
      let start = ContinuousClock.now
      guard let outcome = await SelfCheck.run(provider: wrapped, context: context) else {
        throw CancellationError()
      }
      noteBusy((ContinuousClock.now - start).milliseconds / 1000)
      let trace = MoveTrace(
        context: context, provider: wrapped.name, modelID: modelID(of: contestant),
        prompt: outcome.prompt,
        move: outcome.move)
      let attempt = PuzzleAttempt(
        puzzleID: puzzle.id, category: puzzle.category, contestant: contestant,
        chosen: outcome.move.column,
        correct: puzzle.solutions.contains(outcome.move.column), trace: trace,
        machine: config.machine)
      try store.append(attempt)
      puzzlesDone += 1
      summary.puzzlesAnswered += 1
    }
  }

  func play(_ game: PlannedGame) async throws {
    try checkCancelled()
    let startedAt = Date()
    var board = try Board(moves: game.opening)
    let players = [game.first, game.second]
    let wrapped = players.map { FallbackMoveProvider(BoxedProvider(provider(for: $0))) }
    var traces: [MoveTrace] = []
    var peakBytes = ResidentMemory.currentBytes() ?? 0
    var modelMoves = 0
    emit(.game(first: game.first.displayName, second: game.second.displayName), board: board)

    while !board.isGameOver {
      try checkCancelled()
      let side = board.toMove == .first ? 0 : 1
      let contestant = players[side]
      let (style, profile, variant) = settings(contestant)
      let context = TurnContext(
        board: board, style: style, profile: profile, variant: variant, gameSeed: game.seed)
      let start = ContinuousClock.now
      guard let outcome = await SelfCheck.run(provider: wrapped[side], context: context) else {
        throw CancellationError()
      }
      if case .llm = contestant.kind {
        noteBusy((ContinuousClock.now - start).milliseconds / 1000)
        modelMoves += 1
      }
      peakBytes = max(peakBytes, ResidentMemory.currentBytes() ?? 0)
      var move = outcome.move
      if !board.canPlay(move.column) {
        // Defensive: a provider returned a column that is not playable. Never aborts a game.
        move.column = Engine(depth: 2).bestMove(board)
        move.source = .fallback
      }
      traces.append(
        MoveTrace(
          context: context, provider: wrapped[side].name, modelID: modelID(of: contestant),
          prompt: outcome.prompt, move: move))
      board = board.dropping(move.column)
      emit(.game(first: game.first.displayName, second: game.second.displayName), board: board)
    }

    let ids = Set(players.compactMap { modelID(of: $0) })
    let load = ids.compactMap { loadTimesMs[$0] }
    let finished = BenchGame(
      preset: game.preset, first: game.first, second: game.second, opening: game.opening,
      gameSeed: game.seed,
      moves: board.moves, outcome: board.outcome ?? .draw, traces: traces,
      loadTimeMs: load.isEmpty ? nil : load.reduce(0, +),
      peakRAMGB: peakBytes > 0 ? Double(peakBytes) / 1_073_741_824 : nil, machine: config.machine,
      startedAt: startedAt, finishedAt: Date())
    try store.save(finished)
    finishedSeeds.insert(game.seed)
    gamesDone += 1
    gamesFinishedThisSession += 1
    modelMovesInFinishedGames += modelMoves
    summary.gamesPlayed += 1
    emit(.game(first: game.first.displayName, second: game.second.displayName), board: board)
  }

  func checkCancelled() throws {
    if Task.isCancelled { throw CancellationError() }
  }

  // MARK: Progress

  func noteBusy(_ seconds: Double) {
    busySeconds += seconds
    busyUnits += 1
  }

  /// Seconds left, from the average time of a model move or puzzle so far.
  func eta() -> Double? {
    guard busyUnits > 0 else { return nil }
    let perUnit = busySeconds / Double(busyUnits)
    let puzzlesLeft = max(0, puzzlesTotal - puzzlesDone)
    let movesPerGame =
      gamesFinishedThisSession > 0
      ? Double(modelMovesInFinishedGames) / Double(gamesFinishedThisSession) : 9
    let gamesLeft = max(0, gamesTotal - gamesDone)
    return perUnit * (Double(puzzlesLeft) + Double(gamesLeft) * movesPerGame)
  }

  func snapshot(_ phase: BenchProgress.Phase, board: Board? = nil, message: String? = nil)
    -> BenchProgress
  {
    BenchProgress(
      phase: phase, gamesDone: gamesDone, gamesTotal: gamesTotal, puzzlesDone: puzzlesDone,
      puzzlesTotal: puzzlesTotal, etaSeconds: eta(), currentBoard: board, message: message)
  }

  func emit(_ phase: BenchProgress.Phase, board: Board? = nil, message: String? = nil) {
    report(snapshot(phase, board: board, message: message))
  }
}

// MARK: - Provider box

/// Lets an existential provider be used where a concrete `MoveProvider` is needed.
struct BoxedProvider: MoveProvider {
  let base: any MoveProvider
  init(_ base: any MoveProvider) { self.base = base }
  var name: String { base.name }
  func move(_ context: TurnContext) -> AsyncStream<TurnEvent> { base.move(context) }
}

// MARK: - Memory

enum ResidentMemory {
  /// Current resident set size of this process, from `task_info`.
  static func currentBytes() -> UInt64? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? UInt64(info.resident_size) : nil
  }
}
