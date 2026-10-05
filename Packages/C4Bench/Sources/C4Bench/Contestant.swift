import C4AI
import C4Core
import Foundation

/// One configuration that gets a rating (§5.1): an anchor, or
/// `model × thinking style × difficulty × prompt variant`.
public struct Contestant: Sendable, Hashable, Codable, Identifiable {
  public enum Kind: Sendable, Hashable, Codable {
    case random
    case minimax(depth: Int)
    case llm(modelID: String, style: ThinkingStyle, difficulty: Difficulty, variantID: String)
  }

  public var kind: Kind
  /// Display name for the model part, for example "Qwen3 4B".
  public var modelName: String?

  public init(kind: Kind, modelName: String? = nil) {
    self.kind = kind
    self.modelName = modelName
  }

  /// Stable key used in ratings and storage, for example `"random"`, `"minimax-d4"`,
  /// `"llm|mlx-community/Qwen3-4B-Instruct-2507-4bit|explain|hard|combined"`.
  public var id: String {
    switch kind {
    case .random: "random"
    case .minimax(let depth): "minimax-d\(depth)"
    case .llm(let modelID, let style, let difficulty, let variantID):
      ["llm", modelID, style.rawValue, difficulty.rawValue, variantID].joined(separator: "|")
    }
  }

  /// For example "Qwen3 4B · Explain · Hard · combined", "Minimax d4", "Random".
  public var displayName: String {
    switch kind {
    case .random: "Random"
    case .minimax(let depth): "Minimax d\(depth)"
    case .llm(let modelID, let style, let difficulty, let variantID):
      [modelName ?? modelID, style.displayName, difficulty.displayName, variantID].joined(
        separator: " · ")
    }
  }

  public var isAnchor: Bool {
    if case .llm = kind { return false }
    return true
  }

  public static let random = Contestant(kind: .random)
  public static func minimax(_ depth: Int) -> Contestant {
    Contestant(kind: .minimax(depth: depth))
  }

  /// Fixed-strength players that keep the scale stable.
  public static let anchors: [Contestant] = [
    .random, .minimax(1), .minimax(2), .minimax(4), .minimax(6),
  ]
  /// Rated 1000 by definition.
  public static let reference = Contestant.minimax(2)
}

/// The hardware and software a run was made on. Speed columns are only comparable within
/// one machine; strength columns are comparable everywhere.
public struct MachineInfo: Sendable, Hashable, Codable {
  public var chip: String
  public var memoryGB: Int
  public var osVersion: String
  public var appVersion: String
  public var promptVersion: Int

  public init(
    chip: String, memoryGB: Int, osVersion: String, appVersion: String, promptVersion: Int
  ) {
    self.chip = chip
    self.memoryGB = memoryGB
    self.osVersion = osVersion
    self.appVersion = appVersion
    self.promptVersion = promptVersion
  }

  /// For example "Apple M3 Pro · 18 GB".
  public var label: String { "\(chip) · \(memoryGB) GB" }

  public static var current: MachineInfo {
    var size = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
    let chip = String(
      decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return MachineInfo(
      chip: chip.isEmpty ? "Unknown" : chip,
      memoryGB: Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()),
      osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
      appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
      promptVersion: PromptBuilder.version)
  }
}
