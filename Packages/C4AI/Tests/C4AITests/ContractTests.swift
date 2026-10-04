import C4Core
import Foundation
import Testing

@testable import C4AI

@Suite struct ContractTests {
    @Test func registryLoadsBundledModels() {
        let models = ModelRegistry.bundled()
        #expect(models.count == 7)
        #expect(ModelRegistry.defaultModel?.id == "mlx-community/Qwen3-4B-Instruct-2507-4bit")
        #expect(models.first { $0.name == "Qwen3 1.7B" }?.chatTemplateArgs?["enable_thinking"] == "$deepThink")
    }

    @Test func variantIDsRoundTrip() {
        #expect(PromptVariant.all.count == 12)
        #expect(PromptVariant.default.id == "combined")
        for variant in PromptVariant.all { #expect(PromptVariant(id: variant.id) == variant) }
    }

    @Test func softmaxRespectsMask() {
        let d = ColumnDistribution.softmax(logits: [0, 0, 0, 5, 0, 0, 9], allowed: [0, 3])
        #expect(d.probabilities[6] == 0)
        #expect(d.argmax == 3)
        #expect(abs(d.probabilities.reduce(0, +) - 1) < 1e-9)
        var rng = SplitMix64(seed: 1)
        for _ in 0..<50 { #expect([0, 3].contains(d.sample(temperature: 1, using: &rng))) }
    }

    @Test func mockPlaysALegalMove() async throws {
        let board = try Board(moves: [3, 3, 3, 3, 3, 3])
        let mock = MockMoveProvider(tokenDelay: .milliseconds(1))
        let move = try await mock.move(TurnContext(board: board, gameSeed: 7)).finalMove()
        #expect(board.canPlay(move.column))
        #expect(!move.reasoning.isEmpty)
    }

    @Test func mockIsDeterministic() async throws {
        let board = try Board(moves: [3, 2])
        let mock = MockMoveProvider(tokenDelay: .zero)
        let a = try await mock.move(TurnContext(board: board, style: .instinct, gameSeed: 42)).finalMove()
        let b = try await mock.move(TurnContext(board: board, style: .instinct, gameSeed: 42)).finalMove()
        #expect(a.column == b.column)
    }

    @Test func randomProviderIsLegal() async throws {
        let board = try Board(moves: [0, 0, 0, 0, 0, 0])
        let move = try await RandomMoveProvider().move(TurnContext(board: board, gameSeed: 3)).finalMove()
        #expect(move.column != 0)
    }
}
