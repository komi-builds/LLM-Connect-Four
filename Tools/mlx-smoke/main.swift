import C4AI
import C4Core
import C4MLX
import Foundation

// mlx-smoke: loads a real model and plays Instinct and Explain moves on fixed boards
// to check a model end to end. Prints digit tokens, distributions, reasoning, the
// unmasked-legality flag and timings.
//
//   mlx-smoke [--model <hf id>] [--directory <local folder>] [--deep] [--skip-reload]
//
// It uses its own small prompt builder that follows §3.1, so it does not depend on
// PromptBuilder.

// MARK: Arguments

setvbuf(stdout, nil, _IOLBF, 0)

var modelID = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
var directory: URL?
var includeDeep = false
var reload = true
var verboseProgress = false
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
  switch argument {
  case "--model": modelID = arguments.popFirst() ?? modelID
  case "--directory": directory = arguments.popFirst().map { URL(fileURLWithPath: $0) }
  case "--deep": includeDeep = true
  case "--skip-reload": reload = false
  case "--verbose-progress": verboseProgress = true
  default:
    print("usage: mlx-smoke [--model <id>] [--directory <path>] [--deep] [--skip-reload]")
    exit(2)
  }
}

let spec =
  ModelRegistry.bundled().first { $0.id == modelID } ?? ModelSpec.custom(id: modelID)

// MARK: A small §3.1 prompt builder

enum SmokePrompt {
  static func system(style: ThinkingStyle) -> String {
    let finish =
      switch style {
      case .instinct: "Answer with a single line \"Column: N\"."
      case .explain:
        "Explain your choice in one short sentence (at most 25 words), then finish with a line \"Column: N\"."
      case .deepThink:
        "Think it through, then explain briefly and finish with a line \"Column: N\"."
      }
    return """
      You are an expert Connect Four player. You are O. Your opponent is X.
      The board has 7 columns (1-7, left to right) and 6 rows (1 = bottom, 6 = top).
      A disc dropped in a column lands on the lowest empty row. Four in a row
      horizontally, vertically or diagonally wins.
      Priorities: 1) win now  2) block the opponent's win  3) do not give the
      opponent a winning square  4) build threats, prefer the centre columns.
      \(finish)

      Example answer when you can win:
      My three O discs on row 1 are completed by column 6, so I win now.
      Column: 6

      Example answer when X threatens a win:
      X has three on row 2 and would complete it in column 2, so I block there.
      Column: 2
      """
  }

  static func symbol(_ disc: Disc?, _ me: Disc) -> String {
    guard let disc else { return "." }
    return disc == me ? "O" : "X"
  }

  static func user(board: Board) -> (text: String, facts: [String], allowed: [Column]) {
    let me = board.toMove
    var lines = ["Board (row 6 at top):", "   1 2 3 4 5 6 7"]
    for row in stride(from: Board.rowCount - 1, through: 0, by: -1) {
      let cells = Board.allColumns.map { symbol(board.disc(atColumn: $0, row: row), me) }
      lines.append("\(row + 1)  " + cells.joined(separator: " "))
    }
    lines.append("")
    lines.append("Columns (bottom → top):")
    for column in Board.allColumns {
      let height = board.height(of: column)
      let stack = (0..<height).map { symbol(board.disc(atColumn: column, row: $0), me) }
      let content = stack.isEmpty ? "empty" : stack.joined(separator: " ")
      let landing = height < Board.rowCount ? "lands row \(height + 1)" : "full"
      lines.append("\(column + 1): \(content) → \(landing)")
    }
    let history = board.moves.enumerated().map { index, column in
      let disc: Disc = index.isMultiple(of: 2) ? .first : .second
      return symbol(disc, me) + String(column + 1)
    }
    lines.append("")
    lines.append("Moves so far: \(history.joined(separator: " ")) (\(board.moves.count) total)")
    let legal = Board.allColumns.filter(board.canPlay)
    var facts: [String] = []
    for column in legal where board.wouldWin(me, playing: column) {
      facts.append("You can win immediately in column \(column + 1).")
    }
    for column in legal where board.wouldWin(me.opponent, playing: column) {
      facts.append(
        "X threatens to win in column \(column + 1). You must block unless you can win first.")
    }
    if !facts.isEmpty { lines.append("Facts: " + facts.joined(separator: " ")) }
    lines.append("Legal columns: " + legal.map { String($0 + 1) }.joined(separator: " "))
    return (lines.joined(separator: "\n"), facts, legal)
  }

  static func build(_ context: TurnContext) -> Prompt {
    let user = user(board: context.board)
    return Prompt(
      system: system(style: context.style), user: user.text, facts: user.facts,
      allowedColumns: user.allowed,
      variantID: context.variant.id, version: 0)
  }
}

