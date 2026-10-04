import C4AI
import C4Core
import Testing

@testable import C4MLX

/// A tiny greedy tokenizer over a fixed vocabulary, for testing digit discovery.
private struct FakeTokenizer {
  var vocab: [String: Int]

  func encode(_ text: String) -> [Int] {
    let pieces = vocab.keys.sorted { $0.count > $1.count }
    var rest = Substring(text)
    var ids: [Int] = []
    while !rest.isEmpty {
      guard let piece = pieces.first(where: { rest.hasPrefix($0) }) else {
        ids.append(-1)
        rest = rest.dropFirst()
        continue
      }
      ids.append(vocab[piece]!)
      rest = rest.dropFirst(piece.count)
    }
    return ids
  }

  /// "Column", ":", " " and single digits are separate tokens (Qwen, Llama style).
  static let normal: FakeTokenizer = {
    var vocab = ["Column": 100, ":": 101, " ": 102]
    for d in 1...9 { vocab[String(d)] = d }
    return FakeTokenizer(vocab: vocab)
  }()

  /// The space merges into the digit: " 4" is one token (SentencePiece style).
  static let mergedSpace: FakeTokenizer = {
    var vocab = normal.vocab
    for d in 1...9 { vocab[" " + String(d)] = 200 + d }
    return FakeTokenizer(vocab: vocab)
  }()

  /// Digits have no tokens of their own, so each becomes two byte tokens.
  static let splitDigit: FakeTokenizer = {
    var vocab = ["Column": 100, ":": 101, " ": 102]
    for d in 1...9 { vocab[String(d)] = nil }
    return FakeTokenizer(vocab: vocab)
  }()
}

@Suite struct ColumnConstraintTests {
  @Test func normalTokenizer() throws {
    let map = try ColumnConstraint.discover(encode: FakeTokenizer.normal.encode)
    #expect(map.tokenIDs == [1, 2, 3, 4, 5, 6, 7])
    #expect(map.answerPrefix == "Column: ")
    #expect(map.column(forToken: 4) == 3)
  }

  @Test func mergedSpaceTokenizer() throws {
    let map = try ColumnConstraint.discover(encode: FakeTokenizer.mergedSpace.encode)
    #expect(map.tokenIDs == [201, 202, 203, 204, 205, 206, 207])
    #expect(map.answerPrefix == "Column:")
  }

  @Test func splitDigitIsRejected() {
    // Digits fall back to two unknown "byte" tokens each.
    let encode: (String) -> [Int] = { text in
      FakeTokenizer.splitDigit.encode(text).flatMap { $0 == -1 ? [-1, -2] : [$0] }
    }
    #expect(throws: ColumnConstraintError.digitNotSingleToken(label: "1", tokens: [-1, -2])) {
      try ColumnConstraint.discover(encode: encode)
    }
  }

  @Test func oneBadDigitIsReported() {
    var vocab = FakeTokenizer.normal.vocab
    vocab["5"] = nil
    vocab["5a"] = 55
    let encode: (String) -> [Int] = { text in
      FakeTokenizer(vocab: vocab).encode(text).flatMap { $0 == -1 ? [-7, -8] : [$0] }
    }
    #expect(throws: ColumnConstraintError.digitNotSingleToken(label: "5", tokens: [-7, -8])) {
      try ColumnConstraint.discover(encode: encode)
    }
  }

  @Test func duplicateTokensAreRejected() {
    let encode: (String) -> [Int] = { text in
      let base = FakeTokenizer.normal.encode(text)
      return base.map { $0 == 7 ? 6 : $0 }
    }
    #expect(throws: ColumnConstraintError.duplicateDigitToken(6)) {
      try ColumnConstraint.discover(encode: encode)
    }
  }

  @Test func maskKeepsOnlyAllowedDigits() {
    let map = DigitTokenMap(tokenIDs: [10, 11, 12, 13, 14, 15, 16])
    let logits = (0..<32).map { Float($0) }
    let masked = ColumnConstraint.mask(logits: logits, allowed: [0, 3, 6], digits: map)
    #expect(masked.count == 32)
    for (id, value) in masked.enumerated() {
      if [10, 13, 16].contains(id) {
        #expect(value == Float(id))
      } else {
        #expect(value == -.infinity)
      }
    }
  }

  @Test func maskedSoftmaxMatchesDistribution() {
    let map = DigitTokenMap(tokenIDs: [10, 11, 12, 13, 14, 15, 16])
    var logits = [Float](repeating: 0, count: 32)
    for (column, id) in map.tokenIDs.enumerated() { logits[id] = Float(column) }
    logits[20] = 100  // a non-digit token that would win unmasked
    let digitLogits = ColumnConstraint.digitLogits(logits, digits: map)
    let distribution = ColumnDistribution.softmax(logits: digitLogits, allowed: [1, 2])
    #expect(distribution.masked == [0, 3, 4, 5, 6])
    #expect(abs(distribution.probabilities[2] - 1 / (1 + 1 / 2.718281828)) < 1e-6)
    #expect(distribution.argmax == 2)
  }

  @Test func unmaskedTopChoiceLegality() throws {
    // Column 3 (0-based) is full.
    let board = try Board(moves: [3, 3, 3, 3, 3, 3])
    var digitLogits = [Double](repeating: 0, count: 7)
    digitLogits[3] = 5
    #expect(!ColumnConstraint.unmaskedTopChoiceLegal(digitLogits: digitLogits, board: board))
    digitLogits[2] = 6
    #expect(ColumnConstraint.unmaskedTopChoiceLegal(digitLogits: digitLogits, board: board))
  }
}

@Suite struct LLMMoveProviderTests {
  private static func prompt(_ context: TurnContext) -> Prompt {
    Prompt(
      system: "system", user: "user", facts: [],
      allowedColumns: Board.allColumns.filter(context.board.canPlay),
      variantID: context.variant.id, version: 0)
  }

  @Test func unloadedProviderFailsAfterPrompt() async {
    let spec = ModelSpec(id: "mlx-community/none", name: "None", sizeGB: 1, thinking: false)
    let provider = LLMMoveProvider(spec: spec, promptBuilder: Self.prompt)
    #expect(await !provider.isReady)
    var events: [TurnEvent] = []
    for await event in provider.move(TurnContext(board: Board(), gameSeed: 1)) {
      events.append(event)
    }
    #expect(events.count == 2)
    guard case .prompt(let prompt) = events.first else {
      Issue.record("first event is not .prompt")
      return
    }
    #expect(prompt.user == "user")
    guard case .failed = events.last else {
      Issue.record("last event is not .failed")
      return
    }
  }

  @Test func oversizedModelIsRefused() async {
    let spec = ModelSpec(id: "mlx-community/huge", name: "Huge", sizeGB: 1000, thinking: false)
    let provider = LLMMoveProvider(spec: spec, promptBuilder: Self.prompt)
    await #expect(throws: LLMProviderError.self) {
      try await provider.load { _ in }
    }
    #expect(await !provider.isReady)
  }
}
