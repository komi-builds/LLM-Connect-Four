import Testing

@testable import C4Core

@Suite struct BoardRulesTests {
  private func cells(_ pairs: [(Int, Int)]) -> Set<Cell> {
    Set(pairs.map { Cell(column: $0.0, row: $0.1) })
  }

  @Test func horizontalWin() throws {
    let board = try Board(moves: [0, 0, 1, 1, 2, 2, 3])
    #expect(board.winner == .first)
    #expect(board.winningCells == cells([(0, 0), (1, 0), (2, 0), (3, 0)]))
  }

  @Test func diagonalUpWin() throws {
    let board = try Board(moves: [0, 1, 1, 2, 3, 2, 2, 3, 6, 3, 3])
    #expect(board.winner == .first)
    #expect(board.winningCells == cells([(0, 0), (1, 1), (2, 2), (3, 3)]))
  }

  @Test func diagonalDownWin() throws {
    let board = try Board(moves: [6, 5, 5, 4, 3, 4, 4, 3, 0, 3, 3])
    #expect(board.winner == .first)
    #expect(board.winningCells == cells([(6, 0), (5, 1), (4, 2), (3, 3)]))
  }

  @Test func secondPlayerCanWin() throws {
    let board = try Board(moves: [0, 1, 0, 1, 0, 1, 6, 1])
    #expect(board.winner == .second)
    #expect(board.outcome == .win(.second))
  }

  @Test func noWinnerMidGame() throws {
    let board = try Board(moves: [0, 1, 0, 1, 0])
    #expect(board.winner == nil)
    #expect(board.winningCells == nil)
    #expect(board.outcome == nil)
  }

  @Test func fullDrawnGame() throws {
    let moves = [
      3, 3, 1, 6, 5, 0, 1, 1, 4, 2, 6, 6, 1, 4, 1, 2, 3, 1, 4, 3, 4, 4, 5, 2, 3, 6, 3, 0, 6,
      4, 2, 6, 0, 5, 5, 5, 5, 2, 0, 2, 0, 0,
    ]
    #expect(moves.count == 42)
    let board = try Board(moves: moves)
    #expect(board.isDraw)
    #expect(board.isGameOver)
    #expect(board.winner == nil)
    #expect(board.outcome == .draw)
    #expect(board.legalMoves.isEmpty)
    #expect(board.winningCells == nil)
  }

  @Test func everyColumnFillsAtSix() {
    var board = Board()
    for _ in 0..<6 { board.drop(6) }
    #expect(!board.canPlay(6))
    #expect(board.height(of: 6) == 6)
    #expect(!board.canPlay(-1))
    #expect(!board.canPlay(7))
  }

  @Test func undoAcrossAWin() throws {
    var board = try Board(moves: [0, 1, 0, 1, 0, 1])
    let before = board
    board.drop(0)
    #expect(board.winner == .first)
    board.undo()
    #expect(board.winner == nil)
    #expect(board == before)
    #expect(board.canPlay(0))
  }

  @Test func illegalInputThrows() {
    #expect(throws: BoardError.illegalMove(7, ply: 0)) { try Board(moves: [7]) }
    #expect(throws: BoardError.illegalMove(0, ply: 6)) {
      try Board(moves: [0, 0, 0, 0, 0, 0, 0])
    }
    // Moves after a win are illegal.
    #expect(throws: BoardError.illegalMove(3, ply: 7)) {
      try Board(moves: [0, 1, 0, 1, 0, 1, 0, 3])
    }
  }
}
