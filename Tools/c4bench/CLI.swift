import C4AI
import C4Bench
import C4Core
import C4MLX
import Foundation

/// Plain argument parsing: `--name value` options (repeatable) and `--flag` switches.
struct Arguments {
  var values: [String: [String]] = [:]
  var flags: Set<String> = []
  var positional: [String] = []

  static let flagNames: Set<String> = ["mock", "machine-filter", "help", "quiet"]

  init(_ args: [String]) throws {
    var index = 0
    while index < args.count {
      let arg = args[index]
      if arg.hasPrefix("--") {
        let name = String(arg.dropFirst(2))
        if Self.flagNames.contains(name) {
          flags.insert(name)
        } else {
          guard index + 1 < args.count else { throw CLIError("option --\(name) needs a value") }
          index += 1
          values[name, default: []].append(args[index])
        }
      } else {
        positional.append(arg)
      }
      index += 1
    }
  }

  func all(_ name: String) -> [String] { values[name] ?? [] }
  func one(_ name: String) -> String? { values[name]?.last }
}

struct CLIError: Error, CustomStringConvertible {
  var description: String
  init(_ description: String) { self.description = description }
}

enum CLI {
  static let usage = """
    usage:
      c4bench run --model <id|name> [--model ...] [--style instinct|explain|deepThink] [--difficulty easy|moderate|hard]
                  [--variant <id>] [--suite quick|standard|full] [--out <dir>] [--games <n per anchor>] [--mock [--mock-delay <ms per token>]]
      c4bench puzzles --model <id|name> [--style ...] [--difficulty ...] [--variant <id>] [--out <dir>] [--mock]
      c4bench report [--format md|csv|json] [--out <file>] [--dir <data dir>] [--machine-filter]
      c4bench gen-puzzles [--seed <n>] [--per-category <k>] [--out <file>]
      c4bench models

    --style, --difficulty, --variant and --model can be repeated to sweep a grid.
    Results are saved per game under ~/Library/Application Support/LLMConnectFour/bench/ (or --out);
    Ctrl-C stops after the current move and a rerun resumes where it left off.
    """

  static func main(_ args: [String]) async -> Int32 {
    guard let command = args.first, command != "--help", command != "help" else {
      print(usage)
      return args.isEmpty ? 1 : 0
    }
    do {
      let parsed = try Arguments(Array(args.dropFirst()))
      if parsed.flags.contains("help") {
        print(usage)
        return 0
      }
      switch command {
      case "run": return try await run(parsed, puzzlesOnly: false)
      case "puzzles": return try await run(parsed, puzzlesOnly: true)
      case "report": return try report(parsed)
      case "gen-puzzles": return try genPuzzles(parsed)
      case "models": return listModels()
      default:
        throw CLIError("unknown command '\(command)'\n\n\(usage)")
      }
    } catch {
      FileHandle.standardError.write(Data("c4bench: \(error)\n".utf8))
      return 1
    }
  }

  // MARK: run / puzzles

