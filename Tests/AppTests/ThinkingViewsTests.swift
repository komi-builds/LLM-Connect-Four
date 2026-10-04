import C4AI
import C4Core
import Foundation
import Testing

@testable import LLMConnectFour

/// A short game with real traces: human X plays 4 (index 0), the model answers 4 (index 1), ...
private func makeRecord(
  id: UUID = UUID(), startedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
  moves: [Column] = [3, 3, 2, 4, 1]
) -> GameRecord {
  var record = GameRecord(
    id: id, startedAt: startedAt, finishedAt: startedAt.addingTimeInterval(60),
    opponentName: "Mock Model", modelID: nil, style: .explain, difficulty: .moderate,
    variantID: PromptVariant.default.id, gameSeed: 42, moves: moves)
  for index in moves.indices where !index.isMultiple(of: 2) {
    let board = try! Board(moves: moves.prefix(index))
    let context = TurnContext(board: board, gameSeed: 42)
    let prompt = PromptBuilder.build(for: context)
    let distribution = ColumnDistribution.softmax(
      logits: Board.allColumns.map { Double($0 == moves[index] ? 2 : 0) },
      allowed: board.legalMoves)
    let move = AIMove(
      column: moves[index], distribution: distribution, reasoning: "Because \(index).")
    var trace = MoveTrace(
      context: context, provider: "Mock Model", modelID: nil, prompt: prompt, move: move)
    // ISO 8601 keeps whole seconds, so use one to make the round trip exact.
    trace.createdAt = startedAt.addingTimeInterval(Double(index))
    record.traces.append(trace)
  }
  return record
}

private func makeTempStore(limit: Int = GameStore.defaultLimit) -> GameStore {
  GameStore(
    directory: FileManager.default.temporaryDirectory
      .appendingPathComponent("GameStoreTests-\(UUID().uuidString)", isDirectory: true),
    limit: limit)
}

@Suite struct GameStoreTests {
  @Test func saveAndLoadRoundTrip() throws {
    let store = makeTempStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let record = makeRecord()
    try store.save(record)
    #expect(store.load(id: record.id) == record)
    #expect(store.list() == [record])
  }

  @Test func listIsNewestFirst() throws {
    let store = makeTempStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let old = makeRecord(startedAt: base)
    let new = makeRecord(startedAt: base.addingTimeInterval(500))
    try store.save(old)
    try store.save(new)
    #expect(store.list().map(\.id) == [new.id, old.id])
  }

  @Test func savingTwiceOverwrites() throws {
    let store = makeTempStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    var record = makeRecord()
    try store.save(record)
    record.outcome = .draw
    try store.save(record)
    #expect(store.list().count == 1)
    #expect(store.load(id: record.id)?.outcome == .draw)
  }

  @Test func prunesToTheNewestLimit() throws {
    let store = makeTempStore(limit: 5)
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    var ids: [UUID] = []
    for offset in 0..<8 {
      let record = makeRecord(startedAt: base.addingTimeInterval(Double(offset) * 10))
      ids.append(record.id)
      try store.save(record)
    }
    let kept = store.list().map(\.id)
    #expect(kept.count == 5)
    #expect(kept == ids.suffix(5).reversed())
    #expect(store.load(id: ids[0]) == nil)
  }

  @Test func defaultLimitIsTwoHundred() {
    #expect(GameStore.defaultLimit == 200)
    #expect(GameStore.default.limit == 200)
  }

  @Test func deleteRemovesTheGame() throws {
    let store = makeTempStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let record = makeRecord()
    try store.save(record)
    try store.delete(id: record.id)
    #expect(store.list().isEmpty)
  }

  @Test func exportRoundTrip() throws {
    let store = makeTempStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let record = makeRecord()
    let destination = store.directory.appendingPathComponent("export.json")
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    try store.export(record, to: destination)
    let decoded = try GameStore.record(from: Data(contentsOf: destination))
    #expect(decoded == record)
    // The exported file is not mistaken for a saved game only because of its name; the
    // document type writes the same bytes.
    let document = try GameDocument(record: record)
    #expect(document.data == (try GameStore.data(for: record)))
  }

  @Test func unreadableFilesAreSkipped() throws {
    let store = makeTempStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    try store.save(makeRecord())
    try Data("not json".utf8).write(to: store.directory.appendingPathComponent("junk.json"))
    #expect(store.list().count == 1)
  }

