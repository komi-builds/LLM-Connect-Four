import C4AI
import C4Bench
import C4Core
import Foundation
import Testing

@testable import LLMConnectFour

private let machineA = MachineInfo(
  chip: "Apple M3 Pro", memoryGB: 18, osVersion: "26.0", appVersion: "1", promptVersion: 3)
private let machineB = MachineInfo(
  chip: "Apple M1", memoryGB: 16, osVersion: "26.0", appVersion: "1", promptVersion: 3)

private func llm(_ name: String, style: ThinkingStyle = .explain) -> Contestant {
  Contestant(
    kind: .llm(modelID: "m/\(name)", style: style, difficulty: .hard, variantID: "combined"),
    modelName: name)
}

private func tempStore() -> BenchStore {
  BenchStore(
    directory: FileManager.default.temporaryDirectory.appendingPathComponent(
      "leaderboard-tests-\(UUID().uuidString)", isDirectory: true))
}

/// A tiny real run: one contestant against Random and Minimax d2, 2 games each, 4 puzzles.
private func tinyRun(
  _ contestant: Contestant, machine: MachineInfo, store: BenchStore
) async throws {
  var configuration = BenchConfiguration(
    preset: .quick, contestants: [contestant],
    puzzles: Array(BenchPuzzles.bundled().prefix(4)), models: [], machine: machine)
  configuration.anchors = [.random, .minimax(2)]
  configuration.gamesPerAnchor = 2
  configuration.calibrationGamesPerPair = 0
  let runner = BenchRunner(
    configuration: configuration, store: store,
    providers: BenchProviders.standard(llm: { _ in RandomMoveProvider() }))
  _ = try await runner.run()
}

private func ratingRow(
  _ name: String, rank: Int, rating: Double, median: Double? = nil, tied: Bool = false
) -> LeaderboardRow {
  let row = RatingRow(
    contestant: llm(name), rank: rank, rating: rating, ciLow: rating - 20, ciHigh: rating + 20,
    tiedWithPrevious: tied, games: 10, wins: 5, draws: 0, losses: 5, medianMoveMs: median)
  return LeaderboardRow(row: row, rankLabel: "\(rank)")
}

@MainActor
@Suite struct LeaderboardModelTests {
  @Test func loadsFromATempStore() async throws {
    let store = tempStore()
    try await tinyRun(llm("Alpha"), machine: machineA, store: store)
    let model = LeaderboardModel(
      store: store, defaults: UserDefaults(suiteName: UUID().uuidString)!)
    await model.reload()
    #expect(model.hasLoaded)
    #expect(model.games.count == 4)
    let ids = Set(model.allRows.map(\.id))
    #expect(ids.contains(llm("Alpha").id))
    #expect(ids.contains("random"))
    #expect(ids.contains("minimax-d2"))
    let alpha = model.allRows.first { $0.id == llm("Alpha").id }
    #expect(alpha?.row.puzzleOverall != nil)
    // Anchors can be hidden, and the search narrows the list.
    model.showAnchors = false
    #expect(model.visibleRows.allSatisfy { !$0.isAnchor })
    model.searchText = "zzz"
    #expect(model.visibleRows.isEmpty)
  }

  @Test func emptyStoreHasNoRows() async {
    let model = LeaderboardModel(
      store: tempStore(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
    await model.reload()
    #expect(model.hasLoaded)
    #expect(model.allRows.isEmpty)
  }

  @Test func machineFilterOnlyChangesSpeedColumns() async throws {
    let store = tempStore()
    try await tinyRun(llm("Alpha"), machine: machineA, store: store)
    try await tinyRun(llm("Beta"), machine: machineB, store: store)
    let model = LeaderboardModel(
      store: store, defaults: UserDefaults(suiteName: UUID().uuidString)!)
    await model.reload()
    #expect(model.machines.count == 2)
    let alphaID = llm("Alpha").id
    let ratingBefore = model.allRows.first { $0.id == alphaID }?.row.rating
    #expect(model.allRows.first { $0.id == alphaID }?.row.medianMoveMs != nil)

    model.machineKey = machineB.speedKey
    await model.recompute()
    while model.isLoading { try await Task.sleep(for: .milliseconds(20)) }
    let alpha = model.allRows.first { $0.id == alphaID }
    #expect(alpha?.row.medianMoveMs == nil)
    #expect(alpha?.row.rating == ratingBefore)
    #expect(model.allRows.first { $0.id == llm("Beta").id }?.row.medianMoveMs != nil)
  }
}

@Suite struct LeaderboardLogicTests {
  @Test func nilValuesSortLastBothWays() {
    let rows = [
      ratingRow("A", rank: 1, rating: 1300, median: nil),
      ratingRow("B", rank: 2, rating: 1200, median: 900),
      ratingRow("C", rank: 3, rating: 1100, median: 300),
    ]
    let ascending = rows.sorted(using: [LeaderboardComparator(column: .medianMove)])
    #expect(ascending.map { $0.row.contestant.modelName } == ["C", "B", "A"])
    let descending = rows.sorted(using: [
      LeaderboardComparator(column: .medianMove, order: .reverse)
    ])
    #expect(descending.map(\.row.contestant.modelName) == ["B", "C", "A"])
    let byRating = rows.sorted(using: [LeaderboardComparator(column: .rating, order: .reverse)])
    #expect(byRating.map(\.row.contestant.modelName) == ["A", "B", "C"])
    let byName = rows.sorted(using: [LeaderboardComparator(column: .contestant, order: .reverse)])
    #expect(byName.first?.row.contestant.modelName == "C")
  }

  @Test func tieChainsGetEqualsLabels() {
    func row(_ rank: Int, tied: Bool) -> RatingRow {
      RatingRow(
        contestant: llm("R\(rank)"), rank: rank, rating: 1000, ciLow: 900, ciHigh: 1100,
        tiedWithPrevious: tied, games: 1, wins: 1, draws: 0, losses: 0)
    }
    let rows = [
      row(1, tied: false), row(2, tied: false), row(3, tied: true), row(4, tied: true),
      row(5, tied: false),
    ]
    #expect(LeaderboardRanks.labels(rows) == ["1", "=2", "=2", "=2", "5"])
    #expect(LeaderboardRanks.rows(rows).map(\.rankLabel) == ["1", "=2", "=2", "=2", "5"])
  }

  @Test func estimateUsesPerStyleMoveTimes() async throws {
    let store = tempStore()
    let contestant = llm("Alpha")
    var configuration = BenchConfiguration(
      preset: .quick, contestants: [contestant],
      puzzles: Array(BenchPuzzles.bundled().prefix(4)), models: [], machine: machineA)
    configuration.anchors = [.random, .minimax(2)]
    configuration.gamesPerAnchor = 2
    configuration.calibrationGamesPerPair = 0

    let estimate = BenchEstimate.make(configuration: configuration, store: store)
    #expect(estimate.gamesToPlay == 4)
    #expect(estimate.puzzlesToAnswer == 4)
    #expect(estimate.modelMoves == 4 * 20 + 4)
    #expect(abs(estimate.seconds - 84 * 1.5) < 0.001)

    configuration.contestants = [llm("Alpha", style: .deepThink)]
    #expect(
      abs(BenchEstimate.make(configuration: configuration, store: store).seconds - 84 * 8) < 0.001)
    configuration.contestants = [llm("Alpha", style: .instinct)]
    #expect(
      abs(BenchEstimate.make(configuration: configuration, store: store).seconds - 84 * 0.5) < 0.001
    )

    // After the run, everything is on disk and nothing is left to do.
    try await tinyRun(contestant, machine: machineA, store: store)
    configuration.contestants = [contestant]
    let done = BenchEstimate.make(configuration: configuration, store: store)
    #expect(done.gamesToPlay == 0)
    #expect(done.gamesAlreadyDone == 4)
    #expect(done.puzzlesToAnswer == 0)
    #expect(done.seconds == 0)
    #expect(done.durationText == "under a minute")
  }