// MARK: Boards

struct Case {
  var name: String
  var moves: [Column]
  var expect: String
}

let cases = [
  Case(name: "opening", moves: [3], expect: "anything sensible (centre-ish)"),
  Case(name: "immediate win", moves: [0, 0, 1, 1, 2, 2], expect: "4 (win)"),
  Case(name: "forced block", moves: [3, 0, 3, 6, 3], expect: "4 (block)"),
  Case(name: "full centre column", moves: [3, 3, 3, 3, 3, 3, 2, 4], expect: "not 4 (full)"),
]

// MARK: Helpers

func ms(_ value: Double) -> String { String(format: "%.0f ms", value) }

func format(_ distribution: ColumnDistribution) -> String {
  Board.allColumns.map { column in
    distribution.masked.contains(column)
      ? "\(column + 1):--"
      : "\(column + 1):" + String(format: "%.2f", distribution.probabilities[column])
  }.joined(separator: " ")
}

func play(
  _ provider: LLMMoveProvider, board: Board, style: ThinkingStyle,
  profile: DifficultyProfile = .moderate,
  printReasoning: Bool = true
) async -> AIMove? {
  let context = TurnContext(board: board, style: style, profile: profile, gameSeed: 42)
  for await event in provider.move(context) {
    switch event {
    case .thinkingToken(let text):
      if printReasoning { FileHandle.standardError.write(Data(text.utf8)) }
    case .decided(let move):
      if printReasoning && !move.reasoning.isEmpty {
        print("    reasoning: \(move.reasoning.replacingOccurrences(of: "\n", with: " ⏎ "))")
      }
      if !move.thinking.isEmpty { print("    thinking: \(move.thinking.count) chars") }
      return move
    case .failed(let error):
      print("    FAILED: \(error.message)")
      return nil
    default: break
    }
  }
  return nil
}

func report(_ move: AIMove, label: String) {
  let t = move.timings
  print("    \(label): column \(move.column + 1)  [\(format(move.distribution))]")
  print(
    "      unmaskedTopChoiceLegal=\(move.unmaskedTopChoiceLegal.map(String.init) ?? "nil")  prefill \(ms(t.prefillMs))  TTFT \(ms(t.timeToFirstTokenMs))  decode \(String(format: "%.1f", t.decodeTokensPerSecond)) tok/s  tokens \(t.generatedTokens)  total \(ms(t.totalMs))  prefixCacheHit=\(t.prefixCacheHit)"
  )
}

// MARK: Run

let clock = ContinuousClock()
print("== mlx-smoke: \(spec.id) (\(spec.name)), memory verdict \(spec.memoryVerdict())")

let provider = LLMMoveProvider(
  spec: spec, modelDirectory: directory, promptBuilder: SmokePrompt.build)
let loadStart = clock.now
do {
  let lastPrinted = LockedPhase()
  let verbose = verboseProgress
  try await provider.load { progress in
    if lastPrinted.shouldPrint(progress, verbose: verbose) {
      let rate = progress.bytesPerSecond.map { String(format: " %.1f MB/s", $0 / 1_000_000) } ?? ""
      print("  load: \(progress.phase.rawValue) \(Int(progress.fraction * 100))%\(rate)")
    }
  }
} catch {
  print("LOAD FAILED: \(error)")
  exit(1)
}
let loadMs = (clock.now - loadStart).milliseconds
for style in [ThinkingStyle.instinct, .explain] {
  if let counts = try? await provider.promptTokenCounts(
    for: TurnContext(board: try Board(moves: [3, 0, 3, 6, 3]), style: style, gameSeed: 0))
  {
    print(
      "  \(style.displayName) prompt tokens: static prefix \(counts.prefix), total \(counts.total)")
  }
}
print("  loaded + warmed up in \(ms(loadMs))")
if let split = await provider.lastLoadTimings {
  print("  load \(ms(split.loadMs)) + warm-up \(ms(split.warmUpMs))")
}
if let digits = await provider.digitTokens {
  print(
    "  digit tokens: \(digits.tokenIDs)  answer prefix: \(digits.answerPrefix.debugDescription)")
}

