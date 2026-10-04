import C4AI
import C4Core
import Foundation
import Testing

@testable import C4Bench

@Suite struct LeaderboardTests {
  let machineA = MachineInfo(
    chip: "Apple M3 Pro", memoryGB: 18, osVersion: "26.0", appVersion: "1", promptVersion: 3)
  let machineB = MachineInfo(
    chip: "Apple M1", memoryGB: 16, osVersion: "26.0", appVersion: "1", promptVersion: 3)
  let x = Contestant(
    kind: .llm(modelID: "m/x", style: .explain, difficulty: .hard, variantID: "combined"),
    modelName: "X")
  let models = [ModelSpec(id: "m/x", name: "X", sizeGB: 2.5, thinking: false)]

  func trace(
    _ moves: [Column], provider: String, modelID: String? = nil, totalMs: Double, tokens: Int = 0,
    tps: Double = 0,
    legal: Bool? = nil
  ) -> MoveTrace {
    let before = Array(moves.dropLast())
    let column = moves.last!
    var probabilities = [Double](repeating: 0, count: 7)
    probabilities[column] = 1
    let move = AIMove(
      column: column, distribution: ColumnDistribution(probabilities: probabilities, masked: []),
      timings: MoveTimings(decodeTokensPerSecond: tps, totalMs: totalMs, generatedTokens: tokens),
      unmaskedTopChoiceLegal: legal)
    return MoveTrace(
      movesBefore: before, provider: provider, modelID: modelID, style: .explain, difficulty: .hard,
      variantID: "combined", promptVersion: 3, prompt: nil, gameSeed: 1, seed: 1, move: move)
  }

  func game(
    first: Contestant, second: Contestant, moves: [Column] = [], opening: [Column] = [],
    outcome: GameOutcome, traces: [MoveTrace] = [], load: Double? = nil, ram: Double? = nil,
    machine: MachineInfo
  ) -> BenchGame {
    BenchGame(
      preset: .quick, first: first, second: second, opening: opening, gameSeed: 1, moves: moves,
      outcome: outcome,
      traces: traces, loadTimeMs: load, peakRAMGB: ram, machine: machine,
      startedAt: Date(timeIntervalSince1970: 0),
      finishedAt: Date(timeIntervalSince1970: 1))
  }

  /// X (first) vs d4. Opening 0, 6. X makes 0,1,2 on the bottom row, d4 plays 5 instead of
  /// blocking at column 3 (a missed block), X wins with 3.
  var blunderGame: BenchGame {
    let moves = [0, 6, 1, 6, 2, 5, 3]
    let d4 = "Minimax d4"
    let traces = [
      trace(
        Array(moves[0...2]), provider: "X", modelID: "m/x", totalMs: 100, tokens: 10, tps: 20,
        legal: true),
      trace(Array(moves[0...3]), provider: d4, totalMs: 1),
      trace(
        Array(moves[0...4]), provider: "X", modelID: "m/x", totalMs: 200, tokens: 10, tps: 40,
        legal: false),
      trace(Array(moves[0...5]), provider: d4, totalMs: 1),
      trace(
        Array(moves[0...6]), provider: "X", modelID: "m/x", totalMs: 300, tokens: 0, tps: 0,
        legal: true),
    ]
    return game(
      first: x, second: .minimax(4), moves: moves, opening: [0, 6], outcome: .win(.first),
      traces: traces,
      load: 3000, ram: 4.0, machine: machineA)
  }

  @Test func blunderReplay() {
    let counts = Leaderboard.blunderCounts(in: blunderGame)
    #expect(counts["minimax-d4"] == 1)
    #expect(counts[x.id] == nil)
  }

