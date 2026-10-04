import C4Core

/// The token id of each column digit "1"…"7" as it follows the forced answer prefix in one
/// tokenizer (§3.3.1). Index = 0-based column.
public struct DigitTokenMap: Sendable, Hashable, Codable {
  public var tokenIDs: [Int]
  /// The exact text the app appends before the digit. Normally `"Column: "`. For a
  /// tokenizer that merges the space into the digit (`" 4"` is one token), it is
  /// `"Column:"` and each entry of `tokenIDs` is the space-plus-digit token.
  public var answerPrefix: String

  public init(tokenIDs: [Int], answerPrefix: String = ColumnConstraint.answerPrefix) {
    precondition(tokenIDs.count == Board.columnCount)
    self.tokenIDs = tokenIDs
    self.answerPrefix = answerPrefix
  }

  /// The 0-based column for a token id, if it is one of the digit tokens.
  public func column(forToken id: Int) -> Column? {
    tokenIDs.firstIndex(of: id)
  }
}

public enum ColumnConstraintError: Error, Sendable, Hashable, CustomStringConvertible {
  /// The digit for this 1-based column label did not encode as exactly one token after
  /// `"Column: "`. The model is rejected with a clear message.
  case digitNotSingleToken(label: String, tokens: [Int])
  /// Two columns mapped to the same token.
  case duplicateDigitToken(Int)

  public var description: String {
    switch self {
    case .digitNotSingleToken(let label, let tokens):
      "This model's tokenizer does not encode the column digit \"\(label)\" as a single token "
        + "after \"Column: \" (got \(tokens.count) tokens: \(tokens)), so its answer can't be "
        + "constrained to a legal column."
    case .duplicateDigitToken(let id):
      "Two column digits share token \(id), so the answer can't be constrained."
    }
  }
}

/// Discovers digit tokens and builds the legal-digit logit mask.
public enum ColumnConstraint {
  /// The forced answer prefix. Equal to `PromptBuilder.answerPrefix`.
  public static let answerPrefix = "Column: "

  /// Tokenizes `"Column: 1"` … `"Column: 7"` and diffs each against `"Column: "` to find
  /// the exact token for each digit. If the tokenizer merges the space into the digit
  /// (so `"Column: "` and `"Column: 4"` disagree before the digit), it retries with the
  /// prefix `"Column:"` and the space-plus-digit token, recorded in
  /// `DigitTokenMap.answerPrefix`. If neither works for every digit, it throws
  /// `digitNotSingleToken`. `encode` is the tokenizer's encode function without special
  /// tokens.
  public static func discover(encode: (String) -> [Int]) throws(ColumnConstraintError)
    -> DigitTokenMap
  {
    let spaced = answerPrefix
    let unspaced = String(answerPrefix.dropLast())
    // First choice: "Column: " then a bare digit token.
    if let ids = singleTokenDiffs(prefix: spaced, suffixes: labels, encode: encode) {
      return try validated(DigitTokenMap(tokenIDs: ids, answerPrefix: spaced))
    }
    // Merged-space tokenizers: "Column:" then a " N" token.
    if let ids = singleTokenDiffs(
      prefix: unspaced, suffixes: labels.map { " " + $0 }, encode: encode)
    {
      return try validated(DigitTokenMap(tokenIDs: ids, answerPrefix: unspaced))
    }
    // Report the first digit that fails the primary form.
    let base = encode(spaced)
    for label in labels {
      let full = encode(spaced + label)
      if !(full.count == base.count + 1 && full.starts(with: base)) {
        let extra = full.starts(with: base) ? Array(full.dropFirst(base.count)) : full
        throw .digitNotSingleToken(label: label, tokens: extra)
      }
    }
    throw .digitNotSingleToken(label: "1", tokens: [])
  }

  /// Sets every logit except the allowed columns' digit tokens to −∞. `logits` covers the
  /// whole vocabulary. This is the CPU reference; `LLMMoveProvider` gathers the seven digit
  /// logits on the GPU and applies the same mask to them, which is equivalent.
  public static func mask(logits: [Float], allowed: [Column], digits: DigitTokenMap) -> [Float] {
    var masked = [Float](repeating: -.infinity, count: logits.count)
    for column in allowed {
      let id = digits.tokenIDs[column]
      if logits.indices.contains(id) { masked[id] = logits[id] }
    }
    return masked
  }

  /// The seven digit logits (index = column) read from a full-vocabulary logit vector.
  public static func digitLogits(_ logits: [Float], digits: DigitTokenMap) -> [Double] {
    digits.tokenIDs.map { Double(logits[$0]) }
  }

  /// Whether the highest of the seven digit logits, before any masking, is a column that
  /// can be played on `board` (§3.3.6).
  public static func unmaskedTopChoiceLegal(digitLogits: [Double], board: Board) -> Bool {
    guard let top = digitLogits.indices.max(by: { digitLogits[$0] < digitLogits[$1] }) else {
      return false
    }
    return board.canPlay(top)
  }

  static let labels = (1...Board.columnCount).map(String.init)

  private static func singleTokenDiffs(
    prefix: String, suffixes: [String], encode: (String) -> [Int]
  ) -> [Int]? {
    let base = encode(prefix)
    var ids: [Int] = []
    for suffix in suffixes {
      let full = encode(prefix + suffix)
      guard full.count == base.count + 1, full.starts(with: base) else { return nil }
      ids.append(full[base.count])
    }
    return ids
  }

  private static func validated(_ map: DigitTokenMap) throws(ColumnConstraintError) -> DigitTokenMap
  {
    var seen = Set<Int>()
    for id in map.tokenIDs where !seen.insert(id).inserted { throw .duplicateDigitToken(id) }
    return map
  }
}
