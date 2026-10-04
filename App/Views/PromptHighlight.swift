import C4AI
import Foundation
import SwiftUI

/// Finds the facts inside a prompt and marks them for the "What the model sees" view.
enum PromptHighlight {
  /// The range of the first occurrence of each fact in `text`, in fact order. Facts that
  /// do not appear are skipped (the prompt builder guarantees they do).
  static func ranges(of facts: [String], in text: String) -> [Range<String.Index>] {
    facts.compactMap { fact in
      fact.isEmpty ? nil : text.range(of: fact)
    }
  }

  /// `text` as an attributed string with a tinted background behind every fact.
  static func attributed(_ text: String, facts: [String]) -> AttributedString {
    var result = AttributedString(text)
    for range in ranges(of: facts, in: text) {
      if let lower = AttributedString.Index(range.lowerBound, within: result),
        let upper = AttributedString.Index(range.upperBound, within: result)
      {
        result[lower..<upper].backgroundColor = DesignTokens.Colors.factHighlight
      }
    }
    return result
  }
}
