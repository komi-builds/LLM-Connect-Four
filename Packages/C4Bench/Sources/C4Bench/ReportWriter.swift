import C4Core
import Foundation

public enum ReportWriter {
  /// Renders the leaderboard. Markdown is used for `LEADERBOARD.md` and the README table.
  /// All numbers use fixed decimals and a `.` separator regardless of locale; the output
  /// is a pure function of `rows` and `machine`. Rows are rendered in the order given.
  public static func render(_ rows: [RatingRow], format: ReportFormat, machine: MachineInfo? = nil)
    -> String
  {
    switch format {
    case .md: markdown(rows, machine: machine)
    case .csv: csv(rows)
    case .json: json(rows)
    }
  }

  // MARK: Markdown

  /// Short labels for the per-category puzzle accuracy, in display order.
  static let categoryLabels: [(PuzzleCategory, String)] = [
    (.winIn1, "W1"), (.blockIn1, "B1"), (.avoidBlunder, "AV"), (.winIn3, "W3"),
  ]

  static let markdownHeader = [
    "Rank", "Contestant", "Rating ± CI", "Puzzles % (W1 / B1 / AV / W3)", "Win % vs d4",
    "Blunders / game",
    "Would-be illegal %", "Median move time", "tok/s", "Load time", "Peak RAM", "Size",
  ]

  static func markdown(_ rows: [RatingRow], machine: MachineInfo?) -> String {
    var lines: [String] = []
    lines.append("| " + markdownHeader.joined(separator: " | ") + " |")
    lines.append("|" + String(repeating: "---|", count: markdownHeader.count))
    let ranks = displayRanks(rows)
    for (index, row) in rows.enumerated() {
      let cells = [
        ranks[index],
        escape(row.contestant.displayName),
        ratingCell(row),
        puzzleCell(row),
        optional(row.winRateVsD4.map { $0 * 100 }, "%.1f"),
        optional(row.blundersPerGame, "%.2f"),
        optional(row.wouldBeIllegalRate.map { $0 * 100 }, "%.1f"),
        durationCell(row.medianMoveMs),
        optional(row.tokensPerSecond, "%.1f"),
        optional(row.loadTimeMs.map { $0 / 1000 }, "%.1f s"),
        optional(row.peakRAMGB, "%.1f GB"),
        optional(row.sizeGB, "%.1f GB"),
      ]
      lines.append("| " + cells.joined(separator: " | ") + " |")
    }
    lines.append("")
    var footer = "Speed columns: "
    if let machine {
      footer += "\(machine.label)"
      footer += "; prompt version \(machine.promptVersion)"
    } else {
      footer += "all machines; prompt version n/a"
    }
    footer +=
      ". Ratings: Bradley-Terry, Minimax d2 = 1000, 95% bootstrap CI; = marks a tie with the row above."
    lines.append(footer)
    return lines.joined(separator: "\n") + "\n"
  }

  /// `3` for a row on its own, `=3` for every row in a tie chain starting at position 3.
  static func displayRanks(_ rows: [RatingRow]) -> [String] {
    var out: [String] = []
    var chainStart = 0
    for (index, row) in rows.enumerated() {
      if index > 0 && row.tiedWithPrevious {
        // Same chain as the row above.
      } else {
        chainStart = index
      }
      let tiedAbove = index > 0 && row.tiedWithPrevious
      let tiedBelow = index + 1 < rows.count && rows[index + 1].tiedWithPrevious
      let position = chainStart + 1
      out.append(tiedAbove || tiedBelow ? "=\(position)" : "\(position)")
    }
    return out
  }

  static func ratingCell(_ row: RatingRow) -> String {
    let half = ((row.ciHigh - row.ciLow) / 2).rounded()
    return String(format: "%.0f ± %.0f", row.rating, half)
  }

  static func puzzleCell(_ row: RatingRow) -> String {
    guard let overall = row.puzzleOverall else { return "n/a" }
    let parts = categoryLabels.map { category, label -> String in
      guard let value = row.puzzleAccuracy[category.rawValue] else { return "\(label) -" }
      return label + " " + String(format: "%.0f", value * 100)
    }
    return String(format: "%.0f", overall * 100) + " (" + parts.joined(separator: ", ") + ")"
  }

