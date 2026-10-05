import C4AI
import C4Bench
import C4Core
import Foundation

// Pure logic behind the leaderboard window: columns, sorting, rank labels, the detail
// data and the benchmark time estimate. No SwiftUI here, so it is easy to test.

// MARK: Rows and columns

/// One table row: the rating row plus the rank label to display (`3` or `=3`).
struct LeaderboardRow: Identifiable, Hashable, Sendable {
  var row: RatingRow
  var rankLabel: String
  var id: String { row.id }
  var name: String { row.contestant.displayName }
  var isAnchor: Bool { row.contestant.isAnchor }
}

enum LeaderboardColumn: String, CaseIterable, Hashable, Sendable {
  case rank, contestant, rating, puzzles, winVsD4, blunders, illegal, medianMove
  case tokensPerSecond, loadTime, peakRAM, size

  var title: LocalizedStringResource {
    switch self {
    case .rank: "Rank"
    case .contestant: "Contestant"
    case .rating: "Rating ± CI"
    case .puzzles: "Puzzles %"
    case .winVsD4: "Win % vs d4"
    case .blunders: "Blunders / game"
    case .illegal: "Would-be illegal %"
    case .medianMove: "Median move"
    case .tokensPerSecond: "tok/s"
    case .loadTime: "Load time"
    case .peakRAM: "Peak RAM"
    case .size: "Size"
    }
  }

  /// The number the column sorts by. Nil sorts last, whichever way the column is sorted.
  func sortValue(_ row: LeaderboardRow) -> Double? {
    let r = row.row
    switch self {
    case .rank: return Double(r.rank)
    case .contestant: return nil
    case .rating: return r.rating
    case .puzzles: return r.puzzleOverall
    case .winVsD4: return r.winRateVsD4
    case .blunders: return r.blundersPerGame
    case .illegal: return r.wouldBeIllegalRate
    case .medianMove: return r.medianMoveMs
    case .tokensPerSecond: return r.tokensPerSecond
    case .loadTime: return r.loadTimeMs
    case .peakRAM: return r.peakRAMGB
    case .size: return r.sizeGB
    }
  }

  /// The cell text, or nil when the value is missing (the table shows `n/a`).
  func text(_ row: LeaderboardRow) -> String? {
    let r = row.row
    switch self {
    case .rank: return row.rankLabel
    case .contestant: return row.name
    case .rating:
      return String(format: "%.0f ± %.0f", r.rating, ((r.ciHigh - r.ciLow) / 2).rounded())
    case .puzzles: return r.puzzleOverall.map { String(format: "%.0f", $0 * 100) }
    case .winVsD4: return r.winRateVsD4.map { String(format: "%.0f", $0 * 100) }
    case .blunders: return r.blundersPerGame.map { String(format: "%.2f", $0) }
    case .illegal: return r.wouldBeIllegalRate.map { String(format: "%.1f", $0 * 100) }
    case .medianMove: return r.medianMoveMs.map(Self.duration)
    case .tokensPerSecond: return r.tokensPerSecond.map { String(format: "%.1f", $0) }
    case .loadTime: return r.loadTimeMs.map { String(format: "%.1f s", $0 / 1000) }
    case .peakRAM: return r.peakRAMGB.map { String(format: "%.1f GB", $0) }
    case .size: return r.sizeGB.map { String(format: "%.1f GB", $0) }
    }
  }

  static func duration(_ ms: Double) -> String {
    ms < 1000 ? String(format: "%.0f ms", ms) : String(format: "%.1f s", ms / 1000)
  }
}

/// Sorts rows by one column. Rows without a value always go last, ascending or descending,
/// and ties fall back to rank so the order is stable.
struct LeaderboardComparator: SortComparator, Hashable, Sendable {
  var column: LeaderboardColumn
  var order: SortOrder = .forward

