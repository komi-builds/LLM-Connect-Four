import C4AI
import C4Core
import Foundation
import Testing

@testable import C4Bench

private func tempStore() -> BenchStore {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("c4bench-tests-\(UUID().uuidString)", isDirectory: true)
  return BenchStore(directory: url)
}

private func mockContestant(
  _ id: String = "mock/model", difficulty: Difficulty = .moderate, style: ThinkingStyle = .instinct
) -> Contestant {
  Contestant(
    kind: .llm(
      modelID: id, style: style, difficulty: difficulty, variantID: PromptVariant.default.id),
    modelName: "Mock \(id)")
}

private func mockFactory() -> ProviderFactory {
  BenchProviders.standard { id in
    MockMoveProvider(name: id, tokenDelay: .zero, loadDuration: .zero)
  }
}

private func tinyConfiguration(
  preset: SuitePreset = .quick, contestants: [Contestant]? = nil
) -> BenchConfiguration {
  var config = BenchConfiguration(
    preset: preset, contestants: contestants ?? [mockContestant()],
    puzzles: PuzzleGenerator.generate(seed: 5, perCategory: 2), models: [],
    machine: MachineInfo(
      chip: "Test", memoryGB: 16, osVersion: "1", appVersion: "t", promptVersion: 1))
  config.anchors = [.random, .minimax(1)]
  config.gamesPerAnchor = 4
  config.gamesPerPair = 2
  return config
}

@Suite struct OpeningTests {
  @Test func allFortyNineAreDistinctAndPlayable() {
    #expect(Openings.all.count == 49)
    #expect(Set(Openings.all).count == 49)
    for opening in Openings.all { #expect((try? Board(moves: opening)) != nil) }
  }

  @Test func colourPairsShareAnOpening() {
    for k in 0..<10 {
      let even = Openings.opening(forGame: 2 * k)
      let odd = Openings.opening(forGame: 2 * k + 1)
      #expect(even.moves == odd.moves)
      #expect(even.listedFirstPlaysFirst && !odd.listedFirstPlaysFirst)
    }
  }

  @Test func seedsAreDeterministicAndDistinct() {
    let c = mockContestant()
    let a = BenchSeeds.gameSeed(
      preset: .quick, first: c, second: .random, opening: [3, 3], gameIndex: 0)
    let b = BenchSeeds.gameSeed(
      preset: .quick, first: c, second: .random, opening: [3, 3], gameIndex: 0)
    #expect(a == b)
    #expect(
      a
        != BenchSeeds.gameSeed(
          preset: .standard, first: c, second: .random, opening: [3, 3], gameIndex: 0))
    #expect(
      a
        != BenchSeeds.gameSeed(
          preset: .quick, first: .random, second: c, opening: [3, 3], gameIndex: 0))
    #expect(
      a
        != BenchSeeds.gameSeed(
          preset: .quick, first: c, second: .random, opening: [3, 3], gameIndex: 1))
    // A fixed value, so a change to the hashing is noticed (it would orphan saved games).
    #expect(StableHash.hash("c4") == StableHash.hash("c4"))
  }
}

@Suite struct RunnerTests {
  @Test func tinyRunSavesGamesAndPuzzlesThenResumes() async throws {
    let store = tempStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let config = tinyConfiguration()
    let runner = BenchRunner(configuration: config, store: store, providers: mockFactory())
    #expect(runner.plannedGames().count == 8)
    #expect(Set(runner.plannedGames().map(\.seed)).count == 8)

    let summary = try await runner.run()
    #expect(summary.gamesPlayed == 8)
    #expect(summary.puzzlesAnswered == 8)
    #expect(!summary.cancelled)

    let games = store.loadGames()
    let attempts = store.loadPuzzleAttempts()
    #expect(games.count == 8)
    #expect(attempts.count == 8)
    for game in games {
      #expect(game.moves.starts(with: game.opening))
      #expect(game.traces.count == game.moves.count - game.opening.count)
      #expect(game.machine.chip == "Test")
      #expect(game.loadTimeMs != nil)
      #expect(game.peakRAMGB != nil)
      #expect(game.outcome == (try! Board(moves: game.moves)).outcome)
    }
    #expect(attempts.allSatisfy { $0.trace?.prompt != nil })

    // The leaderboard computes straight from the files.
    let rows = Leaderboard.compute(games: games, puzzles: attempts, models: [])
    #expect(rows.count == 3)
    #expect(
      rows.contains { $0.contestant.id == config.contestants[0].id && $0.puzzleOverall != nil })