  static func durationCell(_ ms: Double?) -> String {
    guard let ms else { return "n/a" }
    return ms < 1000 ? String(format: "%.0f ms", ms) : String(format: "%.1f s", ms / 1000)
  }

  static func optional(_ value: Double?, _ format: String) -> String {
    guard let value else { return "n/a" }
    return String(format: format, value)
  }

  static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "|", with: "\\|")
  }

  // MARK: CSV

  static func csv(_ rows: [RatingRow]) -> String {
    var header = [
      "rank", "tied_with_previous", "contestant_id", "contestant", "rating", "ci_low", "ci_high",
      "games", "wins",
      "draws", "losses",
    ]
    header += PuzzleCategory.allCases.map {
      "puzzle_" + $0.rawValue.replacingOccurrences(of: "-", with: "_")
    }
    header += [
      "puzzle_overall", "win_rate_vs_d4", "blunders_per_game", "would_be_illegal_rate",
      "median_move_ms",
      "tokens_per_second", "load_time_ms", "peak_ram_gb", "size_gb",
    ]
    var lines = [header.joined(separator: ",")]
    for row in rows {
      var fields: [String] = [
        "\(row.rank)", row.tiedWithPrevious ? "true" : "false", csvQuote(row.contestant.id),
        csvQuote(row.contestant.displayName), fixed(row.rating), fixed(row.ciLow),
        fixed(row.ciHigh),
        "\(row.games)", "\(row.wins)", "\(row.draws)", "\(row.losses)",
      ]
      fields += PuzzleCategory.allCases.map { csvOptional(row.puzzleAccuracy[$0.rawValue]) }
      fields += [
        csvOptional(row.puzzleOverall), csvOptional(row.winRateVsD4),
        csvOptional(row.blundersPerGame),
        csvOptional(row.wouldBeIllegalRate), csvOptional(row.medianMoveMs),
        csvOptional(row.tokensPerSecond),
        csvOptional(row.loadTimeMs), csvOptional(row.peakRAMGB), csvOptional(row.sizeGB),
      ]
      lines.append(fields.joined(separator: ","))
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// RFC 4180: quote fields containing a comma, quote or line break; double inner quotes.
  static func csvQuote(_ field: String) -> String {
    guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
      return field
    }
    return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  static func fixed(_ value: Double) -> String { String(format: "%.4f", value) }

  static func csvOptional(_ value: Double?) -> String { value.map(fixed) ?? "" }

  // MARK: JSON

  static func json(_ rows: [RatingRow]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    let rounded = rows.map(rounded)
    guard let data = try? encoder.encode(rounded) else { return "[]\n" }
    return String(decoding: data, as: UTF8.self) + "\n"
  }

  /// Rounds every number to 4 decimals so the output does not change with the last bit
  /// of floating-point noise.
  static func rounded(_ row: RatingRow) -> RatingRow {
    func r(_ x: Double) -> Double { (x * 10_000).rounded() / 10_000 }
    var out = row
    out.rating = r(row.rating)
    out.ciLow = r(row.ciLow)
    out.ciHigh = r(row.ciHigh)
    out.puzzleAccuracy = row.puzzleAccuracy.mapValues(r)
    out.puzzleOverall = row.puzzleOverall.map(r)
    out.winRateVsD4 = row.winRateVsD4.map(r)
    out.blundersPerGame = row.blundersPerGame.map(r)
    out.wouldBeIllegalRate = row.wouldBeIllegalRate.map(r)
    out.medianMoveMs = row.medianMoveMs.map(r)
    out.tokensPerSecond = row.tokensPerSecond.map(r)
    out.loadTimeMs = row.loadTimeMs.map(r)
    out.peakRAMGB = row.peakRAMGB.map(r)
    out.sizeGB = row.sizeGB.map(r)
    return out
  }
}