  func compare(_ lhs: LeaderboardRow, _ rhs: LeaderboardRow) -> ComparisonResult {
    if column == .contestant {
      let result = lhs.name.localizedStandardCompare(rhs.name)
      if result == .orderedSame { return Self.byRank(lhs, rhs) }
      return order == .forward ? result : Self.flipped(result)
    }
    switch (column.sortValue(lhs), column.sortValue(rhs)) {
    case (nil, nil): return Self.byRank(lhs, rhs)
    case (nil, _): return .orderedDescending
    case (_, nil): return .orderedAscending
    case (let a?, let b?):
      if a == b { return Self.byRank(lhs, rhs) }
      let result: ComparisonResult = a < b ? .orderedAscending : .orderedDescending
      return order == .forward ? result : Self.flipped(result)
    }
  }

  private static func byRank(_ lhs: LeaderboardRow, _ rhs: LeaderboardRow) -> ComparisonResult {
    lhs.row.rank == rhs.row.rank
      ? .orderedSame : (lhs.row.rank < rhs.row.rank ? .orderedAscending : .orderedDescending)
  }

  private static func flipped(_ result: ComparisonResult) -> ComparisonResult {
    result == .orderedAscending ? .orderedDescending : .orderedAscending
  }
}

enum LeaderboardRanks {
  /// `3` for a row on its own, `=3` for every row in a tie chain that starts at position 3,
  /// the same labels `ReportWriter` prints. `rows` must be in rating order.
  static func labels(_ rows: [RatingRow]) -> [String] {
    var out: [String] = []
    var chainStart = 0
    for (index, row) in rows.enumerated() {
      if !(index > 0 && row.tiedWithPrevious) { chainStart = index }
      let tiedAbove = index > 0 && row.tiedWithPrevious
      let tiedBelow = index + 1 < rows.count && rows[index + 1].tiedWithPrevious
      out.append(tiedAbove || tiedBelow ? "=\(chainStart + 1)" : "\(chainStart + 1)")
    }
    return out
  }

  static func rows(_ rows: [RatingRow]) -> [LeaderboardRow] {
    zip(rows, labels(rows)).map { LeaderboardRow(row: $0, rankLabel: $1) }
  }
}

// MARK: Machines

extension MachineInfo {
  /// Speed columns compare chip and memory only, as `Leaderboard.compute` does.
  var speedKey: String { label }

  static func distinct(in games: [BenchGame]) -> [MachineInfo] {
    var seen = Set<String>()
    var out: [MachineInfo] = []
    for game in games where seen.insert(game.machine.speedKey).inserted { out.append(game.machine) }
    return out.sorted { $0.label < $1.label }
  }
}

// MARK: Replay conversion

/// Names and captions for replaying a benchmark game, where both sides are contestants.
struct ReplayLabels {
  var title: String
  var subtitle: String
  /// Who made each move (by move index), for the step caption.
  var movers: [String]
}

extension BenchGame {
  /// A `GameRecord` the replay view can open: the first contestant plays the "human" colour
  /// and the second the AI colour. Traces of both contestants are kept (anchor traces have
  /// no prompt, which the replay handles).
  func replayRecord() -> (record: GameRecord, labels: ReplayLabels) {
    let llm: Contestant? = [second, first].first { !$0.isAnchor }
    var modelID: String?
    var style = ThinkingStyle.instinct
    var difficulty = Difficulty.moderate
    var variantID = PromptVariant.default.id
    if let llm, case .llm(let id, let s, let d, let v) = llm.kind {
      modelID = id
      style = s
      difficulty = d
      variantID = v
    }
    let record = GameRecord(
      id: id, startedAt: startedAt, finishedAt: finishedAt, humanDisc: .first,
      opponentName: second.displayName, modelID: modelID, style: style, difficulty: difficulty,
      variantID: variantID, gameSeed: gameSeed, moves: moves, traces: traces, outcome: outcome)
    let result: String
    switch outcome {
    case .draw: result = String(localized: "Draw")
    case .win(let disc):
      result = String(localized: "\((disc == .first ? first : second).displayName) won")
    }
    let movers = moves.indices.map { index -> String in
      if index < opening.count { return String(localized: "Opening") }
      return (index.isMultiple(of: 2) ? first : second).displayName
    }
    let date = startedAt.formatted(date: .abbreviated, time: .shortened)
    let labels = ReplayLabels(
      title: result,
      subtitle: "\(first.displayName) vs \(second.displayName) · "
        + String(localized: "\(moves.count) moves") + " · \(date)",
      movers: movers)
    return (record, labels)
  }
}

