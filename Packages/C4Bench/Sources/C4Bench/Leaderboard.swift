import C4AI
import C4Core
import Foundation

public enum Leaderboard {
  /// Recomputes every row from saved games and puzzle attempts (§5.4). Ratings and
  /// intervals use all games; speed columns use only games from `machine` (chip and
  /// memory) when given. Only contestants that played at least one game get a row.
  public static func compute(
    games: [BenchGame], puzzles: [PuzzleAttempt], models: [ModelSpec] = ModelRegistry.bundled(),
    machine: MachineInfo? = nil
  ) -> [RatingRow] {
    var contestants: [String: Contestant] = [:]
    for game in games {
      if contestants[game.first.id] == nil { contestants[game.first.id] = game.first }
      if contestants[game.second.id] == nil { contestants[game.second.id] = game.second }
    }
    let pairs = games.map(\.pairResult)
    let ratings = BradleyTerry.fit(pairs)
    let intervals = BradleyTerry.bootstrap(pairs)

    var wins: [String: Int] = [:]
    var draws: [String: Int] = [:]
    var losses: [String: Int] = [:]
    var played: [String: Int] = [:]
    var blunders: [String: Int] = [:]
    var illegalCounts: [String: (illegal: Int, total: Int)] = [:]
    var moveMs: [String: [Double]] = [:]
    var tokensPerSecond: [String: [Double]] = [:]
    var loadTimes: [String: [Double]] = [:]
    var peakRAM: [String: Double] = [:]
    var vsD4: [String: (points: Double, games: Int)] = [:]

    for game in games where game.first.id != game.second.id {
      let sides = [game.first, game.second]
      let onMachine =
        machine.map { $0.chip == game.machine.chip && $0.memoryGB == game.machine.memoryGB } ?? true
      for (side, contestant) in sides.enumerated() {
        let id = contestant.id
        let opponent = sides[1 - side]
        played[id, default: 0] += 1
        let score = game.score(for: id) ?? 0
        if score == 1 {
          wins[id, default: 0] += 1
        } else if score == 0.5 {
          draws[id, default: 0] += 1
        } else {
          losses[id, default: 0] += 1
        }
        if opponent.id == "minimax-d4" {
          var entry = vsD4[id] ?? (0, 0)
          entry.points += score
          entry.games += 1
          vsD4[id] = entry
        }
        if onMachine, case .llm = contestant.kind {
          if let load = game.loadTimeMs { loadTimes[id, default: []].append(load) }
          if let ram = game.peakRAMGB { peakRAM[id] = max(peakRAM[id] ?? 0, ram) }
        }
      }
      for (id, count) in blunderCounts(in: game) { blunders[id, default: 0] += count }
      for trace in game.traces {
        guard let contestant = traceOwner(trace, in: game) else { continue }
        let id = contestant.id
        if let legal = trace.move.unmaskedTopChoiceLegal {
          var entry = illegalCounts[id] ?? (0, 0)
          entry.total += 1
          if !legal { entry.illegal += 1 }
          illegalCounts[id] = entry
        }
        if onMachine {
          moveMs[id, default: []].append(trace.move.timings.totalMs)
          if trace.move.timings.generatedTokens > 0 {
            tokensPerSecond[id, default: []].append(trace.move.timings.decodeTokensPerSecond)
          }
        }
      }
    }

    var puzzleCorrect: [String: [String: (correct: Int, total: Int)]] = [:]
    for attempt in puzzles {
      var byCategory = puzzleCorrect[attempt.contestant.id] ?? [:]
      var entry = byCategory[attempt.category.rawValue] ?? (0, 0)
      entry.total += 1
      if attempt.correct { entry.correct += 1 }
      byCategory[attempt.category.rawValue] = entry
      puzzleCorrect[attempt.contestant.id] = byCategory
    }

    let sizes = Dictionary(
      models.map { ($0.id, $0.sizeGB) }, uniquingKeysWith: { first, _ in first })

    let ordered = contestants.values.sorted {
      let r0 = ratings[$0.id] ?? 1000
      let r1 = ratings[$1.id] ?? 1000
      return r0 != r1 ? r0 > r1 : $0.id < $1.id
    }
    var rows: [RatingRow] = []
    // A tie group starts at a row and takes every following row whose interval overlaps
    // the group's first row. Comparing with the group's leader (not just the row above)
    // keeps a chain of small overlaps from tying the top of the table with the bottom.
    var groupLeader: RatingRow?
    for (position, contestant) in ordered.enumerated() {
      let id = contestant.id
      let rating = ratings[id] ?? 1000
      let interval = intervals[id] ?? rating...rating
      let games = played[id] ?? 0
      var row = RatingRow(
        contestant: contestant, rank: position + 1, rating: rating, ciLow: interval.lowerBound,
        ciHigh: interval.upperBound, games: games, wins: wins[id] ?? 0, draws: draws[id] ?? 0,
        losses: losses[id] ?? 0)
      if let leader = groupLeader, row.ciHigh >= leader.ciLow {
        row.tiedWithPrevious = true
      } else {
        groupLeader = row
      }
      if let entry = vsD4[id], entry.games > 0 {
        row.winRateVsD4 = entry.points / Double(entry.games)
      }
      if let byCategory = puzzleCorrect[id] {
        var totalCorrect = 0
        var total = 0
        for (category, entry) in byCategory {
          row.puzzleAccuracy[category] = Double(entry.correct) / Double(entry.total)
          totalCorrect += entry.correct
          total += entry.total
        }
        if total > 0 { row.puzzleOverall = Double(totalCorrect) / Double(total) }
      }
      if games > 0 { row.blundersPerGame = Double(blunders[id] ?? 0) / Double(games) }
      if let entry = illegalCounts[id], entry.total > 0 {
        row.wouldBeIllegalRate = Double(entry.illegal) / Double(entry.total)
      }
      row.medianMoveMs = median(moveMs[id] ?? [])
      row.tokensPerSecond = median(tokensPerSecond[id] ?? [])
      row.loadTimeMs = median(loadTimes[id] ?? [])
      row.peakRAMGB = peakRAM[id]
      if case .llm(let modelID, _, _, _) = contestant.kind { row.sizeGB = sizes[modelID] }
      rows.append(row)
    }
    return rows
  }

  /// The contestant that made the move behind `trace`: the first contestant plays
  /// `Disc.first` (even plies), the second plays `Disc.second`. A trace whose model id
  /// contradicts the LLM contestant it maps to is ignored.
  static func traceOwner(_ trace: MoveTrace, in game: BenchGame) -> Contestant? {
    let contestant = trace.ply.isMultiple(of: 2) ? game.first : game.second
    if case .llm(let modelID, _, _, _) = contestant.kind, let traced = trace.modelID,
      traced != modelID
    {
      return nil
    }
    return contestant
  }

  /// Blunders per contestant id in one game, over the moves after the opening.
  static func blunderCounts(in game: BenchGame) -> [String: Int] {
    var counts: [String: Int] = [:]
    var board = Board()
    for (ply, column) in game.moves.enumerated() {
      guard !board.isGameOver, board.canPlay(column) else { break }
      if ply >= game.opening.count {
        let mover = board.toMove == Disc.first ? game.first : game.second
        if Tactics.blunder(on: board, played: column) != nil { counts[mover.id, default: 0] += 1 }
      }
      board = board.dropping(column)
    }
    return counts
  }

  static func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
  }
}
