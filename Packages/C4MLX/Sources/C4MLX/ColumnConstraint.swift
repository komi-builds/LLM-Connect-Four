import C4Core

/// The token id of each column digit "1"…"7" as it follows `"Column: "` in one tokenizer
/// (§3.3.1). Index = 0-based column.
public struct DigitTokenMap: Sendable, Hashable, Codable {
    public var tokenIDs: [Int]

    public init(tokenIDs: [Int]) {
        precondition(tokenIDs.count == Board.columnCount)
        self.tokenIDs = tokenIDs
    }
}

public enum ColumnConstraintError: Error, Sendable, Hashable {
    /// The digit for this 1-based column label did not encode as exactly one token after
    /// `"Column: "`. The model is rejected with a clear message.
    case digitNotSingleToken(label: String, tokens: [Int])
}

/// Discovers digit tokens and builds the legal-digit logit mask.
public enum ColumnConstraint {
    /// Tokenizes `"Column: 1"` … `"Column: 7"` and diffs each against `"Column: "` to find
    /// the exact token for each digit, catching tokenizers that merge the space into the
    /// digit. `encode` is the tokenizer's encode function without special tokens.
    public static func discover(encode: (String) -> [Int]) throws(ColumnConstraintError) -> DigitTokenMap {
        fatalError("TODO: agent D")
    }
}
