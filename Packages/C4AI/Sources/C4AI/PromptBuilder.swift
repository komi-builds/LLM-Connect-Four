import C4Core
import Foundation

/// Which prompt layout to use (§3.1). The default is whichever wins on the leaderboard.
public struct PromptVariant: Sendable, Hashable, Codable {
  public enum BoardView: String, Sendable, Hashable, Codable, CaseIterable {
    /// The 6×7 grid only.
    case grid
    /// The per-column list only (bottom → top, with landing rows).
    case columns
    /// Both.
    case combined
  }

  public var view: BoardView
  /// Include the two worked examples in the static prefix.
  public var fewShot: Bool
  /// Include the "Moves so far" line.
  public var history: Bool

  public init(view: BoardView, fewShot: Bool = true, history: Bool = true) {
    self.view = view
    self.fewShot = fewShot
    self.history = history
  }

  /// Stable id recorded in traces and contestants, for example `"combined"`,
  /// `"grid-nofs"`, `"columns-nofs-nohist"`. The prompt version is recorded separately.
  public var id: String {
    view.rawValue + (fewShot ? "" : "-nofs") + (history ? "" : "-nohist")
  }

  public init?(id: String) {
    guard let match = PromptVariant.all.first(where: { $0.id == id }) else { return nil }
    self = match
  }

  public static let `default` = PromptVariant(view: .combined)

  public static let all: [PromptVariant] = BoardView.allCases.flatMap { view in
    [true, false].flatMap { fewShot in
      [true, false].map { history in PromptVariant(view: view, fewShot: fewShot, history: history) }
    }
  }
}

/// A complete prompt for one move.
public struct Prompt: Sendable, Hashable, Codable {
  /// The static system prefix. Identical for every turn of a game, so its KV cache is
  /// reused. Depends only on variant, style and prompt version.
  public var system: String
  /// The per-turn user message.
  public var user: String
  /// The facts included in `user`, each exactly as it appears there (for highlighting).
  public var facts: [String]
  /// Columns the answer is restricted to (0-based), after difficulty masking.
  public var allowedColumns: [Column]
  public var variantID: String
  /// `PromptBuilder.version` at the time the prompt was built.
  public var version: Int

  public init(
    system: String, user: String, facts: [String], allowedColumns: [Column], variantID: String,
    version: Int
  ) {
    self.system = system
    self.user = user
    self.facts = facts
    self.allowedColumns = allowedColumns
    self.variantID = variantID
    self.version = version
  }
}

/// Builds prompts from versioned templates in `Resources/prompts/`. The side to move on
/// the board is always the model (`O`); the opponent is `X`.
///
/// Template files live in `prompts/v<version>/`: `system.txt` (with `{{style}}`),
/// `style-<style>.txt`, `fewshot.txt` (with `{{turn1}}`, `{{answer1}}`, `{{turn2}}`,
/// `{{answer2}}`), `answers-<style>.txt` (two answers separated by a `---` line) and
/// `turn.txt` (with `{{board}}` and `{{lines}}`). The system prefix never depends on the board.
public enum PromptBuilder {
  /// Bump whenever any template or encoding changes. Recorded in every trace.
  public static let version = 1

  /// The text the app appends to force the answer. The digit token follows directly.
  public static let answerPrefix = "Column: "

  /// The static prefix for a game.
  public static func systemPrompt(variant: PromptVariant, style: ThinkingStyle) -> String {
    var text = template("system").replacingOccurrences(
      of: "{{style}}", with: template("style-\(style.rawValue)"))
    if variant.fewShot {
      let answers = template("answers-\(style.rawValue)").components(separatedBy: "\n---\n")
      precondition(answers.count == 2, "answers-\(style.rawValue).txt must hold two answers")
      let examples = template("fewshot")
        .replacingOccurrences(of: "{{turn1}}", with: turn(PromptExamples.block, variant: variant))
        .replacingOccurrences(of: "{{answer1}}", with: answers[0])
        .replacingOccurrences(of: "{{turn2}}", with: turn(PromptExamples.win, variant: variant))
        .replacingOccurrences(of: "{{answer2}}", with: answers[1])
      text += "\n\n" + examples
    }
    return text
  }

  /// The full prompt for the side to move on `board`.
  public static func build(
    board: Board, style: ThinkingStyle, profile: DifficultyProfile, variant: PromptVariant,
    extraFacts: [String] = []
  ) -> Prompt {
    let facts = PromptFacts.compute(board: board, level: profile.facts) + extraFacts
    let allowed = profile.allowedColumns(on: board)
    let user = turn(
      board, variant: variant, facts: facts,
      showFacts: profile.facts != .none || !extraFacts.isEmpty, allowed: allowed)
    return Prompt(
      system: systemPrompt(variant: variant, style: style), user: user, facts: facts,
      allowedColumns: allowed, variantID: variant.id, version: version)
  }

  /// Convenience for a turn context.
  public static func build(for context: TurnContext) -> Prompt {
    build(
      board: context.board, style: context.style, profile: context.profile,
      variant: context.variant,
      extraFacts: context.extraFacts)
  }

  // MARK: Internals

  /// The per-turn text. With `showFacts` false there is no Facts section at all (Easy).
  /// Otherwise an empty list prints `Facts: none`.
  static func turn(
    _ board: Board, variant: PromptVariant, facts: [String] = [], showFacts: Bool = false,
    allowed: [Column]? = nil
  ) -> String {
    let blocks: [String]
    switch variant.view {
    case .grid: blocks = [BoardEncoder.grid(board)]
    case .columns: blocks = [BoardEncoder.columns(board)]
    case .combined: blocks = [BoardEncoder.grid(board), BoardEncoder.columns(board)]
    }
    var lines: [String] = []
    if variant.history { lines.append(BoardEncoder.history(board)) }
    if showFacts {
      if facts.isEmpty {
        lines.append("Facts: none")
      } else {
        lines.append((["Facts:"] + facts.map { "- " + $0 }).joined(separator: "\n"))
      }
    }
    let legal = (allowed ?? board.legalMoves).map(BoardEncoder.label).joined(separator: " ")
    lines.append("Legal columns: " + legal)
    return template("turn")
      .replacingOccurrences(of: "{{board}}", with: blocks.joined(separator: "\n\n"))
      .replacingOccurrences(of: "{{lines}}", with: lines.joined(separator: "\n"))
  }

  private static func template(_ name: String) -> String {
    guard let text = Templates.files["\(name).txt"] else {
      fatalError("missing prompt template \(name).txt in prompts/v\(version)")
    }
    return text
  }

  /// Every file of `prompts/v<version>/`, read once. Trailing newlines are stripped.
  private enum Templates {
    static let files: [String: String] = {
      let folder = Bundle.module.resourceURL!.appendingPathComponent(
        "prompts/v\(PromptBuilder.version)")
      let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
      var result: [String: String] = [:]
      for name in names where name.hasSuffix(".txt") {
        var text =
          (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? ""
        while text.hasSuffix("\n") { text.removeLast() }
        result[name] = text
      }
      return result
    }()
  }
}
