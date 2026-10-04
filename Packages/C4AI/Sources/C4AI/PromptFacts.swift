import C4Core

/// Turns `Tactics` results into the fact sentences shown in the prompt (§3.1, §3.6).
///
/// Facts never say "play column N" except as a stated forced fact (an immediate win).
/// Sentences are always from the side to move's view: the opponent is `X`, "you" is `O`.
public enum PromptFacts {
  /// The facts for `board` at `level`, in a fixed order: wins, blocks, unsafe moves, threats.
  public static func compute(board: Board, level: FactLevel) -> [String] {
    guard level != .none, !board.isGameOver else { return [] }
    var facts: [String] = []
    for column in Tactics.immediateWins(board, for: board.toMove) {
      facts.append("You can win immediately in column \(BoardEncoder.label(column)).")
    }
    for column in Tactics.mustBlock(board) {
      facts.append(
        "X threatens to win in column \(BoardEncoder.label(column)). You must block unless you can win first."
      )
    }
    guard level == .full else { return facts }
    for column in Tactics.unsafeMoves(board) {
      facts.append("Playing column \(BoardEncoder.label(column)) lets X win immediately.")
    }
    for (column, count) in Tactics.threatsCreated(board).sorted(by: { $0.key < $1.key }) {
      let what = count == 1 ? "a new winning threat" : "\(count) new winning threats"
      facts.append("Column \(BoardEncoder.label(column)) would create \(what) for you.")
    }
    return facts
  }
}

/// The two worked examples in the static prefix. Both are checked against the engine in tests.
public enum PromptExamples {
  /// Example 1: the opponent (first player) has three in column 4, so the side to move must block it.
  public static let blockMoves: [Column] = [3, 0, 3, 1, 3]
  public static let blockAnswer: Column = 3
  /// Example 2: the side to move (first player) has 2, 3, 4 on row 1 and wins in column 1.
  public static let winMoves: [Column] = [1, 4, 2, 5, 3, 5]
  public static let winAnswer: Column = 0

  public static var block: Board { try! Board(moves: blockMoves) }
  public static var win: Board { try! Board(moves: winMoves) }
}
