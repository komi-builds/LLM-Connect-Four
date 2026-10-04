import Foundation

/// One entry in `models.json`. See `Resources/schemas/models.schema.json`.
public struct ModelSpec: Sendable, Hashable, Codable, Identifiable {
    /// Hugging Face repo id, for example `mlx-community/Qwen3-4B-Instruct-2507-4bit`.
    public var id: String
    public var name: String
    public var isDefault: Bool
    /// Approximate download / resident size.
    public var sizeGB: Double
    /// Supports native thinking, so Deep think is offered.
    public var thinking: Bool
    /// Opening and closing think tags, for example `["<think>", "</think>"]`.
    public var thinkTags: [String]?
    /// Extra chat-template arguments. The value `"$deepThink"` is replaced with `true` when
    /// the style is Deep think and `false` otherwise.
    public var chatTemplateArgs: [String: String]?
    public var notes: String?

    enum CodingKeys: String, CodingKey {
        case id, name, sizeGB, thinking, thinkTags, chatTemplateArgs, notes
        case isDefault = "default"
    }

    public init(
        id: String, name: String, isDefault: Bool = false, sizeGB: Double, thinking: Bool,
        thinkTags: [String]? = nil, chatTemplateArgs: [String: String]? = nil, notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.sizeGB = sizeGB
        self.thinking = thinking
        self.thinkTags = thinkTags
        self.chatTemplateArgs = chatTemplateArgs
        self.notes = notes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        sizeGB = try c.decode(Double.self, forKey: .sizeGB)
        thinking = try c.decode(Bool.self, forKey: .thinking)
        thinkTags = try c.decodeIfPresent([String].self, forKey: .thinkTags)
        chatTemplateArgs = try c.decodeIfPresent([String: String].self, forKey: .chatTemplateArgs)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }

    /// A spec for a custom `mlx-community/...` id typed in Settings.
    public static func custom(id: String) -> ModelSpec {
        ModelSpec(id: id, name: id.split(separator: "/").last.map(String.init) ?? id, sizeGB: 0, thinking: false)
    }

    public enum MemoryVerdict: Sendable, Hashable { case ok, warn, refuse }

    /// Warn above 40% of physical memory; refuse above 60% (§12).
    public func memoryVerdict(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> MemoryVerdict {
        let fraction = sizeGB * 1_073_741_824 / Double(physicalMemory)
        if fraction > 0.6 { return .refuse }
        if fraction > 0.4 { return .warn }
        return .ok
    }
}

public enum ModelRegistry {
    /// The models shipped in `models.json`.
    public static func bundled() -> [ModelSpec] {
        guard let url = Bundle.module.url(forResource: "models", withExtension: "json"),
            let models = try? load(from: url)
        else { return [] }
        return models
    }

    public static func load(from url: URL) throws -> [ModelSpec] {
        try JSONDecoder().decode([ModelSpec].self, from: Data(contentsOf: url))
    }

    public static var defaultModel: ModelSpec? {
        let models = bundled()
        return models.first(where: \.isDefault) ?? models.first
    }
}
