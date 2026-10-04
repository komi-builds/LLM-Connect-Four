import C4Core
import Testing

@testable import LLMConnectFour

@MainActor
@Suite struct GameViewModelTests {
    @Test func humanMovesFirst() {
        let model = GameViewModel()
        #expect(model.isHumanTurn)
    }
}
