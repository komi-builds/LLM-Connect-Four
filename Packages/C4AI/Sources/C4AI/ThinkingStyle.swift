/// How much the model thinks before the forced `Column: ` answer (§3.2).
public enum ThinkingStyle: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    /// No generated text: one forward pass after `Column: `.
    case instinct
    /// Short reasoning (about 64 tokens), then the forced answer. The default.
    case explain
    /// Native `<think>…</think>` with a budget, then the forced answer. Only for models
    /// with `thinking: true`.
    case deepThink

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .instinct: "Instinct"
        case .explain: "Explain"
        case .deepThink: "Deep think"
        }
    }

    /// Default token budget. Deep think is adjustable within `deepThinkBudgetRange`.
    public var defaultBudget: Int {
        switch self {
        case .instinct: 0
        case .explain: 64
        case .deepThink: 512
        }
    }

    public static let deepThinkBudgetRange = 128...2048
}