  @MainActor
  @Test func viewModelSavesFinishedGames() async throws {
    let store = makeTempStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let model = GameViewModel(
      provider: MockMoveProvider(tokenDelay: .zero, loadDuration: .milliseconds(10)),
      defaults: UserDefaults(suiteName: "GameStoreTests-\(UUID().uuidString)")!,
      minimumAIDelay: .zero)
    model.gameStore = store
    model.humanDrop(3)
    await model.waitForAITurn()
    #expect(store.list().isEmpty)  // still in progress
    model.newGame()  // abandoned with a model move: saved
    let saved = store.list()
    #expect(saved.count == 1)
    #expect(saved[0].traces.count == 1)
  }
}

@Suite struct ReplayStateTests {
  @Test func stepsMapPlyToBoard() throws {
    let record = makeRecord()
    var state = ReplayState(record: record)
    #expect(state.ply == 0)
    #expect(state.board.plyCount == 0)
    #expect(!state.canStepBack)
    for step in 1...record.moves.count {
      state.stepForward()
      #expect(state.ply == step)
      #expect(state.board.moves == Array(record.moves.prefix(step)))
      #expect(state.lastColumn == record.moves[step - 1])
    }
    #expect(!state.canStepForward)
    state.stepForward()
    #expect(state.ply == record.moves.count)
    state.stepBack()
    #expect(state.ply == record.moves.count - 1)
  }

  @Test func traceAppearsOnlyOnAIMoves() {
    let record = makeRecord()
    var state = ReplayState(record: record)
    for ply in 0...record.moves.count {
      state.seek(to: ply)
      let lastIndex = ply - 1
      if ply > 0, !lastIndex.isMultiple(of: 2) {
        let trace = state.trace
        #expect(trace?.ply == lastIndex)
        #expect(trace?.move.column == record.moves[lastIndex])
        #expect(trace?.movesBefore == Array(record.moves.prefix(lastIndex)))
      } else {
        #expect(state.trace == nil)
      }
    }
  }

  @Test func seekClamps() {
    var state = ReplayState(record: makeRecord())
    state.seek(to: 99)
    #expect(state.ply == 5)
    state.seek(to: -3)
    #expect(state.ply == 0)
  }

  @Test func emptyGameIsSafe() {
    var state = ReplayState(record: makeRecord(moves: []))
    state.stepForward()
    state.stepBack()
    #expect(state.ply == 0)
    #expect(state.trace == nil)
  }

  @Test func turnRebuiltFromTraceCarriesEverything() throws {
    let record = makeRecord()
    let trace = try #require(record.traces.first)
    let turn = GameViewModel.AITurn(trace: trace)
    #expect(turn.move == trace.move)
    #expect(turn.distribution == trace.move.distribution)
    #expect(turn.prompt == trace.prompt)
    #expect(turn.reasoning == trace.move.reasoning)
    #expect(!turn.isStreaming)
  }
}

@Suite struct PromptHighlightTests {
  @Test func findsEveryFactRange() throws {
    // A position with facts at full level.
    let board = try Board(moves: [3, 3, 3, 4, 2, 4, 2, 1])
    let prompt = PromptBuilder.build(
      board: board, style: .explain, profile: .profile(for: .hard), variant: .default)
    let facts = prompt.facts.isEmpty ? ["Facts: none"] : prompt.facts
    let ranges = PromptHighlight.ranges(of: facts, in: prompt.user)
    #expect(ranges.count == facts.count)
    for (fact, range) in zip(facts, ranges) {
      #expect(String(prompt.user[range]) == fact)
    }
  }

  @Test func highlightsFactsInTheAttributedString() {
    let user =
      "Board\nFacts:\n- You can win immediately in column 4.\n- Column 2 is open.\nLegal: 1 2"
    let facts = ["You can win immediately in column 4.", "Column 2 is open."]
    let attributed = PromptHighlight.attributed(user, facts: facts)
    let highlighted = attributed.runs.filter { $0.backgroundColor != nil }
      .map { String(attributed[$0.range].characters) }
    #expect(highlighted == facts)
    #expect(String(attributed.characters) == user)
  }

  @Test func ignoresMissingAndEmptyFacts() {
    let ranges = PromptHighlight.ranges(of: ["", "absent", "here"], in: "it is here")
    #expect(ranges.count == 1)
  }
}
