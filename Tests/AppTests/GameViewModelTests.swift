import C4AI
import C4Core
import Foundation
import Testing

@testable import LLMConnectFour

@MainActor
@Suite struct GameViewModelTests {
  /// A fast mock: no token delay, a tiny load, and isolated defaults.
  static func makeModel(
    tokenDelay: Duration = .zero, loadDuration: Duration = .milliseconds(20), failure: String? = nil
  ) -> GameViewModel {
    GameViewModel(
      provider: MockMoveProvider(
        tokenDelay: tokenDelay, loadDuration: loadDuration, failure: failure),
      defaults: UserDefaults(suiteName: "GameViewModelTests-\(UUID().uuidString)")!,
      minimumAIDelay: .zero)
  }

  @Test func humanMovesFirst() {
    let model = Self.makeModel()
    #expect(model.isHumanTurn)
    #expect(model.board.toMove == .first)
  }

  @Test func humanMoveTriggersAIMove() async {
    let model = Self.makeModel()
    model.humanDrop(3)
    #expect(model.board.plyCount == 1)
    await model.waitForAITurn()
    #expect(model.board.plyCount == 2)
    #expect(model.isHumanTurn)
    #expect(model.record.traces.count == 1)
    #expect(model.record.traces[0].movesBefore == [3])
    #expect(model.aiTurn?.move != nil)
    #expect(model.aiTurn?.prompt != nil)
    #expect(model.aiTurn?.distribution != nil)
  }

  @Test func inputIsLockedDuringAITurn() async {
    let model = Self.makeModel(tokenDelay: .milliseconds(20))
    model.humanDrop(3)
    #expect(model.isAITurnActive)
    #expect(!model.isHumanTurn)
    model.humanDrop(4)
    #expect(model.board.plyCount == 1)
    #expect(!model.canChangeSettings)
    await model.waitForAITurn()
    #expect(model.board.plyCount == 2)
  }

  @Test func reasoningStreamsDuringTurn() async throws {
    let model = Self.makeModel(tokenDelay: .milliseconds(10))
    model.humanDrop(3)
    try await Task.sleep(for: .milliseconds(120))
    #expect(model.aiTurn?.isStreaming == true)
    #expect(model.aiTurn?.reasoning.isEmpty == false)
    await model.waitForAITurn()
  }

  @Test func newGameCancelsAITurn() async throws {
    let model = Self.makeModel(tokenDelay: .milliseconds(20))
    model.humanDrop(3)
    #expect(model.isAITurnActive)
    model.newGame()
    #expect(!model.isAITurnActive)
    #expect(model.board.plyCount == 0)
    #expect(model.aiTurn == nil)
    // The cancelled turn must not land a disc later.
    try await Task.sleep(for: .milliseconds(800))
    #expect(model.board.plyCount == 0)
    #expect(model.record.traces.isEmpty)
    #expect(model.isHumanTurn)
  }

  @Test func waitsForModelLoadThenPlays() async {
    let model = Self.makeModel(loadDuration: .milliseconds(300))
    #expect(!model.isModelReady)
    model.humanDrop(3)
    #expect(model.status == .warmingUp || model.isModelReady)
    await model.waitForAITurn()
    #expect(model.isModelReady)
    #expect(model.board.plyCount == 2)
    #expect(model.loadProgress?.phase == .ready)
  }

  @Test func winIsDetected() async {
    let model = Self.makeModel()
    // Stack column 1 (index 0); the AI replies wherever it likes. Keep going until the
    // game ends: the human wins vertically unless the AI blocks, in which case try
    // another column, so the loop always ends.
    var columns = [
      0, 0, 0, 0, 6, 6, 6, 6, 1, 1, 1, 1, 5, 5, 5, 5, 2, 2, 2, 2, 4, 4, 4, 4, 3, 3, 3, 3,
    ]
    while !model.board.isGameOver, !columns.isEmpty {
      let column = columns.removeFirst()
      guard model.board.canPlay(column) else { continue }
      model.humanDrop(column)
      await model.waitForAITurn()
    }
    #expect(model.board.isGameOver)
    #expect(model.record.outcome != nil)
    #expect(model.record.finishedAt != nil)
    if model.board.winner != nil {
      #expect(model.winningCells.count >= 4)
    }
    #expect(!model.isHumanTurn)
    model.humanDrop(3)
    #expect(model.record.moves == model.board.moves)
  }

  @Test func scriptedWinHighlightsFourCells() {
    let model = Self.makeModel()
    model.setPosition(DemoPositions.win, aiTurn: nil)
    #expect(model.board.winner == model.aiDisc)
    #expect(
      model.winningCells
        == [
          Cell(column: 6, row: 0), Cell(column: 5, row: 1), Cell(column: 4, row: 2),
          Cell(column: 3, row: 3),
        ])
    #expect(model.status == .gameOver(.win(model.aiDisc)))
  }

  @Test func midgameDemoIsLegalAndOpen() {
    let model = Self.makeModel()
    model.setPosition(DemoPositions.midgame, aiTurn: nil)
    #expect(model.board.plyCount == DemoPositions.midgame.count)
    #expect(!model.board.isGameOver)
    #expect(model.isHumanTurn)
  }

  @Test func failedTurnFallsBack() async {
    let model = Self.makeModel(failure: "boom")
    model.humanDrop(0)
    await model.waitForAITurn()
    #expect(model.board.plyCount == 2)
    #expect(model.record.traces.last?.move.source == .fallback)
    #expect(model.board.moves.last == 3)
  }

  @Test func settingsLockDuringGame() async {
    let model = Self.makeModel()
    #expect(model.canChangeSettings)
    model.difficulty = .hard
    model.humanDrop(3)
    await model.waitForAITurn()
    #expect(!model.canChangeSettings)
    #expect(model.record.difficulty == .hard)
    #expect(model.record.traces.first?.difficulty == .hard)
  }

  @Test func deepThinkNeedsAThinkingModel() {
    let model = Self.makeModel()
    guard let plain = model.models.first(where: { !$0.thinking }),
      let thinker = model.models.first(where: \.thinking)
    else { return }
    model.selectedModelID = thinker.id
    model.style = .deepThink
    #expect(model.effectiveStyle == .deepThink)
    model.selectedModelID = plain.id
    #expect(!model.canDeepThink)
    #expect(model.style == .explain)
  }

  @Test func placedDiscsStackPerColumn() throws {
    let board = try Board(moves: [3, 3, 4])
    let placed = PlacedDisc.all(on: board)
    #expect(
      placed.map(\.cell) == [
        Cell(column: 3, row: 0), Cell(column: 3, row: 1), Cell(column: 4, row: 0),
      ])
    #expect(placed.map(\.disc) == [.first, .second, .first])
  }

  @Test func metricsKeepSevenBySixAndMapColumns() {
    let metrics = BoardMetrics.fitting(CGSize(width: 800, height: 700))
    let size = metrics.plateSize
    #expect(abs(size.width / size.height - 7.0 / 6.0) < 0.0001)
    for column in Board.allColumns {
      #expect(metrics.column(atX: metrics.center(column: column, row: 0).x) == column)
    }
    #expect(metrics.column(atX: -50) == 0)
    #expect(metrics.column(atX: size.width + 50) == 6)
  }
}
