import C4Core
import Foundation
import Testing

@testable import C4AI

private func board(_ moves: [Column]) -> Board { try! Board(moves: moves) }

/// Fixed boards for the golden files.
private let goldenBoards: [(name: String, board: Board)] = [
  ("empty", Board()),
  ("midgame", board([3, 3, 2, 4, 3, 4, 4, 2, 2, 6, 3])),
  ("canwin", PromptExamples.win),
  ("mustblock", PromptExamples.block),
  // Column 7 is full, column 4 is unsafe, columns 3 and 4 create threats.
  (
    "unsafe-full",
    board([1, 0, 4, 2, 6, 3, 6, 1, 2, 6, 4, 6, 5, 6, 0, 3, 4, 5, 6, 4, 0, 0, 0, 2])
  ),
]

private let goldenFolder = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().appendingPathComponent("Golden")

private func golden(_ name: String, actual: String) throws -> String? {
  if ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] == "1" {
    try FileManager.default.createDirectory(at: goldenFolder, withIntermediateDirectories: true)
    try (actual + "\n").write(
      to: goldenFolder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    return nil
  }
  let url = Bundle.module.resourceURL!.appendingPathComponent("Golden").appendingPathComponent(name)
  guard let text = try? String(contentsOf: url, encoding: .utf8) else {
    Issue.record("missing golden \(name); run with UPDATE_GOLDENS=1")
    return nil
  }
  return String(text.dropLast())
}

@Suite struct GoldenTests {
  @Test(arguments: PromptVariant.all, ThinkingStyle.allCases)
  func systemPrompt(variant: PromptVariant, style: ThinkingStyle) throws {
    let actual = PromptBuilder.systemPrompt(variant: variant, style: style)
    if let expected = try golden("system__\(variant.id)__\(style.rawValue).txt", actual: actual) {
      #expect(actual == expected)
    }
  }

  @Test(arguments: PromptVariant.all)
  func userPrompt(variant: PromptVariant) throws {
    for (name, board) in goldenBoards {
      var sections: [String] = []
      var facts: [String] = []
      for difficulty in Difficulty.allCases {
        let prompt = PromptBuilder.build(
          board: board, style: .explain, profile: .profile(for: difficulty), variant: variant)
        sections.append(
          "=== \(difficulty.rawValue) (allowed: \(prompt.allowedColumns.map { $0 + 1 })) ===\n"
            + prompt.user)
        facts.append(contentsOf: prompt.facts)
      }
      let actual = sections.joined(separator: "\n\n")
      if let expected = try golden("user__\(name)__\(variant.id).txt", actual: actual) {
        #expect(actual == expected, "board \(name), variant \(variant.id)")
      }
    }
  }
}

@Suite struct EncoderTests {
  /// Second player to move, so the second player's discs are `O`.
  @Test func perspectiveRelabelling() {
    // First player plays column 4 (index 3); second player to move.
    let b = board([3])
    #expect(b.toMove == .second)
    #expect(BoardEncoder.grid(b).contains("1  . . . X . . ."))
    // Same shape with the roles swapped: first player to move sees its own disc as O.
    let b2 = board([3, 3])
    #expect(b2.toMove == .first)
    let rows = BoardEncoder.grid(b2).split(separator: "\n")
    #expect(rows.contains("1  . . . O . . ."))
    #expect(rows.contains("2  . . . X . . ."))
    #expect(BoardEncoder.history(b2) == "Moves so far: O4 X4 (2 total)")
    #expect(BoardEncoder.history(board([3])) == "Moves so far: X4 (1 total)")
  }

  @Test func gridLayout() {
    let expected = """
      Board (row 6 at top):
         1 2 3 4 5 6 7
      6  . . . . . . .
      5  . . . . . . .
      4  . . . . . . .
      3  . . . . . . .
      2  . . . X . . .
      1  . . X O . . .
      """
    // First plays 3, second plays 4, first plays 4. Second is to move, so first's discs are X.
    let b = board([2, 3, 3])
    #expect(b.toMove == .second)
    #expect(BoardEncoder.grid(b) == expected)
  }

  @Test func columnsLandingRowsAndFull() {
    let b = board([0, 0, 0, 0, 0, 0, 3])
    let text = BoardEncoder.columns(b)
    #expect(text.contains("1: X O X O X O → full"))
    #expect(text.contains("2: empty → lands row 1"))
    #expect(text.contains("4: X → lands row 2"))
    #expect(!text.contains("0:"))
    #expect(text.hasPrefix("Columns (bottom → top):\n1:"))
  }

  @Test func emptyHistory() {
    #expect(BoardEncoder.history(Board()) == "Moves so far: none")
  }

  @Test func labelsAreOneBased() {
    #expect(BoardEncoder.label(0) == "1")
    #expect(BoardEncoder.label(6) == "7")
    let p = PromptBuilder.build(
      board: Board(), style: .explain, profile: .moderate, variant: .default)
    #expect(p.user.contains("Legal columns: 1 2 3 4 5 6 7"))
    #expect(p.allowedColumns == [0, 1, 2, 3, 4, 5, 6])
  }
}

@Suite struct FactsTests {
  private func prompt(_ b: Board, _ profile: DifficultyProfile, extra: [String] = []) -> Prompt {
    PromptBuilder.build(
      board: b, style: .explain, profile: profile, variant: .default, extraFacts: extra)
  }

