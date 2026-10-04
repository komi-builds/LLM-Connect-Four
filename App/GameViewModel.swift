import C4AI
import C4Core
import Observation
import os

let gameLog = Logger(subsystem: "com.komi.LLMConnectFour", category: "game")

/// The game loop: human moves, async AI turn, cancellation (§1). Built against
/// `MockMoveProvider` first; the real provider is wired in by the integration step.
@MainActor
@Observable
final class GameViewModel {
    private(set) var board = Board()
    let humanDisc: Disc = .first
    var aiDisc: Disc { humanDisc.opponent }

    let provider: any MoveProvider

    init(provider: any MoveProvider = MockMoveProvider()) {
        self.provider = provider
    }

    var isHumanTurn: Bool { !board.isGameOver && board.toMove == humanDisc }

    func newGame() {
        board = Board()
    }
}
