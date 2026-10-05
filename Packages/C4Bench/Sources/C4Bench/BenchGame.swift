import C4AI
import C4Core
import Foundation

/// Bench suites and presets (§5.2).
public enum SuitePreset: String, Sendable, Hashable, Codable, CaseIterable {
  /// Puzzles + 14 games against each of 3 anchors.
  case quick
  /// Puzzles + 50 games against each of 5 anchors.
  case standard
  /// Standard + round robin.
  case full
}

/// One finished benchmark game. Stored as one JSONL file per game under
/// `~/Library/Application Support/LLMConnectFour/bench/`; the leaderboard is always
/// recomputed from these.
public struct BenchGame: Sendable, Hashable, Codable, Identifiable {
  public var id: UUID
  public var preset: SuitePreset
  public var first: Contestant
  public var second: Contestant
  /// The forced opening moves (0-based) played before either contestant moves.
  public var opening: [Column]
  public var gameSeed: UInt64
  /// All moves including the opening.
  public var moves: [Column]
  public var outcome: GameOutcome
  /// One trace per contestant move (not the opening), in order.
  public var traces: [MoveTrace]
  /// Load time of the LLM contestant(s) for this run, if measured.
  public var loadTimeMs: Double?
  /// Peak resident memory during the game, if measured.
  public var peakRAMGB: Double?
  public var machine: MachineInfo
  public var startedAt: Date
  public var finishedAt: Date

  public init(
    id: UUID = UUID(), preset: SuitePreset, first: Contestant, second: Contestant,
    opening: [Column],
    gameSeed: UInt64, moves: [Column], outcome: GameOutcome, traces: [MoveTrace],
    loadTimeMs: Double? = nil,
    peakRAMGB: Double? = nil, machine: MachineInfo, startedAt: Date, finishedAt: Date
  ) {
    self.id = id
    self.preset = preset
    self.first = first
    self.second = second
    self.opening = opening
    self.gameSeed = gameSeed
    self.moves = moves
    self.outcome = outcome
    self.traces = traces
    self.loadTimeMs = loadTimeMs
    self.peakRAMGB = peakRAMGB
    self.machine = machine
    self.startedAt = startedAt
    self.finishedAt = finishedAt
  }

  /// 1 for a win, 0.5 for a draw, 0 for a loss; nil if `contestantID` didn't play.
  public func score(for contestantID: String) -> Double? {
    let disc: Disc
    if first.id == contestantID {
      disc = .first
    } else if second.id == contestantID {
      disc = .second
    } else {
      return nil
    }
    switch outcome {
    case .draw: return 0.5
    case .win(let winner): return winner == disc ? 1 : 0
    }
  }

  public var pairResult: PairResult {
    PairResult(a: first.id, b: second.id, scoreA: score(for: first.id)!)
  }
}

/// One contestant's answer to one puzzle.
public struct PuzzleAttempt: Sendable, Hashable, Codable, Identifiable {
  public var id: UUID
  public var puzzleID: String
  public var category: PuzzleCategory
  public var contestant: Contestant
  public var chosen: Column
  public var correct: Bool
  public var trace: MoveTrace?
  public var machine: MachineInfo

  public init(
    id: UUID = UUID(), puzzleID: String, category: PuzzleCategory, contestant: Contestant,
    chosen: Column,
    correct: Bool, trace: MoveTrace?, machine: MachineInfo
  ) {
    self.id = id
    self.puzzleID = puzzleID
    self.category = category
    self.contestant = contestant
    self.chosen = chosen
    self.correct = correct
    self.trace = trace
    self.machine = machine
  }
}