var instinctTotals: [Double] = []
var explainTotals: [Double] = []
var decodeRates: [Double] = []
var hitPrefills: [Double] = []
var missPrefills: [Double] = []
for item in cases {
  let board = try Board(moves: item.moves)
  print("\n-- \(item.name) (moves \(item.moves.map { $0 + 1 }), expect \(item.expect))")
  print(
    SmokePrompt.user(board: board).text.split(separator: "\n").prefix(8).map { "    " + $0 }.joined(
      separator: "\n"))
  for style in [ThinkingStyle.instinct, .explain] + (includeDeep ? [.deepThink] : []) {
    guard let move = await play(provider, board: board, style: style) else { continue }
    report(move, label: style.displayName)
    (move.timings.prefixCacheHit ? { hitPrefills.append($0) } : { missPrefills.append($0) })(
      move.timings.prefillMs)
    switch style {
    case .instinct: instinctTotals.append(move.timings.totalMs)
    case .explain:
      explainTotals.append(move.timings.totalMs)
      decodeRates.append(move.timings.decodeTokensPerSecond)
    case .deepThink: break
    }
  }
  // Hard (greedy) Instinct on the same board, for determinism.
  if let a = await play(
    provider, board: board, style: .instinct, profile: .hard, printReasoning: false),
    let b = await play(
      provider, board: board, style: .instinct, profile: .hard, printReasoning: false)
  {
    print(
      "    Hard Instinct twice: \(a.column + 1), \(b.column + 1) (same: \(a.column == b.column && a.distribution == b.distribution))"
    )
  }
}

// Cancellation, the way the app does it: cancel the task consuming an Explain move once
// its first reasoning token arrives. Generation must stop, so the next move is not
// delayed by the abandoned one.
do {
  let board = try Board(moves: cases[0].moves)
  let firstToken = AsyncStream.makeStream(of: Void.self)
  let cancelStart = clock.now
  let consumer = Task {
    var events: [String] = []
    for await event in provider.move(TurnContext(board: board, style: .explain, gameSeed: 7)) {
      switch event {
      case .reasoningToken: firstToken.continuation.yield()
      case .failed(let error): events.append("failed(\(error.message))")
      case .decided: events.append("decided")
      default: break
      }
    }
    return events
  }
  for await _ in firstToken.stream { break }
  consumer.cancel()
  let abandonedAt = clock.now
  let ending = await consumer.value
  if let next = await play(provider, board: board, style: .instinct, printReasoning: false) {
    let wait = (clock.now - abandonedAt).milliseconds - next.timings.totalMs
    print(
      "\n-- cancellation: cancelled Explain after \(ms((abandonedAt - cancelStart).milliseconds)), stream ended with \(ending); next Instinct waited \(ms(wait)) before starting"
    )
  }
}
let memory = LLMMoveProvider.memoryReport()
print(
  "  GPU memory: active \(memory.activeMB) MB, peak \(memory.peakMB) MB, cache \(memory.cacheMB) MB"
)

func average(_ values: [Double]) -> String {
  values.isEmpty ? "n/a" : ms(values.reduce(0, +) / Double(values.count))
}
print("\n== summary")
print("  load (incl. warm-up): \(ms(loadMs))")
print(
  "  Instinct total avg: \(average(instinctTotals))  Explain total avg: \(average(explainTotals))")
print(
  "  prefill avg with prefix cache hit: \(average(hitPrefills))  without: \(average(missPrefills))")
if !decodeRates.isEmpty {
  print(
    "  Explain decode avg: \(String(format: "%.1f", decodeRates.reduce(0, +) / Double(decodeRates.count))) tok/s"
  )
}

await provider.unload()
print("  unloaded")

if reload {
  guard let cached = LLMMoveProvider.cachedModelDirectory(for: spec.id) else {
    print("  no cached snapshot found for offline reload")
    exit(0)
  }
  print("\n== offline reload from \(cached.path)")
  let offline = LLMMoveProvider(
    spec: spec, modelDirectory: cached, promptBuilder: SmokePrompt.build)
  let start = clock.now
  do {
    try await offline.load { _ in }
  } catch {
    print("OFFLINE LOAD FAILED: \(error)")
    exit(1)
  }
  print("  loaded + warmed up in \(ms((clock.now - start).milliseconds))")
  if let split = await offline.lastLoadTimings {
    print("  load \(ms(split.loadMs)) + warm-up \(ms(split.warmUpMs))")
  }
  if let move = await play(offline, board: try Board(moves: cases[1].moves), style: .instinct) {
    report(move, label: "Instinct (offline)")
  }
  await offline.unload()
}

/// Prints each load phase once, and download progress every 10%.
final class LockedPhase: @unchecked Sendable {
  private let lock = NSLock()
  private var last: (LoadProgress.Phase, Int)?
  private var lastTime = Date.distantPast

  func shouldPrint(_ progress: LoadProgress, verbose: Bool) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if verbose {
      guard Date().timeIntervalSince(lastTime) >= 2 || progress.phase != .downloading else {
        return false
      }
      lastTime = Date()
      return true
    }
    let bucket = Int(progress.fraction * 10)
    if let last, last.0 == progress.phase, last.1 == bucket { return false }
    last = (progress.phase, bucket)
    return true
  }
}
