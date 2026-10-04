import Foundation
import Testing

@testable import C4Core

@Suite struct PuzzleTests {
  @Test func generationIsDeterministic() {
    let a = PuzzleGenerator.generate(seed: 42, perCategory: 3)
    let b = PuzzleGenerator.generate(seed: 42, perCategory: 3)
    #expect(a == b)
    #expect(a.count == 12)
    let c = PuzzleGenerator.generate(seed: 43, perCategory: 3)
    #expect(a != c)
  }

  @Test func generatedPuzzlesPassCheckAndAreWellFormed() {
    let puzzles = PuzzleGenerator.generate(seed: 7, perCategory: 4)
    #expect(Set(puzzles.map(\.id)).count == puzzles.count)
    for puzzle in puzzles {
      #expect(PuzzleGenerator.check(puzzle), "\(puzzle.id)")
      #expect(puzzle.id.hasPrefix(puzzle.category.rawValue + "-"))
      #expect(PuzzleGenerator.moveRangeContains(puzzle.moves.count))
    }
  }

  @Test func checkRejectsWrongSolutions() {
    var puzzle = PuzzleGenerator.generate(seed: 7, perCategory: 1)[0]
    #expect(PuzzleGenerator.check(puzzle))
    puzzle.solutions = [puzzle.solutions[0] == 0 ? 1 : 0]
    #expect(!PuzzleGenerator.check(puzzle))
  }

  @Test func categoriesHaveTheirDefiningProperty() {
    for puzzle in PuzzleGenerator.generate(seed: 11, perCategory: 3) {
      let board = puzzle.board
      switch puzzle.category {
      case .winIn1:
        #expect(puzzle.solutions == Tactics.immediateWins(board, for: board.toMove))
      case .blockIn1:
        #expect(Tactics.immediateWins(board, for: board.toMove).isEmpty)
        #expect(puzzle.solutions == Tactics.mustBlock(board))
        #expect(puzzle.solutions.count == 1)
      case .avoidBlunder:
        #expect(!Tactics.unsafeMoves(board).isEmpty)
        #expect(Set(puzzle.solutions).isDisjoint(with: Tactics.unsafeMoves(board)))
      case .winIn3:
        #expect(Tactics.immediateWins(board, for: board.toMove).isEmpty)
        for column in puzzle.solutions {
          #expect(Engine(depth: 3).scores(board)[column] == 997)
        }
      }
    }
  }
}

// MARK: Engine cross-check against a plain negamax

/// Plain negamax with no pruning and no table. Undecided leaves score 0, so only decided
/// scores (magnitude above 900) are comparable with the engine's heuristic values.
private func bruteForce(_ board: Board, depth: Int) -> Int {
  if board.isDraw || depth == 0 { return 0 }
  return board.legalMoves.map { bruteScore(board, column: $0, depth: depth) }.max()!
}

private func bruteScore(_ board: Board, column: Column, depth: Int) -> Int {
  if board.isWinningMove(column) { return 999 }
  let child = bruteForce(board.dropping(column), depth: depth - 1)
  return child > 900 ? -(child - 1) : child < -900 ? -(child + 1) : -child
}

@Suite struct EngineCrossCheckTests {
  @Test func engineMatchesBruteForceOnDecidedScores() {
    var rng = SplitMix64(seed: 99)
    var checked = 0
    var decided = 0
    while checked < 30 {
      // Longer playouts are more likely to contain decided lines.
      let target = Int(rng.next() % 28) + 4
      var board = Board()
      for _ in 0..<target where !board.isGameOver {
        let legal = board.legalMoves
        board = board.dropping(legal[Int(rng.next() % UInt64(legal.count))])
      }
      guard !board.isGameOver else { continue }
      checked += 1
      for depth in 1...5 {
        let engine = Engine(depth: depth)
        let scores = engine.scores(board)
        for (column, score) in scores {
          let expected = bruteScore(board, column: column, depth: depth)
          if abs(expected) > 900 {
            decided += 1
            #expect(score == expected, "depth \(depth) col \(column) \(board.moves)")
          } else {
            #expect(abs(score) <= 900, "depth \(depth) col \(column) \(board.moves)")
          }
        }
        let best = engine.bestMove(board)
        #expect(scores[best] == scores.values.max())
      }
    }
    #expect(decided > 50, "cross-check saw only \(decided) decided scores")
  }
}