// MARK: Detail

enum GameResult: Sendable, Hashable {
  case win, draw, loss
}

struct ContestantDetail: Sendable {
  struct Matchup: Identifiable, Sendable {
    var opponent: Contestant
    var wins = 0
    var draws = 0
    var losses = 0
    var id: String { opponent.id }
    var total: Int { wins + draws + losses }
  }

  struct CategoryAccuracy: Identifiable, Sendable {
    var category: PuzzleCategory
    var correct: Int
    var total: Int
    var id: String { category.rawValue }
    var fraction: Double { total == 0 ? 0 : Double(correct) / Double(total) }
  }

  struct BlunderRecord: Identifiable, Sendable {
    var gameID: UUID
    var opponent: Contestant
    var ply: Int
    var played: Column
    var kind: Blunder
    /// The columns that would have been right: the winning moves or the blocks.
    var missed: [Column]
    var id: String { "\(gameID)-\(ply)" }
  }

  struct GameEntry: Identifiable, Sendable {
    var game: BenchGame
    var opponent: Contestant
    var result: GameResult
    var wasFirst: Bool
    var id: UUID { game.id }
  }

  var matchups: [Matchup] = []
  var categories: [CategoryAccuracy] = []
  var blunders: [BlunderRecord] = []
  var games: [GameEntry] = []

  /// Everything the detail view shows for `contestantID`.
  static func make(
    contestantID: String, games: [BenchGame], puzzles: [PuzzleAttempt], blunderLimit: Int = 25
  ) -> ContestantDetail {
    var detail = ContestantDetail()
    var matchups: [String: Matchup] = [:]
    for game in games where game.first.id != game.second.id {
      guard let score = game.score(for: contestantID) else { continue }
      let wasFirst = game.first.id == contestantID
      let opponent = wasFirst ? game.second : game.first
      var matchup = matchups[opponent.id] ?? Matchup(opponent: opponent)
      let result: GameResult = score == 1 ? .win : (score == 0.5 ? .draw : .loss)
      switch result {
      case .win: matchup.wins += 1
      case .draw: matchup.draws += 1
      case .loss: matchup.losses += 1
      }
      matchups[opponent.id] = matchup
      detail.games.append(
        GameEntry(game: game, opponent: opponent, result: result, wasFirst: wasFirst))
      detail.blunders += blunders(in: game, by: contestantID, opponent: opponent)
    }
    // Anchors first (weakest to strongest), then models by name.
    detail.matchups = matchups.values.sorted { a, b in
      if a.opponent.isAnchor != b.opponent.isAnchor { return a.opponent.isAnchor }
      if a.opponent.isAnchor { return anchorOrder(a.opponent) < anchorOrder(b.opponent) }
      return a.opponent.displayName < b.opponent.displayName
    }
    detail.games.sort { $0.game.finishedAt > $1.game.finishedAt }
    detail.blunders.sort {
      if $0.kind != $1.kind { return $0.kind == .missedWin }
      if $0.ply != $1.ply { return $0.ply < $1.ply }
      return $0.gameID.uuidString < $1.gameID.uuidString
    }
    detail.blunders = Array(detail.blunders.prefix(blunderLimit))

    var byCategory: [PuzzleCategory: (Int, Int)] = [:]
    for attempt in puzzles where attempt.contestant.id == contestantID {
      var entry = byCategory[attempt.category] ?? (0, 0)
      entry.1 += 1
      if attempt.correct { entry.0 += 1 }
      byCategory[attempt.category] = entry
    }
    detail.categories = PuzzleCategory.allCases.compactMap { category in
      byCategory[category].map {
        CategoryAccuracy(category: category, correct: $0.0, total: $0.1)
      }
    }
    return detail
  }

