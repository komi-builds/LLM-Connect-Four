import Testing

@testable import C4MLX

@Suite struct ColumnConstraintTests {
    @Test func placeholder() {
        #expect(DigitTokenMap(tokenIDs: [1, 2, 3, 4, 5, 6, 7]).tokenIDs.count == 7)
    }
}
