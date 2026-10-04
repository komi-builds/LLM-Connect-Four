import Testing

@testable import C4Core

@Suite struct EngineTests {
  @Test func takesWinInOne() throws {
    let board = try Board(moves: [0, 0, 1, 1, 2, 2])
    for depth in [1, 2, 4] {
      #expect(Engine(depth: depth).bestMove(board) == 3)
      #expect(Engine(depth: depth).scores(board)[3] == 999)
    }
  }

  @Test func blocksInOne() throws {
    let board = try Board(moves: [0, 0, 1, 1, 2])
    for depth in [2, 3, 4, 6] {
      #expect(Engine(depth: depth).bestMove(board) == 3)
    }
  }

  @Test func forcedWinInThree() throws {
    // First has bottom discs 2, 3 under second's 2, 3. Playing 1 or 4 makes an open
    // three, and second cannot block both ends.
    let board = try Board(moves: [2, 2, 3, 3])
    for depth in [3, 4, 5, 7] {
      let engine = Engine(depth: depth)
      let move = engine.bestMove(board)
      #expect([1, 4].contains(move))
      #expect(engine.scores(board)[move] == 997)
    }
  }

  @Test func seesForcedLoss() throws {
    // Second faces an open three: every move loses.
    let board = try Board(moves: [2, 2, 3, 3, 4])
    let scores = Engine(depth: 4).scores(board)
    #expect(scores.values.allSatisfy { $0 < -900 })
  }

  @Test func prefersCentreOnEmptyBoard() {
    for depth in [1, 2, 4, 6] {
      #expect(Engine(depth: depth).bestMove(Board()) == 3)
    }
  }

  @Test func scoresCoverEveryLegalMove() throws {
    let board = try Board(moves: [0, 0, 0, 0, 0, 0])
    let scores = Engine(depth: 3).scores(board)
    #expect(Set(scores.keys) == Set(board.legalMoves))
  }

  @Test func bestMoveMatchesScores() throws {
    let boards = [
      Board(),
      try Board(moves: [3, 3, 2, 4]),
      try Board(moves: [3, 2, 3, 2, 4, 5, 1]),
    ]
    for board in boards {
      for depth in [1, 2, 3, 5] {
        let engine = Engine(depth: depth)
        let scores = engine.scores(board)
        let top = scores.values.max()!
        let expected = Engine.columnOrder.first { scores[$0] == top }
        #expect(engine.bestMove(board) == expected)
      }
    }
  }

  @Test func deterministic() throws {
    let board = try Board(moves: [3, 2, 3, 4, 1])
    let engine = Engine(depth: 6)
    #expect(engine.bestMove(board) == engine.bestMove(board))
    #expect(engine.scores(board) == engine.scores(board))
  }

  @Test func drawScoresZeroOnLastMove() throws {
    let moves = [
      3, 3, 1, 6, 5, 0, 1, 1, 4, 2, 6, 6, 1, 4, 1, 2, 3, 1, 4, 3, 4, 4, 5, 2, 3, 6, 3, 0, 6,
      4, 2, 6, 0, 5, 5, 5, 5, 2, 0, 2, 0,
    ]
    let board = try Board(moves: moves)
    #expect(Engine(depth: 3).scores(board) == [0: 0])
    #expect(Engine(depth: 3).bestMove(board) == 0)
  }
}

@Suite struct EnginePerformanceTests {
  #if DEBUG
    static let limit = Duration.seconds(5)
  #else
    static let limit = Duration.milliseconds(100)
  #endif

  static let positions: [[Column]] = [
    [],
    [3, 3, 2, 4, 2, 2, 4, 4, 1, 5],
    [3, 2, 3, 2, 4, 5, 4, 3, 2, 2, 3, 4],
    [3, 4, 3, 4, 2, 2, 4, 3, 1, 1, 5, 0],
    [3, 4, 3, 4, 3, 2, 4, 2, 2, 5, 5, 1, 6],
  ]

  @Test(arguments: positions)
  func depthSevenIsFast(moves: [Column]) throws {
    let board = try Board(moves: moves)
    try #require(!board.isGameOver)
    let engine = Engine(depth: 7)
    let clock = ContinuousClock()
    var move = -1
    let elapsed = clock.measure { move = engine.bestMove(board) }
    print("depth-7 bestMove for \(moves) = \(move) in \(elapsed)")
    #expect(board.canPlay(move))
    #expect(elapsed < Self.limit)
  }
}