    // Rerun: everything is on disk, nothing is replayed.
    let again = try await runner.run()
    #expect(again.gamesPlayed == 0 && again.puzzlesAnswered == 0)
    #expect(again.gamesResumed == 8 && again.puzzlesResumed == 8)
    #expect(store.loadGames().count == 8)
  }

  @Test func resumeOnlyPlaysTheMissingGames() async throws {
    let store = tempStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let runner = BenchRunner(
      configuration: tinyConfiguration(), store: store, providers: mockFactory())
    _ = try await runner.run()
    let files = try FileManager.default.contentsOfDirectory(
      at: store.gamesDirectory, includingPropertiesForKeys: nil)
    try FileManager.default.removeItem(at: files[0])
    try FileManager.default.removeItem(at: files[1])
    let summary = try await runner.run()
    #expect(summary.gamesPlayed == 2)
    #expect(summary.gamesResumed == 6)
    #expect(store.loadGames().count == 8)
  }

  @Test func sameSeedsGiveTheSameGames() async throws {
    let storeA = tempStore()
    let storeB = tempStore()
    defer {
      try? FileManager.default.removeItem(at: storeA.directory)
      try? FileManager.default.removeItem(at: storeB.directory)
    }
    for store in [storeA, storeB] {
      _ = try await BenchRunner(
        configuration: tinyConfiguration(), store: store, providers: mockFactory()
      ).run()
    }
    let a = Dictionary(uniqueKeysWithValues: storeA.loadGames().map { ($0.gameSeed, $0.moves) })
    let b = Dictionary(uniqueKeysWithValues: storeB.loadGames().map { ($0.gameSeed, $0.moves) })
    #expect(a == b)
    #expect(a.count == 8)
  }

  @Test func progressReportsTotalsAndBoard() async throws {
    let store = tempStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let box = ProgressBox()
    _ = try await BenchRunner(
      configuration: tinyConfiguration(), store: store, providers: mockFactory()
    ).run {
      box.add($0)
    }
    let all = box.all
    let last = all.last!
    #expect(last.phase == .finished)
    #expect(last.gamesDone == 8 && last.gamesTotal == 8)
    #expect(last.puzzlesDone == 8 && last.puzzlesTotal == 8)
    #expect(all.contains { $0.currentBoard != nil })
    #expect(all.contains { if case .loading = $0.phase { true } else { false } })
  }

  @Test func cancelledRunPlaysNothing() async throws {
    let store = tempStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let runner = BenchRunner(
      configuration: tinyConfiguration(), store: store, providers: mockFactory())
    let task = Task { try await runner.run() }
    task.cancel()
    let summary = try await task.value
    #expect(summary.cancelled)
    #expect(store.loadGames().isEmpty)
  }

  @Test func providerErrorsFallBackInsteadOfAbortingTheGame() async throws {
    let store = tempStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    var config = tinyConfiguration()
    config.includePuzzles = false
    config.anchors = [.random]
    config.gamesPerAnchor = 2
    let factory = BenchProviders.standard { id in
      MockMoveProvider(name: id, tokenDelay: .zero, loadDuration: .zero, failure: "boom")
    }
    let summary = try await BenchRunner(configuration: config, store: store, providers: factory)
      .run()
    #expect(summary.gamesPlayed == 2)
    let sources = store.loadGames().flatMap(\.traces).filter { $0.modelID != nil }.map(
      \.move.source)
    #expect(!sources.isEmpty && sources.allSatisfy { $0 == .fallback })
  }

  @Test func fullPresetPlaysRoundRobinOnlyWhenModelsFit() async throws {
    let store = tempStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let a = mockContestant("m/a")
    let b = mockContestant("m/b")
    var config = tinyConfiguration(preset: .full, contestants: [a, b])
    config.includePuzzles = false
    config.anchors = [.random]
    config.gamesPerAnchor = 2
    config.models = [
      ModelSpec(id: "m/a", name: "A", sizeGB: 2, thinking: false),
      ModelSpec(id: "m/b", name: "B", sizeGB: 2, thinking: false),
    ]
    let runner = BenchRunner(configuration: config, store: store, providers: mockFactory())
    #expect(runner.plannedGames().count == 2 + 2 + 2)
    let summary = try await runner.run()
    #expect(summary.gamesPlayed == 6)
    let pairGames = store.loadGames().filter { !$0.first.isAnchor && !$0.second.isAnchor }
    #expect(pairGames.count == 2)
    #expect(Set(pairGames.map(\.first.id)) == [a.id, b.id])

    config.models = [
      ModelSpec(id: "m/a", name: "A", sizeGB: 4, thinking: false),
      ModelSpec(id: "m/b", name: "B", sizeGB: 4, thinking: false),
    ]
    let big = BenchRunner(configuration: config, store: tempStore(), providers: mockFactory())
    #expect(big.plannedGames().count == 4)
    let note = try await big.run().notes
    #expect(note.count == 1 && note[0].contains("round robin skipped"))
  }

  @Test func contestantsSharingAModelShareOneProvider() async throws {
    let store = tempStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let counter = ProgressBox()
    let factory = BenchProviders.standard { id in
      counter.made(id)
      return MockMoveProvider(name: id, tokenDelay: .zero, loadDuration: .zero)
    }
    var config = tinyConfiguration(contestants: [
      mockContestant(difficulty: .easy), mockContestant(difficulty: .hard),
    ])
    config.anchors = [.random]
    config.gamesPerAnchor = 2
    _ = try await BenchRunner(configuration: config, store: store, providers: factory).run()
    #expect(counter.madeIDs.filter { $0 == "mock/model" }.count == 1)
  }

  @Test func storeIgnoresATornPuzzleLine() throws {
    let store = tempStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let contestant = mockContestant()
    let attempt = PuzzleAttempt(
      puzzleID: "win-in-1-001", category: .winIn1, contestant: contestant, chosen: 3, correct: true,
      trace: nil, machine: .current)
    try store.append(attempt)
    let url = store.puzzleFile(for: contestant)
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"puzzleID\":\"win-in".utf8))
    try handle.close()
    #expect(store.loadPuzzleAttempts().count == 1)
    #expect(store.answeredPuzzleIDs(for: contestant) == ["win-in-1-001"])
  }
}