  static func run(_ args: Arguments, puzzlesOnly: Bool) async throws -> Int32 {
    let mock = args.flags.contains("mock")
    let models = ModelRegistry.bundled()
    var specs: [ModelSpec] = []
    let requested = args.all("model")
    if requested.isEmpty {
      if mock {
        specs = [ModelSpec(id: "mock/mock-model", name: "Mock Model", sizeGB: 0, thinking: true)]
      } else if let def = ModelRegistry.defaultModel {
        specs = [def]
      } else {
        throw CLIError("no --model given and no default model is bundled")
      }
    }
    for name in requested { specs.append(try resolve(name, in: models, mock: mock)) }

    let styles = try args.all("style").map(parseStyle)
    let difficulties = try args.all("difficulty").map(parseDifficulty)
    let variants = try args.all("variant").map { id -> String in
      guard PromptVariant(id: id) != nil else {
        throw CLIError(
          "unknown prompt variant '\(id)'; known: \(PromptVariant.all.map(\.id).joined(separator: ", "))"
        )
      }
      return id
    }
    let preset = try parsePreset(args.one("suite") ?? "quick")

    var contestants: [Contestant] = []
    for spec in specs {
      if !mock {
        switch spec.memoryVerdict() {
        case .refuse:
          print(
            "skipping \(spec.name): about \(spec.sizeGB) GB is more than 60% of this Mac's memory")
          continue
        case .warn:
          print(
            "warning: \(spec.name) is about \(spec.sizeGB) GB, more than 40% of this Mac's memory")
        case .ok: break
        }
      }
      for style in styles.isEmpty ? [.explain] : styles {
        if style == .deepThink && !spec.thinking {
          print("skipping Deep think for \(spec.name): the model has no native thinking")
          continue
        }
        for difficulty in difficulties.isEmpty ? [.moderate] : difficulties {
          for variant in variants.isEmpty ? [PromptVariant.default.id] : variants {
            contestants.append(
              Contestant(
                kind: .llm(
                  modelID: spec.id, style: style, difficulty: difficulty, variantID: variant),
                modelName: spec.name))
          }
        }
      }
    }
    guard !contestants.isEmpty else { throw CLIError("nothing to run") }

    let directory = (args.one("out") ?? args.one("dir")).map {
      URL(fileURLWithPath: $0, isDirectory: true)
    }
    let store = directory.map { BenchStore(directory: $0) } ?? BenchStore()
    let puzzles = BenchPuzzles.bundled()
    if puzzles.isEmpty { print("warning: no bundled puzzles found") }
    var config = BenchConfiguration(
      preset: preset, contestants: contestants, puzzles: puzzles,
      models: models
        + specs.filter { s in
          !models.contains { $0.id == s.id }
        })
    config.includeGames = !puzzlesOnly
    if let games = args.one("games") {
      guard let n = Int(games), n > 0 else { throw CLIError("--games needs a positive number") }
      config.gamesPerAnchor = n
    }

    let mockDelay = Duration.milliseconds(Int(args.one("mock-delay") ?? "0") ?? 0)
    let byID = Dictionary(specs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let factory = BenchProviders.standard { modelID in
      let spec = byID[modelID] ?? .custom(id: modelID)
      if mock {
        return MockMoveProvider(
          name: spec.name, tokenDelay: mockDelay, loadDuration: .milliseconds(20))
      }
      return LLMMoveProvider(spec: spec)
    }
    let runner = BenchRunner(configuration: config, store: store, providers: factory)

    let what = puzzlesOnly ? "puzzles" : "\(preset.rawValue) suite"
    print("c4bench: \(what), \(contestants.count) contestant(s), data in \(store.directory.path)")
    for contestant in contestants { print("  - \(contestant.displayName)") }
    print("Ctrl-C stops after the current move; run the same command again to resume.")

    let printer = ProgressPrinter(quiet: args.flags.contains("quiet"))
    let task = Task { try await runner.run { printer.update($0) } }
    let interrupts = InterruptCounter()
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    source.setEventHandler {
      if interrupts.increment() == 1 {
        FileHandle.standardError.write(
          Data("\nstopping after the current move (Ctrl-C again to quit now)...\n".utf8))
        task.cancel()
      } else {
        exit(130)
      }
    }
    source.resume()
    defer { source.cancel() }

    let summary = try await task.value
    printer.finish()
    print(
      "games: \(summary.gamesPlayed) played, \(summary.gamesResumed) already done; puzzles: \(summary.puzzlesAnswered) answered, \(summary.puzzlesResumed) already done; \(String(format: "%.1f", summary.seconds)) s"
    )
    for note in summary.notes { print("note: \(note)") }
    if summary.cancelled {
      print("cancelled; finished work is saved, rerun to resume")
      return 130
    }
    print("next: c4bench report")
    return 0
  }

  // MARK: report

  static func report(_ args: Arguments) throws -> Int32 {
    let format: ReportFormat
    if let name = args.one("format") {
      guard let parsed = ReportFormat(rawValue: name) else {
        throw CLIError("unknown format '\(name)' (md, csv, json)")
      }
      format = parsed
    } else {
      format = .md
    }
    let store =
      args.one("dir").map { BenchStore(directory: URL(fileURLWithPath: $0, isDirectory: true)) }
      ?? BenchStore()
    let games = store.loadGames()
    let attempts = store.loadPuzzleAttempts()
    guard !games.isEmpty || !attempts.isEmpty else {
      throw CLIError("no results in \(store.directory.path); run `c4bench run` first")
    }
    let machine: MachineInfo? = args.flags.contains("machine-filter") ? .current : nil
    let rows = Leaderboard.compute(games: games, puzzles: attempts, machine: machine)
    let text = ReportWriter.render(rows, format: format, machine: machine)
    if let out = args.one("out") {
      try text.write(toFile: out, atomically: true, encoding: .utf8)
      print("wrote \(out) (\(rows.count) contestants from \(games.count) games)")
    } else {
      print(text, terminator: text.hasSuffix("\n") ? "" : "\n")
    }
    return 0
  }

  // MARK: gen-puzzles

  static func genPuzzles(_ args: Arguments) throws -> Int32 {
    let seed: UInt64
    if let text = args.one("seed") {
      guard let n = UInt64(text) else { throw CLIError("--seed needs a number") }
      seed = n
    } else {
      seed = 20_260_101
    }
    let per: Int
    if let text = args.one("per-category") {
      guard let n = Int(text), n > 0 else {
        throw CLIError("--per-category needs a positive number")
      }
      per = n
    } else {
      per = 38
    }
    let start = Date()
    let puzzles = PuzzleGenerator.generate(seed: seed, perCategory: per)
    let counts = PuzzleCategory.allCases.map { c in
      "\(c.rawValue): \(puzzles.filter { $0.category == c }.count)"
    }
    let data = try PuzzleGenerator.encode(puzzles)
    let message =
      "generated \(puzzles.count) puzzles with seed \(seed) in \(String(format: "%.1f", Date().timeIntervalSince(start))) s (\(counts.joined(separator: ", ")))\n"
    if let out = args.one("out") {
      try data.write(to: URL(fileURLWithPath: out))
      print(message, terminator: "")
    } else {
      FileHandle.standardError.write(Data(message.utf8))
      FileHandle.standardOutput.write(data)
    }
    return 0
  }

  static func listModels() -> Int32 {
    for model in ModelRegistry.bundled() {
      print(
        "\(model.id)  \(model.name)  \(model.sizeGB) GB\(model.thinking ? "  thinking" : "")\(model.isDefault ? "  (default)" : "")"
      )
    }
    return 0
  }

  // MARK: parsing

  static func resolve(_ name: String, in models: [ModelSpec], mock: Bool) throws -> ModelSpec {
    let lower = name.lowercased()
    if let exact = models.first(where: {
      $0.id.lowercased() == lower || $0.name.lowercased() == lower
    }) {
      return exact
    }
    let partial = models.filter {
      $0.id.lowercased().contains(lower) || $0.name.lowercased().contains(lower)
    }
    if partial.count == 1 { return partial[0] }
    if partial.count > 1 {
      throw CLIError("'\(name)' is ambiguous: \(partial.map(\.name).joined(separator: ", "))")
    }
    if name.contains("/") { return .custom(id: name) }
    if mock { return ModelSpec(id: "mock/\(name)", name: name, sizeGB: 0, thinking: true) }
    throw CLIError(
      "unknown model '\(name)'; run `c4bench models` or pass a Hugging Face id like mlx-community/..."
    )
  }

  static func parseStyle(_ text: String) throws -> ThinkingStyle {
    switch text.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(
      of: "_", with: "")
    {
    case "instinct": .instinct
    case "explain": .explain
    case "deepthink": .deepThink
    default: throw CLIError("unknown style '\(text)' (instinct, explain, deepThink)")
    }
  }

  static func parseDifficulty(_ text: String) throws -> Difficulty {
    guard let value = Difficulty(rawValue: text.lowercased()) else {
      throw CLIError("unknown difficulty '\(text)' (easy, moderate, hard)")
    }
    return value
  }

  static func parsePreset(_ text: String) throws -> SuitePreset {
    guard let value = SuitePreset(rawValue: text.lowercased()) else {
      throw CLIError("unknown suite '\(text)' (quick, standard, full)")
    }
    return value
  }
}

// MARK: - Support

final class InterruptCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func increment() -> Int {
    lock.withLock {
      count += 1
      return count
    }
  }
}

