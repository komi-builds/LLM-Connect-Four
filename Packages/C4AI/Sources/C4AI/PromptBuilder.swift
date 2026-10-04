import C4Core

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
public enum PromptBuilder {
    /// Bump whenever any template or encoding changes. Recorded in every trace.
    public static let version = 1

    /// The text the app appends to force the answer. The digit token follows directly.
    public static let answerPrefix = "Column: "

    /// The static prefix for a game.
    public static func systemPrompt(variant: PromptVariant, style: ThinkingStyle) -> String {
        fatalError("TODO: agent B")
    }

    /// The full prompt for the side to move on `board`.
    public static func build(
        board: Board, style: ThinkingStyle, profile: DifficultyProfile, variant: PromptVariant,
        extraFacts: [String] = []
    ) -> Prompt {
        fatalError("TODO: agent B")
    }

    /// Convenience for a turn context.
    public static func build(for context: TurnContext) -> Prompt {
        build(
            board: context.board, style: context.style, profile: context.profile, variant: context.variant,
            extraFacts: context.extraFacts)
    }
}
