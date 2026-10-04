import Foundation
import Testing

@testable import C4Core

@Suite struct BoardTests {
  @Test func emptyBoard() {
    let board = Board()
    #expect(board.toMove == .first)
    #expect(board.legalMoves == [0, 1, 2, 3, 4, 5, 6])
    #expect(board.winner == nil)
    #expect(!board.isGameOver)
  }

  @Test func gravityAndOwnership() throws {
    let board = try Board(moves: [3, 3, 4])
    #expect(board.disc(atColumn: 3, row: 0) == .first)
    #expect(board.disc(atColumn: 3, row: 1) == .second)
    #expect(board.disc(atColumn: 4, row: 0) == .first)
    #expect(board.disc(atColumn: 4, row: 1) == nil)
    #expect(board.height(of: 3) == 2)
    #expect(board.toMove == .second)
  }

  @Test func verticalWin() throws {
    let board = try Board(moves: [0, 1, 0, 1, 0, 1, 0])
    #expect(board.winner == .first)
    #expect(board.legalMoves.isEmpty)
    #expect(board.winningCells == Set((0..<4).map { Cell(column: 0, row: $0) }))
  }

  @Test func undoRestoresPosition() throws {
    var board = try Board(moves: [3, 2, 3, 2, 3])
    let before = board
    board.drop(4)
    board.undo()
    #expect(board == before)
  }

  @Test func fullColumnIsIllegal() throws {
    let board = try Board(moves: [0, 0, 0, 0, 0, 0])
    #expect(!board.canPlay(0))
    #expect(board.legalMoves == [1, 2, 3, 4, 5, 6])
  }

  @Test func codableRoundTrip() throws {
    let board = try Board(moves: [3, 4, 2, 5])
    let data = try JSONEncoder().encode(board)
    #expect(String(decoding: data, as: UTF8.self) == "[3,4,2,5]")
    #expect(try JSONDecoder().decode(Board.self, from: data) == board)
  }
}
