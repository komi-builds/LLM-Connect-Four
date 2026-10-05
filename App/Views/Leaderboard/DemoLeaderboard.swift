#if DEBUG
  import AppKit
  import C4AI
  import C4Bench
  import C4Core
  import Foundation

  /// Launch arguments that set up the Leaderboard window for screenshots (DEBUG only):
  ///
  ///     -demoLeaderboard YES      open the Leaderboard window at launch (and snapshot it)
  ///     -demoSelect Thinking      select the first row whose name contains this text
  ///     -demoOpenGame YES         with -demoSelect: open that row's first game in the replay
  ///     -demoRunSheet YES         open the run sheet and start a mock run (use -mockModel YES)
  ///
  /// The data comes from a real `BenchRunner` run in the sandbox temp folder: engines of
  /// different depths stand in for the models, then timings, load times and memory are
  /// filled in with plausible numbers so every column has something to show. It is demo
  /// data and never touches the user's real benchmark folder.
  @MainActor
  enum DemoLeaderboard {
    struct Hooks {
      var select: (String) -> Void
      var showRunSheet: () -> Void
      var openGame: (BenchGame) -> Void
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "demoLeaderboard") }

    static var directory: URL {
      URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
        "demo-bench", isDirectory: true)
    }

    static func run(model: LeaderboardModel, run: BenchRunModel, show: Hooks) async {
      guard isEnabled else { return }
      let store = BenchStore(directory: directory)
      if store.finishedGameSeeds().isEmpty { await seed(store) }
      await model.use(store: store)
      let defaults = UserDefaults.standard
      if let text = defaults.string(forKey: "demoSelect"),
        let row = model.allRows.first(where: { $0.name.contains(text) })
      {
        show.select(row.id)
        if defaults.bool(forKey: "demoOpenGame") {
          try? await Task.sleep(for: .milliseconds(400))
          let detail = model.detail(for: row.id)
          if let game = detail.games.first(where: { $0.result == .loss })?.game
            ?? detail.games.first?.game
          {
            show.openGame(game)
          }
        }
      }
      if defaults.bool(forKey: "demoRunSheet") {
        // Run into a copy, so the demo data the other screenshots use stays as it is.
        let copy = directory.deletingLastPathComponent().appendingPathComponent("demo-bench-run")
        try? FileManager.default.removeItem(at: copy)
        try? FileManager.default.copyItem(at: directory, to: copy)
        let store = BenchStore(directory: copy)
        await model.use(store: store)
        run.mockTokenDelay = .milliseconds(60)
        run.selectedModelIDs = ["mlx-community/Qwen3-8B-4bit"]
        run.styles = [.explain]
        run.difficulties = [.moderate]
        show.showRunSheet()
        try? await Task.sleep(for: .milliseconds(600))
        run.start(store: store) { Task { await model.reload() } }
      }
    }

    // MARK: Seeding

    /// (model id, style, difficulty, stand-in engine depth; nil plays at random).
    private static let seeded: [(String, ThinkingStyle, Difficulty, Int?)] = [
      ("mlx-community/Qwen3-4B-Thinking-2507-4bit", .deepThink, .hard, 4),
      ("mlx-community/Qwen3-4B-Instruct-2507-4bit", .explain, .hard, 3),
      ("mlx-community/Qwen3.5-4B-4bit", .explain, .moderate, 3),
      ("mlx-community/gemma-3-4b-it-4bit", .explain, .moderate, 2),
      ("mlx-community/Qwen3-1.7B-4bit", .instinct, .moderate, 1),
      ("mlx-community/Llama-3.2-3B-Instruct-4bit", .instinct, .easy, nil),
    ]

    private static func seed(_ store: BenchStore) async {
      let models = ModelRegistry.bundled()
      let contestants = seeded.compactMap { id, style, difficulty, _ -> Contestant? in
        guard let spec = models.first(where: { $0.id == id }) else { return nil }
        return Contestant(
          kind: .llm(
            modelID: id, style: style, difficulty: difficulty, variantID: PromptVariant.default.id),
          modelName: spec.name)
      }
      var configuration = BenchConfiguration(
        preset: .quick, contestants: contestants, models: models,
        machine: MachineInfo(
          chip: "Apple M3 Pro", memoryGB: 18, osVersion: "26.0.0", appVersion: "0.1.0",
          promptVersion: PromptBuilder.version))
      configuration.anchors = [.random, .minimax(2), .minimax(4)]
      configuration.gamesPerAnchor = 14
      configuration.calibrationAnchors = [.random, .minimax(1), .minimax(2), .minimax(4)]
      configuration.calibrationGamesPerPair = 10
      let depths = Dictionary(uniqueKeysWithValues: seeded.map { ($0.0, $0.3) })
      let providers = BenchProviders.standard(llm: { id in
        if let depth = depths[id] ?? nil { return EngineMoveProvider(depth: depth) }
        return RandomMoveProvider()
      })
      let runner = BenchRunner(configuration: configuration, store: store, providers: providers)
      _ = try? await Task.detached { try await runner.run() }.value
      await Task.detached { decorate(store, models: models) }.value
    }

    /// Fills in what a stand-in engine cannot measure: model names, move times, tokens per
    /// second, load times, memory, a few would-be-illegal answers and a second machine.
    nonisolated private static func decorate(_ store: BenchStore, models: [ModelSpec]) {
      let sizes = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0.sizeGB) })
      let secondMachine = MachineInfo(
        chip: "Apple M1", memoryGB: 16, osVersion: "26.0.0", appVersion: "0.1.0",
        promptVersion: PromptBuilder.version)
      for var game in store.loadGames() {
        var llmIDs = Set<String>()
        for index in game.traces.indices {
          var trace = game.traces[index]
          let contestant = trace.ply.isMultiple(of: 2) ? game.first : game.second
          guard case .llm(let id, let style, let difficulty, let variant) = contestant.kind else {
            continue
          }
          llmIDs.insert(id)
          let size = sizes[id] ?? 2
          let jitter = Double((trace.ply &* 37 &+ id.count &* 11) % 100) / 100
          let base: Double =
            switch style {
            case .instinct: 380
            case .explain: 1400
            case .deepThink: 6800
            }
          let tokens =
            switch style {
            case .instinct: 0
            case .explain: 38
            case .deepThink: 520
            }
          let speed = 190 / (size + 0.8)
          trace.provider = contestant.modelName ?? id
          trace.modelID = id
          trace.style = style
          trace.difficulty = difficulty
          trace.variantID = variant
          trace.move.timings = MoveTimings(
            prefillMs: 60 + size * 20, timeToFirstTokenMs: 90 + size * 25,
            decodeTokensPerSecond: tokens == 0 ? 0 : speed * (0.94 + jitter * 0.12),
            totalMs: base * size / 2.3 * (0.8 + jitter * 0.4), generatedTokens: tokens,
            prefixCacheHit: true)
          trace.move.reasoning =
            tokens == 0
            ? ""
            : "Column \(trace.move.column + 1) keeps my lines open and does not give the opponent a square."
          trace.move.unmaskedTopChoiceLegal =
            id.contains("Llama") ? (trace.ply % 9 != 0) : (trace.ply % 41 != 0)
          game.traces[index] = trace
        }
        let size = llmIDs.compactMap { sizes[$0] }.reduce(0, +)
        if !llmIDs.isEmpty {
          game.loadTimeMs = size * 1700
          game.peakRAMGB = size * 1.2 + 0.5
        }
        if llmIDs.contains("mlx-community/gemma-3-4b-it-4bit") { game.machine = secondMachine }
        try? store.save(game)
      }
    }
  }
#endif

#if DEBUG
  import SwiftUI

  /// Opens the Leaderboard window at launch for `-demoLeaderboard YES`.
  struct DemoOpenLeaderboard: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
      content.onAppear {
        if DemoLeaderboard.isEnabled { openWindow(id: "leaderboard") }
      }
    }
  }
#endif