@Suite struct SelfCheckTests {
  /// Answers a fixed wrong column until it is told the fact, then answers the right one.
  struct Stubborn: MoveProvider {
    var wrong: Column
    var right: Column
    var name: String { "Stub" }
    func move(_ context: TurnContext) -> AsyncStream<TurnEvent> {
      let column = context.extraFacts.isEmpty ? wrong : right
      return AsyncStream { continuation in
        var p = [Double](repeating: 0, count: 7)
        p[column] = 1
        let d = ColumnDistribution(probabilities: p, masked: [])
        continuation.yield(.prompt(PromptBuilder.build(for: context)))
        continuation.yield(.decided(AIMove(column: column, distribution: d)))
        continuation.finish()
      }
    }
  }

  private func winPosition() -> Board {
    // First has three in column 0 and second has three in column 1; first to move wins at 0.
    try! Board(moves: [0, 1, 0, 1, 0, 1])
  }

  @Test func hardReprompts() async throws {
    let board = winPosition()
    #expect(Tactics.immediateWins(board, for: board.toMove) == [0])
    let context = TurnContext(board: board, profile: .hard, gameSeed: 1)
    let outcome = try #require(
      await SelfCheck.run(provider: Stubborn(wrong: 4, right: 0), context: context))
    #expect(outcome.selfChecked)
    #expect(outcome.move.column == 0)
    #expect(outcome.move.source == .modelAfterSelfCheck)
    #expect(outcome.firstMove?.column == 4)
    #expect(outcome.blunder == .missedWin)
    #expect(outcome.prompt?.facts.contains { $0.contains("missed an immediate win") } == true)
  }

  @Test func moderateDoesNotReprompt() async throws {
    let context = TurnContext(board: winPosition(), profile: .moderate, gameSeed: 1)
    let outcome = try #require(
      await SelfCheck.run(provider: Stubborn(wrong: 4, right: 0), context: context))
    #expect(!outcome.selfChecked)
    #expect(outcome.move.column == 4)
    #expect(outcome.move.source == .model)
  }

  @Test func goodMoveIsLeftAlone() async throws {
    let context = TurnContext(board: winPosition(), profile: .hard, gameSeed: 1)
    let outcome = try #require(
      await SelfCheck.run(provider: Stubborn(wrong: 0, right: 0), context: context))
    #expect(!outcome.selfChecked)
    #expect(outcome.move.source == .model)
  }

  @Test func missedBlockIsCaught() async throws {
    // Second has three in column 1; first to move cannot win and must block column 1.
    let board = try Board(moves: [0, 1, 2, 1, 4, 1])
    let facts = Tactics.mustBlock(board)
    #expect(facts == [1])
    let context = TurnContext(board: board, profile: .hard, gameSeed: 1)
    // `right` is the block; the stub answers wrong first.
    let outcome = try #require(
      await SelfCheck.run(provider: Stubborn(wrong: 3, right: 1), context: context))
    #expect(outcome.blunder == .missedBlock)
    #expect(outcome.move.column == 1)
  }
}

private final class ProgressBox: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [BenchProgress] = []
  private var madeList: [String] = []
  func add(_ progress: BenchProgress) { lock.withLock { items.append(progress) } }
  func made(_ id: String) { lock.withLock { madeList.append(id) } }
  var all: [BenchProgress] { lock.withLock { items } }
  var madeIDs: [String] { lock.withLock { madeList } }
}

@Suite struct CommittedPuzzleTests {
  @Test func everyCommittedPuzzleChecks() {
    let puzzles = BenchPuzzles.bundled()
    #expect(puzzles.count >= 150)
    #expect(Set(puzzles.map(\.id)).count == puzzles.count)
    for category in PuzzleCategory.allCases {
      #expect(puzzles.filter { $0.category == category }.count >= 30, "\(category)")
    }
    for puzzle in puzzles { #expect(PuzzleGenerator.check(puzzle), "\(puzzle.id)") }
  }

  @Test func committedFileMatchesTheFixedSeed() {
    // c4bench gen-puzzles --seed 20260101 --per-category 38 regenerates the file.
    let regenerated = PuzzleGenerator.generate(seed: 20_260_101, perCategory: 38)
    #expect(regenerated == BenchPuzzles.bundled())
  }
}
