import Testing

@testable import C4Core

@Suite struct TacticsTests {
  /// First has 0, 1, 2 on the bottom row; second to move must block column 3.
  private let rowThreat = try! Board(moves: [0, 0, 1, 1, 2])
  /// Same, with first to move: first wins at column 3.
  private let rowWin = try! Board(moves: [0, 0, 1, 1, 2, 2])
  /// Second has row 1 columns 0...2 and an unplayable winning cell at (3, 1).
  private let trap = try! Board(moves: [0, 0, 2, 1, 6, 2, 5, 1])
  /// First has an open three on the bottom row (2, 3, 4): second faces two threats.
  private let doubleThreat = try! Board(moves: [2, 2, 3, 3, 4])

  @Test func immediateWins() {
    #expect(Tactics.immediateWins(rowWin, for: .first) == [3])
    #expect(Tactics.immediateWins(rowWin, for: .second).isEmpty)
    #expect(Tactics.immediateWins(rowThreat, for: .first) == [3])
    #expect(Tactics.immediateWins(doubleThreat, for: .first) == [1, 5])
    #expect(Tactics.immediateWins(Board(), for: .first).isEmpty)
  }

  @Test func immediateWinsIgnoresUnplayableCells() {
    #expect(Tactics.immediateWins(trap, for: .second).isEmpty)
  }

  @Test func immediateWinsEmptyWhenOver() throws {
    let over = try Board(moves: [0, 0, 1, 1, 2, 2, 3])
    #expect(Tactics.immediateWins(over, for: .first).isEmpty)
  }

  @Test func mustBlock() {
    #expect(Tactics.mustBlock(rowThreat) == [3])
    #expect(Tactics.mustBlock(doubleThreat) == [1, 5])
    #expect(Tactics.mustBlock(Board()).isEmpty)
  }

  @Test func unsafeMovesIncludesPlayingUnderAThreat() {
    #expect(Tactics.unsafeMoves(trap) == [3])
  }

  @Test func unsafeMovesWhenNotBlocking() {
    // Second ignores the threat at column 3: every move except 3 is unsafe.
    #expect(Tactics.unsafeMoves(rowThreat) == [0, 1, 2, 4, 5, 6])
  }

  @Test func unsafeMovesEmptyOnEmptyBoard() {
    #expect(Tactics.unsafeMoves(Board()).isEmpty)
  }

  @Test func threatsCreated() {
    #expect(Tactics.threatsCreated(trap) == [3: 1, 4: 1])
    #expect(Tactics.threatsCreated(Board()).isEmpty)
  }

  @Test func threatsCreatedCountsOnlyNewThreats() {
    // First already threatens column 3; that existing threat is not counted again.
    let created = Tactics.threatsCreated(rowWin)
    #expect(created[3] == nil)
  }

  @Test func openThreeCreatesTwoThreats() throws {
    let board = try Board(moves: [2, 2, 3, 3])
    let created = Tactics.threatsCreated(board)
    #expect(created[4] == 2)
    #expect(created[1] == 2)
  }

  @Test func missedWin() {
    #expect(Tactics.blunder(on: rowWin, played: 4) == .missedWin)
    #expect(Tactics.blunder(on: rowWin, played: 3) == nil)
  }

  @Test func missedBlock() {
    #expect(Tactics.blunder(on: rowThreat, played: 5) == .missedBlock)
    #expect(Tactics.blunder(on: rowThreat, played: 3) == nil)
  }

  @Test func twoThreatsBlockingOneIsNotAMissedBlock() {
    #expect(Tactics.blunder(on: doubleThreat, played: 1) == nil)
    #expect(Tactics.blunder(on: doubleThreat, played: 5) == nil)
    #expect(Tactics.blunder(on: doubleThreat, played: 0) == .missedBlock)
  }

  @Test func winningTakesPriorityOverBlocking() throws {
    // Both sides threaten column 3 on the bottom row; the mover wins there.
    let board = try Board(moves: [0, 4, 1, 5, 2, 6])
    #expect(Tactics.blunder(on: board, played: 3) == nil)
    #expect(Tactics.blunder(on: board, played: 0) == .missedWin)
  }

  @Test func noBlunderOnQuietPosition() {
    #expect(Tactics.blunder(on: Board(), played: 3) == nil)
  }
}