/// Prints progress: a live status line on a terminal, one line per milestone otherwise.
final class ProgressPrinter: @unchecked Sendable {
  private let lock = NSLock()
  private let tty = isatty(STDOUT_FILENO) != 0
  private let quiet: Bool
  private var lastGames = -1
  private var lastPuzzles = -1
  private var lastLoad = -1.0
  private var drewLine = false

  init(quiet: Bool) { self.quiet = quiet }

  func update(_ p: BenchProgress) {
    lock.lock()
    defer { lock.unlock() }
    guard !quiet else { return }
    let status =
      "[games \(p.gamesDone)/\(p.gamesTotal) | puzzles \(p.puzzlesDone)/\(p.puzzlesTotal) | eta \(Self.eta(p.etaSeconds))]"
    var activity = ""
    switch p.phase {
    case .loading(let model, let fraction): activity = "loading \(model) \(Int(fraction * 100))%"
    case .puzzles(let name): activity = name.isEmpty ? "" : "puzzles: \(name)"
    case .game(let a, let b): activity = "\(a) vs \(b)"
    case .finished: activity = "done"
    }
    if let message = p.message {
      clear()
      print("note: \(message)")
    }
    if tty {
      let plies = p.currentBoard.map { " ply \($0.plyCount)" } ?? ""
      let line = "\(status) \(activity)\(plies)"
      print("\r\u{1B}[2K" + String(line.prefix(160)), terminator: "")
      fflush(stdout)
      drewLine = true
      return
    }
    switch p.phase {
    case .loading(let model, let fraction):
      let bucket = (fraction * 4).rounded(.down)
      if bucket != lastLoad {
        lastLoad = bucket
        print("loading \(model) \(Int(fraction * 100))%")
      }
    default:
      let gameMilestone =
        p.gamesDone != lastGames && (p.gamesDone % 10 == 0 || p.gamesDone == p.gamesTotal)
      let puzzleMilestone = p.puzzlesDone != lastPuzzles && p.puzzlesDone % 50 == 0
      if gameMilestone || puzzleMilestone {
        lastGames = p.gamesDone
        lastPuzzles = p.puzzlesDone
        print("\(status) \(activity)")
      }
    }
  }

  func finish() {
    lock.lock()
    defer { lock.unlock() }
    clear()
  }

  private func clear() {
    if tty && drewLine {
      print("\r\u{1B}[2K", terminator: "")
      drewLine = false
    }
  }

  static func eta(_ seconds: Double?) -> String {
    guard let seconds else { return "?" }
    let s = Int(seconds.rounded())
    if s < 90 { return "\(s)s" }
    if s < 5400 { return "\(s / 60)m" }
    return String(format: "%.1fh", seconds / 3600)
  }
}