  @Test func everyField() throws {
    let otherMachine = game(
      first: .minimax(4), second: x, outcome: .win(.first),
      traces: [
        trace([0, 1], provider: "X", modelID: "m/x", totalMs: 9999, tokens: 5, tps: 1, legal: true)
      ], load: 7000, ram: 9, machine: machineB)
    let draw = game(
      first: x, second: .random, outcome: .draw, load: 5000, ram: 4.5, machine: machineA)
    let win = game(
      first: x, second: .minimax(2), outcome: .win(.first), load: 1000, ram: 3.9, machine: machineA)
    let all = [blunderGame, otherMachine, draw, win]
    let puzzle = { (id: String, category: PuzzleCategory, correct: Bool) in
      PuzzleAttempt(
        puzzleID: id, category: category, contestant: x, chosen: 0, correct: correct, trace: nil,
        machine: machineA)
    }
    let puzzles = [
      puzzle("w1", .winIn1, true), puzzle("w2", .winIn1, true), puzzle("b1", .blockIn1, false),
    ]
    let rows = Leaderboard.compute(games: all, puzzles: puzzles, models: models, machine: machineA)
    #expect(rows.count == 4)
    #expect(rows.map(\.rank) == [1, 2, 3, 4])
    #expect(rows.map(\.rating) == rows.map(\.rating).sorted(by: >))
    #expect(rows.first { $0.contestant.id == "minimax-d2" }?.rating == 1000)
    for (index, row) in rows.enumerated() {
      #expect(row.ciLow <= row.rating && row.rating <= row.ciHigh)
      if index == 0 {
        #expect(!row.tiedWithPrevious)
      } else {
        #expect(row.tiedWithPrevious == (row.ciHigh >= rows[index - 1].ciLow))
      }
    }
    let xr = try #require(rows.first { $0.contestant.id == x.id })
    #expect(xr.games == 4 && xr.wins == 2 && xr.draws == 1 && xr.losses == 1)
    #expect(xr.winRateVsD4 == 0.5)
    #expect(xr.puzzleAccuracy == ["win-in-1": 1, "block-in-1": 0])
    #expect(abs(xr.puzzleOverall! - 2.0 / 3.0) < 1e-12)
    #expect(xr.blundersPerGame == 0)
    // Unmasked legality over all 4 traced moves (3 here, 1 on the other machine): 0 illegal... one false of 4.
    #expect(xr.wouldBeIllegalRate == 0.25)
    // Speed columns: this machine only (100, 200, 300 ms; 2 moves with tokens: 20 and 40 tok/s).
    #expect(xr.medianMoveMs == 200)
    #expect(xr.tokensPerSecond == 30)
    #expect(xr.loadTimeMs == 3000)
    #expect(xr.peakRAMGB == 4.5)
    #expect(xr.sizeGB == 2.5)

    let d4 = try #require(rows.first { $0.contestant.id == "minimax-d4" })
    #expect(d4.games == 2 && d4.wins == 1 && d4.losses == 1)
    #expect(d4.blundersPerGame == 0.5)
    #expect(d4.winRateVsD4 == nil)
    #expect(d4.wouldBeIllegalRate == nil)
    #expect(d4.sizeGB == nil && d4.loadTimeMs == nil && d4.peakRAMGB == nil)
    #expect(d4.puzzleOverall == nil && d4.puzzleAccuracy.isEmpty)
    // d4 traces for plies 3 and 5 (1 ms each), on this machine.
    #expect(d4.medianMoveMs == 1)
    #expect(d4.tokensPerSecond == nil)

    let random = try #require(rows.first { $0.contestant.id == "random" })
    #expect(random.games == 1 && random.draws == 1)
    #expect(random.medianMoveMs == nil)
  }

  @Test func machineFilterIsOptional() throws {
    let other = game(
      first: .minimax(4), second: x, outcome: .win(.first),
      traces: [trace([0, 1], provider: "X", modelID: "m/x", totalMs: 9999, tokens: 5, tps: 1)],
      load: 7000, ram: 9, machine: machineB)
    let rows = Leaderboard.compute(
      games: [blunderGame, other], puzzles: [], models: models, machine: nil)
    let xr = try #require(rows.first { $0.contestant.id == x.id })
    // Without a machine filter all moves count: 100, 200, 300, 9999 ms and 20, 40, 1 tok/s.
    #expect(xr.medianMoveMs == 250)
    #expect(xr.tokensPerSecond == 20)
    #expect(xr.loadTimeMs == 5000)
    #expect(xr.peakRAMGB == 9)
    let withMachineB = Leaderboard.compute(
      games: [blunderGame, other], puzzles: [], models: models, machine: machineB)
    let xb = try #require(withMachineB.first { $0.contestant.id == x.id })
    #expect(xb.loadTimeMs == 7000)
    #expect(xb.peakRAMGB == 9)
    #expect(xb.medianMoveMs == 9999)
  }

  @Test func emptyInput() {
    #expect(Leaderboard.compute(games: [], puzzles: [], models: [], machine: nil).isEmpty)
  }
}