  @Test func easyHasNoFactsSection() {
    let p = prompt(PromptExamples.win, .easy)
    #expect(p.facts.isEmpty)
    #expect(!p.user.contains("Facts"))
  }

  @Test func moderateWinsAndBlocks() {
    let win = prompt(PromptExamples.win, .moderate)
    #expect(win.facts == ["You can win immediately in column 1."])
    let block = prompt(PromptExamples.block, .moderate)
    #expect(
      block.facts == [
        "X threatens to win in column 4. You must block unless you can win first."
      ])
    // No unsafe-move or threat facts at Moderate.
    let late = prompt(goldenBoards[4].board, .moderate)
    #expect(late.facts.isEmpty)
    #expect(late.user.contains("Facts: none"))
  }

  @Test func hardAddsUnsafeAndThreats() {
    let p = prompt(goldenBoards[4].board, .hard)
    #expect(p.facts.contains("Playing column 4 lets X win immediately."))
    #expect(p.facts.contains { $0.hasSuffix("would create a new winning threat for you.") })
    #expect(p.allowedColumns == [0, 1, 2, 4, 5])
    #expect(p.user.contains("Legal columns: 1 2 3 5 6"))
  }

  @Test func everyFactAppearsVerbatimInUser() {
    for (_, b) in goldenBoards {
      for profile in [DifficultyProfile.easy, .moderate, .hard] {
        let p = prompt(b, profile, extra: ["Extra fact."])
        for fact in p.facts { #expect(p.user.contains(fact)) }
        #expect(p.facts.last == "Extra fact.")
      }
    }
  }

  @Test func factsNeverInstructAPlay() {
    for (_, b) in goldenBoards {
      for f in prompt(b, .hard).facts { #expect(!f.lowercased().contains("play column")) }
    }
  }
}

@Suite struct AllowedColumnsTests {
  @Test func easyAndModerateOfferAllLegalMoves() {
    let b = goldenBoards[4].board
    #expect(DifficultyProfile.easy.allowedColumns(on: b) == b.legalMoves)
    #expect(DifficultyProfile.moderate.allowedColumns(on: b) == b.legalMoves)
  }

  @Test func hardMasksUnsafeMoves() {
    let b = goldenBoards[4].board
    let allowed = DifficultyProfile.hard.allowedColumns(on: b)
    #expect(!allowed.contains(3))
    #expect(allowed == allowed.sorted())
    #expect(Set(allowed) == Set(b.legalMoves).subtracting(Tactics.unsafeMoves(b)))
  }

  @Test func hardKeepsEverythingWhenAllMovesAreUnsafe() {
    // Find a position where every legal move is unsafe by search.
    var rng = SplitMix64(seed: 99)
    for _ in 0..<200_000 {
      var b = Board()
      let target = 20 + Int(rng.next() % 20)
      while b.plyCount < target, !b.isGameOver {
        let m = b.legalMoves
        b.drop(m[Int(rng.next() % UInt64(m.count))])
      }
      guard !b.isGameOver, !b.legalMoves.isEmpty else { continue }
      if Tactics.unsafeMoves(b).count == b.legalMoves.count {
        #expect(DifficultyProfile.hard.allowedColumns(on: b) == b.legalMoves)
        return
      }
    }
    Issue.record("no all-unsafe position found")
  }
}

@Suite struct SystemPromptTests {
  @Test func independentOfBoard() {
    for variant in PromptVariant.all {
      for style in ThinkingStyle.allCases {
        let systems = Set(
          goldenBoards.map {
            PromptBuilder.build(
              board: $0.board, style: style, profile: .hard, variant: variant
            ).system
          })
        #expect(systems.count == 1)
        #expect(systems.first == PromptBuilder.systemPrompt(variant: variant, style: style))
      }
    }
  }

  @Test func fewShotExamplesAreCorrectByTheEngine() {
    let block = PromptExamples.block
    #expect(Tactics.mustBlock(block) == [PromptExamples.blockAnswer])
    #expect(Tactics.immediateWins(block, for: block.toMove).isEmpty)
    let win = PromptExamples.win
    #expect(Tactics.immediateWins(win, for: win.toMove) == [PromptExamples.winAnswer])
    #expect(win.isWinningMove(PromptExamples.winAnswer))
    #expect(Tactics.mustBlock(win).isEmpty)
  }

  @Test func fewShotContainsBothExamplesInTheTurnFormat() {
    let variant = PromptVariant.default
    let system = PromptBuilder.systemPrompt(variant: variant, style: .explain)
    #expect(system.contains(PromptBuilder.turn(PromptExamples.block, variant: variant)))
    #expect(system.contains(PromptBuilder.turn(PromptExamples.win, variant: variant)))
    let none = PromptBuilder.systemPrompt(
      variant: PromptVariant(view: .combined, fewShot: false), style: .explain)
    #expect(!none.contains("Example 1"))
  }

  @Test func versionAndPrefix() {
    #expect(PromptBuilder.version == 1)
    #expect(PromptBuilder.answerPrefix == "Column: ")
    for style in ThinkingStyle.allCases {
      let s = PromptBuilder.systemPrompt(variant: .default, style: style)
      #expect(s.hasPrefix("You are an expert Connect Four player. You are O."))
      #expect(!s.contains("—") && !s.contains("–"))
    }
  }
}