  private static func anchorOrder(_ contestant: Contestant) -> Int {
    switch contestant.kind {
    case .random: 0
    case .minimax(let depth): depth
    case .llm: 99
    }
  }

  /// Replays `game` and reports every move by `contestantID` (after the opening) that
  /// `Tactics.blunder` flags.
  static func blunders(in game: BenchGame, by contestantID: String, opponent: Contestant)
    -> [BlunderRecord]
  {
    var out: [BlunderRecord] = []
    var board = Board()
    for (ply, column) in game.moves.enumerated() {
      guard !board.isGameOver, board.canPlay(column) else { break }
      let mover = board.toMove == .first ? game.first : game.second
      if ply >= game.opening.count, mover.id == contestantID,
        let kind = Tactics.blunder(on: board, played: column)
      {
        let missed =
          kind == .missedWin
          ? Tactics.immediateWins(board, for: board.toMove) : Tactics.mustBlock(board)
        out.append(
          BlunderRecord(
            gameID: game.id, opponent: opponent, ply: ply, played: column, kind: kind,
            missed: missed))
      }
      board = board.dropping(column)
    }
    return out
  }
}

// MARK: Estimate

/// A rough time estimate shown before a run starts (§5.5): per model move, Instinct 0.5 s,
/// Explain 1.5 s, Deep think 8 s; about 20 model moves per game; a puzzle is one move.
struct BenchEstimate: Sendable, Equatable {
  var gamesToPlay = 0
  var gamesAlreadyDone = 0
  var puzzlesToAnswer = 0
  var modelMoves = 0
  var seconds: Double = 0

  static let movesPerGame = 20

  static func secondsPerMove(_ style: ThinkingStyle) -> Double {
    switch style {
    case .instinct: 0.5
    case .explain: 1.5
    case .deepThink: 8
    }
  }

  static func make(configuration: BenchConfiguration, store: BenchStore) -> BenchEstimate {
    var estimate = BenchEstimate()
    let runner = BenchRunner(
      configuration: configuration, store: store, providers: { _ in RandomMoveProvider() })
    let finished = store.finishedGameSeeds()
    func perMove(_ contestant: Contestant) -> Double {
      if case .llm(_, let style, _, _) = contestant.kind { return secondsPerMove(style) }
      return 0
    }
    for game in runner.plannedGames() {
      if finished.contains(game.seed) {
        estimate.gamesAlreadyDone += 1
        continue
      }
      estimate.gamesToPlay += 1
      for side in [game.first, game.second] where !side.isAnchor {
        estimate.modelMoves += movesPerGame
        estimate.seconds += Double(movesPerGame) * perMove(side)
      }
    }
    if configuration.includePuzzles {
      for contestant in configuration.contestants where !contestant.isAnchor {
        let answered = store.answeredPuzzleIDs(for: contestant)
        let todo = configuration.puzzles.filter { !answered.contains($0.id) }.count
        estimate.puzzlesToAnswer += todo
        estimate.modelMoves += todo
        estimate.seconds += Double(todo) * perMove(contestant)
      }
    }
    return estimate
  }

  /// "about 2 h 10 min", "about 12 min", "under a minute".
  var durationText: String {
    let minutes = Int((seconds / 60).rounded())
    if seconds < 60 { return String(localized: "under a minute") }
    if minutes < 60 { return String(localized: "about \(minutes) min") }
    let hours = minutes / 60
    let rest = (minutes % 60 / 5) * 5
    return rest == 0
      ? String(localized: "about \(hours) h") : String(localized: "about \(hours) h \(rest) min")
  }
}
