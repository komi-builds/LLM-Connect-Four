import C4AI
import C4Core
import Foundation
import Testing

@testable import C4Bench

@Suite struct ReportTests {
  static let machine = MachineInfo(
    chip: "Apple M3 Pro", memoryGB: 18, osVersion: "26.0", appVersion: "1.0", promptVersion: 3)

  /// Hand-written rows (no fitting) so the goldens only depend on the writers.
  static var rows: [RatingRow] {
    let qwen = Contestant(
      kind: .llm(
        modelID: "mlx-community/Qwen3-4B-Instruct-2507-4bit", style: .explain, difficulty: .hard,
        variantID: "combined"), modelName: "Qwen3 4B")
    let odd = Contestant(
      kind: .llm(modelID: "m/odd", style: .instinct, difficulty: .easy, variantID: "grid"),
      modelName: "Odd, \"Quoted\" | Model")
    let gemma = Contestant(
      kind: .llm(modelID: "m/gemma", style: .instinct, difficulty: .moderate, variantID: "columns"),
      modelName: "Gemma 2B")
    return [
      RatingRow(
        contestant: .minimax(6), rank: 1, rating: 1412.34, ciLow: 1380.2, ciHigh: 1445.9, games: 50,
        wins: 44,
        draws: 3, losses: 3, winRateVsD4: 0.73, blundersPerGame: 0.02, medianMoveMs: 38),
      RatingRow(
        contestant: qwen, rank: 2, rating: 1123.45, ciLow: 1082.6, ciHigh: 1163.8,
        tiedWithPrevious: false,
        games: 50, wins: 20, draws: 5, losses: 25,
        puzzleAccuracy: [
          "win-in-1": 1, "block-in-1": 0.9, "avoid-the-blunder": 0.625, "win-in-3": 0.4,
        ],
        puzzleOverall: 0.7125, winRateVsD4: 0.26, blundersPerGame: 0.84, wouldBeIllegalRate: 0.031,
        medianMoveMs: 1234.5, tokensPerSecond: 61.25, loadTimeMs: 4200, peakRAMGB: 3.4, sizeGB: 2.3),
      RatingRow(
        contestant: .minimax(4), rank: 3, rating: 1101.1, ciLow: 1070, ciHigh: 1132.2,
        tiedWithPrevious: true,
        games: 80, wins: 40, draws: 10, losses: 30, winRateVsD4: nil, blundersPerGame: 0.1,
        medianMoveMs: 12),
      RatingRow(
        contestant: odd, rank: 4, rating: 1000, ciLow: 1000, ciHigh: 1000, tiedWithPrevious: true,
        games: 14,
        wins: 5, draws: 4, losses: 5, puzzleAccuracy: ["win-in-1": 0.5], puzzleOverall: 0.5,
        blundersPerGame: 1.5, wouldBeIllegalRate: 0.2, medianMoveMs: 250, tokensPerSecond: 0,
        loadTimeMs: 800,
        peakRAMGB: 1.25, sizeGB: 1.1),
      RatingRow(
        contestant: gemma, rank: 5, rating: 802.5, ciLow: 760.1, ciHigh: 850, games: 14, wins: 1,
        draws: 0,
        losses: 13, wouldBeIllegalRate: 0.55),
      RatingRow(
        contestant: .random, rank: 6, rating: 450, ciLow: 380, ciHigh: 520, games: 28, wins: 0,
        draws: 0,
        losses: 28, blundersPerGame: 3.25),
    ]
  }

  static func golden(_ name: String, _ content: String) throws -> String {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(
      path: "Golden")
    let url = directory.appending(path: name)
    if ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] == "1" {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try content.write(to: url, atomically: true, encoding: .utf8)
    }
    guard
      let bundled = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Golden")
    else {
      // Freshly regenerated files are not in the built bundle yet.
      return try String(contentsOf: url, encoding: .utf8)
    }
    return try String(contentsOf: bundled, encoding: .utf8)
  }

  @Test func markdownGolden() throws {
    let output = ReportWriter.render(Self.rows, format: .md, machine: Self.machine)
    #expect(output == (try Self.golden("leaderboard.md", output)))
  }

  @Test func markdownWithoutMachineGolden() throws {
    let output = ReportWriter.render(Self.rows, format: .md)
    #expect(output == (try Self.golden("leaderboard-no-machine.md", output)))
  }

  @Test func csvGolden() throws {
    let output = ReportWriter.render(Self.rows, format: .csv, machine: Self.machine)
    #expect(output == (try Self.golden("leaderboard.csv", output)))
  }

  @Test func jsonGolden() throws {
    let output = ReportWriter.render(Self.rows, format: .json, machine: Self.machine)
    #expect(output == (try Self.golden("leaderboard.json", output)))
  }

  @Test func noDashesAnywhere() {
    for format in ReportFormat.allCases {
      let output = ReportWriter.render(Self.rows, format: format, machine: Self.machine)
      #expect(!output.contains("\u{2014}") && !output.contains("\u{2013}"), "\(format)")
    }
  }

  @Test func tiedRanksShowAnEqualsSign() {
    let ranks = ReportWriter.displayRanks(Self.rows)
    #expect(ranks == ["1", "=2", "=2", "=2", "5", "6"])
  }

  @Test func csvQuotingFollowsRFC4180() {
    #expect(ReportWriter.csvQuote("plain") == "plain")
    #expect(ReportWriter.csvQuote("a,b") == "\"a,b\"")
    #expect(ReportWriter.csvQuote("say \"hi\"") == "\"say \"\"hi\"\"\"")
    let output = ReportWriter.render(Self.rows, format: .csv)
    #expect(output.contains("\"Odd, \"\"Quoted\"\" | Model"))
    let lines = output.split(separator: "\n")
    #expect(lines.count == Self.rows.count + 1)
  }

  @Test func emptyRows() {
    let md = ReportWriter.render([], format: .md, machine: Self.machine)
    #expect(md.hasPrefix("| Rank |"))
    #expect(ReportWriter.render([], format: .json) == "[\n\n]\n")
    #expect(ReportWriter.render([], format: .csv).split(separator: "\n").count == 1)
  }

  @Test func jsonRoundTrips() throws {
    let output = ReportWriter.render(Self.rows, format: .json)
    let decoded = try JSONDecoder().decode([RatingRow].self, from: Data(output.utf8))
    #expect(decoded.count == Self.rows.count)
    #expect(decoded.map(\.contestant.id) == Self.rows.map(\.contestant.id))
  }
}
