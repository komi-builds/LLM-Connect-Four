import C4AI
import C4Core
import Foundation

/// Pure stepping logic for the replay: a game and how many plies are on the board.
/// Takes a `GameRecord` (not the live view model), so benchmark games can open here too.
struct ReplayState: Equatable {
  var record: GameRecord
  /// Discs on the board, 0...moves.count.
  private(set) var ply = 0

  init(record: GameRecord, ply: Int? = nil) {
    self.record = record
    self.ply = min(max(ply ?? 0, 0), record.moves.count)
  }

  var plyCount: Int { record.moves.count }
  var canStepBack: Bool { ply > 0 }
  var canStepForward: Bool { ply < plyCount }

  mutating func stepBack() { if canStepBack { ply -= 1 } }
  mutating func stepForward() { if canStepForward { ply += 1 } }
  mutating func seek(to value: Int) { ply = min(max(value, 0), plyCount) }

  /// The board with the first `ply` moves played.
  var board: Board { (try? Board(moves: Array(record.moves.prefix(ply)))) ?? Board() }

  /// Index of the move that was just played, nil at the empty board.
  var lastMoveIndex: Int? { ply > 0 ? ply - 1 : nil }
  var lastColumn: Column? { lastMoveIndex.map { record.moves[$0] } }

  /// The trace of the AI move just played, if the last move was the AI's.
  var trace: MoveTrace? { lastMoveIndex.flatMap { trace(forMoveAt: $0) } }

  func trace(forMoveAt index: Int) -> MoveTrace? {
    record.traces.first { $0.ply == index }
  }

  func isHumanMove(at index: Int) -> Bool {
    trace(forMoveAt: index) == nil
  }

  /// Ply (board size) after each AI move, for slider ticks.
  var aiPlies: [Int] { record.traces.map { $0.ply + 1 }.sorted() }
}

extension GameViewModel.AITurn {
  /// A finished turn rebuilt from a saved trace, so the live views also render history.
  init(trace: MoveTrace) {
    self.init(ply: trace.ply)
    prompt = trace.prompt
    thinking = trace.move.thinking
    reasoning = trace.move.reasoning
    thinkingTokens = Self.approximateTokens(trace.move.thinking)
    reasoningTokens = Self.approximateTokens(trace.move.reasoning)
    distribution = trace.move.distribution
    move = trace.move
  }

  /// Saved traces keep text, not token counts. Words are close enough for a counter.
  private static func approximateTokens(_ text: String) -> Int {
    text.split(whereSeparator: \.isWhitespace).count
  }
}