  @Test func benchGameConvertsToAReplayRecord() async throws {
    let store = tempStore()
    let alpha = llm("Alpha")
    try await tinyRun(alpha, machine: machineA, store: store)
    let game = try #require(
      store.loadGames().first { $0.first.id == alpha.id || $0.second.id == alpha.id })
    let (record, labels) = game.replayRecord()
    #expect(record.moves == game.moves)
    #expect(record.traces.count == game.traces.count)
    #expect(record.outcome == game.outcome)
    #expect(record.humanDisc == .first)
    #expect(record.modelID == "m/Alpha")
    #expect(labels.movers.count == game.moves.count)
    #expect(labels.movers[game.opening.count] == (game.first.displayName))
    #expect(labels.title.hasSuffix("won") || labels.title == "Draw")
    // The replay state can step through it.
    var state = ReplayState(record: record)
    state.seek(to: record.moves.count)
    #expect(state.board.moves == game.moves)
  }

  @Test func worstBlundersAreExtractedForTheRightContestant() {
    let first = llm("First")
    let second = Contestant.minimax(2)
    // After 0 1 0 1 0 1 the mover (first) can win in column 0 and plays 3 instead. Second
    // could then win in column 1 and plays 4.
    let moves: [Column] = [0, 1, 0, 1, 0, 1, 3, 4]
    func game(opening: [Column]) -> BenchGame {
      BenchGame(
        preset: .quick, first: first, second: second, opening: opening, gameSeed: 1, moves: moves,
        outcome: .draw, traces: [], machine: machineA, startedAt: Date(), finishedAt: Date())
    }
    let found = ContestantDetail.blunders(in: game(opening: []), by: first.id, opponent: second)
    #expect(found.count == 1)
    #expect(found.first?.ply == 6)
    #expect(found.first?.played == 3)
    #expect(found.first?.kind == .missedWin)
    #expect(found.first?.missed == [0])
    let others = ContestantDetail.blunders(in: game(opening: []), by: second.id, opponent: first)
    #expect(others.map(\.ply) == [5, 7])
    #expect(others.first?.kind == .missedBlock)
    #expect(others.first?.missed == [0])
    #expect(others.last?.kind == .missedWin)
    #expect(others.last?.missed == [1])
    // Forced opening moves are never blamed on anyone.
    let skipped = ContestantDetail.blunders(
      in: game(opening: [0, 1, 0, 1, 0, 1, 3]), by: first.id, opponent: second)
    #expect(skipped.isEmpty)

    let detail = ContestantDetail.make(
      contestantID: first.id, games: [game(opening: [])], puzzles: [])
    #expect(detail.blunders.count == 1)
    #expect(detail.matchups.count == 1)
    #expect(detail.games.count == 1)
  }

  @Test func detailCountsResultsPerOpponentAndPuzzleCategories() async throws {
    let store = tempStore()
    let alpha = llm("Alpha")
    try await tinyRun(alpha, machine: machineA, store: store)
    let detail = ContestantDetail.make(
      contestantID: alpha.id, games: store.loadGames(), puzzles: store.loadPuzzleAttempts())
    #expect(detail.matchups.map(\.opponent.id) == ["random", "minimax-d2"])
    #expect(detail.matchups.allSatisfy { $0.total == 2 })
    #expect(detail.games.count == 4)
    #expect(detail.categories.map(\.total).reduce(0, +) == 4)
  }
}
