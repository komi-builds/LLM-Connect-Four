import C4AI
import C4Core
import Foundation
import Testing

@testable import C4Bench

@Suite struct ContestantTests {
    @Test func idsAreStable() {
        #expect(Contestant.reference.id == "minimax-d2")
        let llm = Contestant(
            kind: .llm(modelID: "m/x", style: .explain, difficulty: .hard, variantID: "combined"), modelName: "X")
        #expect(llm.id == "llm|m/x|explain|hard|combined")
        #expect(llm.displayName == "X · Explain · Hard · combined")
    }

    @Test func scoring() {
        let game = BenchGame(
            preset: .quick, first: .random, second: .minimax(2), opening: [], gameSeed: 1, moves: [],
            outcome: .win(.second), traces: [], machine: .current, startedAt: Date(), finishedAt: Date())
        #expect(game.score(for: "random") == 0)
        #expect(game.score(for: "minimax-d2") == 1)
        #expect(game.score(for: "minimax-d4") == nil)
    }
}
