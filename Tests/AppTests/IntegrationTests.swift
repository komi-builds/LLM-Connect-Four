import C4AI
import C4Core
import Foundation
import Testing

@testable import LLMConnectFour

/// On a first attempt, deliberately avoids every immediate win and block (playing the first
/// other allowed column); once re-prompted with extra facts, plays the win or block. Lets
/// tests trigger the Hard self-check on purpose.
private struct BlunderingProvider: MoveProvider {
  var name: String { "Blunderer" }

  func move(_ context: TurnContext) -> AsyncStream<TurnEvent> {
    AsyncStream { continuation in
      let prompt = PromptBuilder.build(for: context)
      let board = context.board
      let allowed = prompt.allowedColumns
      let fixes = Tactics.immediateWins(board, for: board.toMove) + Tactics.mustBlock(board)
      let column =
        context.extraFacts.isEmpty
        ? (allowed.first { !fixes.contains($0) } ?? allowed[0])
        : (fixes.first { allowed.contains($0) } ?? allowed[0])
      var probabilities = [Double](repeating: 0, count: Board.columnCount)
      probabilities[column] = 1
      let distribution = ColumnDistribution(
        probabilities: probabilities, masked: Set(Board.allColumns).subtracting(allowed))
      continuation.yield(.prompt(prompt))
      continuation.yield(.distribution(distribution))
      continuation.yield(.decided(AIMove(column: column, distribution: distribution)))
      continuation.finish()
    }
  }
}

@MainActor
@Suite struct IntegrationTests {
  static func defaults() -> UserDefaults {
    UserDefaults(suiteName: "IntegrationTests-\(UUID().uuidString)")!
  }

  static func hardModel() -> GameViewModel {
    let store = defaults()
    store.set(Difficulty.hard.rawValue, forKey: "difficulty")
    return GameViewModel(provider: BlunderingProvider(), defaults: store, minimumAIDelay: .zero)
  }

  @Test func hardSelfCheckCatchesAMissedWin() async {
    let model = Self.hardModel()
    // The AI stacks column 1 while the human plays elsewhere, until it has a win to miss.
    for column in [6, 6, 2, 2] {
      guard model.isHumanTurn else { break }
      model.humanDrop(column)
      await model.waitForAITurn()
    }
    let selfChecked = model.record.traces.filter { $0.move.source == .modelAfterSelfCheck }
    #expect(selfChecked.count == 1)
    #expect(
      selfChecked.first?.prompt?.facts.contains { $0.contains("missed an immediate win") } == true)
    #expect(model.board.winner == model.aiDisc)
  }

  @Test func hardMaskLeavesOnlyTheBlock() async {
    let model = Self.hardModel()
    // The human stacks three in column 4; every other answer would lose at once.
    for _ in 0..<3 {
      model.humanDrop(3)
      await model.waitForAITurn()
    }
    #expect(model.record.traces.last?.prompt?.allowedColumns == [3])
    #expect(model.board.disc(atColumn: 3, row: 3) == model.aiDisc)
  }

  @Test func moderateNeverSelfChecks() async {
    let store = Self.defaults()
    store.set(Difficulty.moderate.rawValue, forKey: "difficulty")
    let model = GameViewModel(
      provider: BlunderingProvider(), defaults: store, minimumAIDelay: .zero)
    for _ in 0..<3 {
      model.humanDrop(3)
      await model.waitForAITurn()
    }
    #expect(model.record.traces.allSatisfy { $0.move.source == .model })
  }

  @Test func engineOpponentPlaysWithoutTheModel() async {
    let store = Self.defaults()
    store.set("engine", forKey: "opponent")
    let model = GameViewModel(
      provider: MockMoveProvider(loadDuration: .seconds(60)), defaults: store,
      minimumAIDelay: .zero)
    #expect(model.opponentName == "Minimax d4")
    model.humanDrop(3)
    await model.waitForAITurn()
    #expect(model.board.plyCount == 2)
    #expect(model.record.traces[0].provider == "Minimax d4")
    #expect(model.record.traces[0].modelID == nil)
  }

  @Test func switchingModelsRebuildsTheProviderAndStartsANewGame() async {
    var made: [String] = []
    let model = GameViewModel(
      providerFactory: { spec in
        made.append(spec.id)
        return MockMoveProvider(name: spec.name, tokenDelay: .zero, loadDuration: .milliseconds(5))
      },
      defaults: Self.defaults(), minimumAIDelay: .zero)
    let other = model.models.first { $0.id != model.selectedModelID }!
    model.selectedModelID = other.id
    #expect(made.count == 2)
    #expect(made.last == other.id)
    #expect(model.provider.name == other.name)
    #expect(model.providerModelID == other.id)
    #expect(model.record.opponentName == other.name)
    model.humanDrop(3)
    await model.waitForAITurn()
    #expect(model.record.traces.last?.modelID == other.id)
  }

  @Test func customModelsAreListedAndPersisted() {
    let store = Self.defaults()
    let model = GameViewModel(defaults: store, minimumAIDelay: .zero, loadImmediately: false)
    model.customModelIDs.append("mlx-community/Tiny-Model-4bit")
    #expect(model.models.contains { $0.id == "mlx-community/Tiny-Model-4bit" })
    let reloaded = GameViewModel(defaults: store, minimumAIDelay: .zero, loadImmediately: false)
    #expect(reloaded.customModelIDs == ["mlx-community/Tiny-Model-4bit"])
  }

  @Test func deepThinkBudgetReachesTheProvider() async {
    let store = Self.defaults()
    store.set("deepThink", forKey: "thinkingStyle")
    store.set(1024, forKey: "deepThinkBudget")
    store.set("mlx-community/Qwen3-1.7B-4bit", forKey: "modelID")
    let model = GameViewModel(
      provider: MockMoveProvider(tokenDelay: .zero, loadDuration: .zero), defaults: store,
      minimumAIDelay: .zero)
    #expect(model.style == .deepThink)
    model.humanDrop(3)
    await model.waitForAITurn()
    // The trace records the style; the budget is checked through the context helper.
    #expect(model.record.traces[0].style == .deepThink)
    #expect(model.deepThinkBudget == 1024)
  }
}
