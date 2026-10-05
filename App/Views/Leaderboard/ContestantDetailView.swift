import C4AI
import C4Bench
import C4Core
import Charts
import SwiftUI

/// The inspector for one contestant: results per opponent, puzzle accuracy by category, the
/// worst blunders and the list of games. Clicking a game or a blunder opens the replay.
struct ContestantDetailView: View {
  var row: LeaderboardRow
  var detail: ContestantDetail
  /// Opens a game in the replay, optionally at a move (number of discs on the board).
  var onOpenGame: (BenchGame, Int?) -> Void

  @State private var showAllGames = false
  private let gameLimit = 30

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
        header
        resultsSection
        puzzleSection
        blunderSection
        gamesSection
      }
      .padding(DesignTokens.Spacing.m)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(.background)
  }

  // MARK: Header

  private var header: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      Text(row.name)
        .font(.title3.weight(.semibold))
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: DesignTokens.Spacing.s) {
        Text("Rank \(row.rankLabel)")
        Text("·")
        Text(LeaderboardColumn.rating.text(row) ?? "").monospacedDigit()
        if row.isAnchor {
          Text("anchor")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
        }
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
      Text(
        "\(row.row.games) games: \(row.row.wins) won, \(row.row.draws) drawn, \(row.row.losses) lost"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .monospacedDigit()
    }
  }

  // MARK: Results

  private var resultsSection: some View {
    section("Results by opponent") {
      if detail.matchups.isEmpty {
        Text("No games yet.").foregroundStyle(.secondary)
      } else {
        Grid(alignment: .trailing, horizontalSpacing: DesignTokens.Spacing.m, verticalSpacing: 5) {
          GridRow {
            Text("Opponent").gridColumnAlignment(.leading)
            Text("W")
            Text("D")
            Text("L")
            Text("Score")
          }
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
          Divider().gridCellUnsizedAxes(.horizontal)
          ForEach(detail.matchups) { matchup in
            GridRow {
              Text(matchup.opponent.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(matchup.opponent.isAnchor ? .primary : .secondary)
                .gridColumnAlignment(.leading)
              Text("\(matchup.wins)")
              Text("\(matchup.draws)")
              Text("\(matchup.losses)")
              Text(scoreText(matchup))
                .foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .font(.callout)
          }
        }
      }
    }
  }

  private func scoreText(_ matchup: ContestantDetail.Matchup) -> String {
    guard matchup.total > 0 else { return "" }
    let points = Double(matchup.wins) + Double(matchup.draws) / 2
    return String(format: "%.0f%%", points / Double(matchup.total) * 100)
  }

  // MARK: Puzzles

  private var puzzleSection: some View {
    section("Puzzle accuracy") {
      if detail.categories.isEmpty {
        Text(
          row.isAnchor
            ? "Anchors do not take the puzzle suite." : "No puzzle answers recorded yet."
        )
        .foregroundStyle(.secondary)
      } else {
        Chart(detail.categories) { item in
          BarMark(
            x: .value("Category", item.category.shortTitle),
            y: .value("Accuracy", item.fraction * 100)
          )
          .foregroundStyle(DesignTokens.Colors.ai.gradient)
          .cornerRadius(4)
          .annotation(position: .overlay, alignment: .top) {
            Text("\(Int((item.fraction * 100).rounded()))%")
              .font(.caption2.weight(.semibold).monospacedDigit())
              .fixedSize()
              .foregroundStyle(.black.opacity(0.7))
              .padding(.top, 4)
          }
          .accessibilityLabel(item.category.title)
          .accessibilityValue("\(Int((item.fraction * 100).rounded())) percent")
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
          AxisMarks(values: [0, 50, 100])
        }
        .frame(height: DesignTokens.Chart.height)
        VStack(alignment: .leading, spacing: 1) {
          ForEach(detail.categories) { item in
            Text(
              "\(item.category.shortTitle): \(item.category.title), \(item.correct) of \(item.total)"
            )
          }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .monospacedDigit()
      }
    }
  }

  // MARK: Blunders

  private var blunderSection: some View {
    section("Worst blunders") {
      if detail.blunders.isEmpty {
        Text("No blunders found in the saved games.").foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(detail.blunders) { item in
            Button {
              if let game = detail.games.first(where: { $0.id == item.gameID })?.game {
                onOpenGame(game, item.ply + 1)
              }
            } label: {
              VStack(alignment: .leading, spacing: 1) {
                Text(blunderTitle(item))
                  .font(.callout)
                Text(blunderDetail(item))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.vertical, 4)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
  }

  private func blunderTitle(_ item: ContestantDetail.BlunderRecord) -> String {
    let missed = item.missed.map { "\($0 + 1)" }.joined(separator: " or ")
    switch item.kind {
    case .missedWin:
      return String(localized: "Move \(item.ply + 1): missed a win in column \(missed)")
    case .missedBlock:
      return String(localized: "Move \(item.ply + 1): missed a block in column \(missed)")
    }
  }

  private func blunderDetail(_ item: ContestantDetail.BlunderRecord) -> String {
    String(localized: "Played column \(item.played + 1) against \(item.opponent.displayName)")
  }

  // MARK: Games

  private var gamesSection: some View {
    section("Games (\(detail.games.count))") {
      let shown = showAllGames ? detail.games : Array(detail.games.prefix(gameLimit))
      VStack(alignment: .leading, spacing: 0) {
        ForEach(shown) { entry in
          Button {
            onOpenGame(entry.game, nil)
          } label: {
            HStack(spacing: DesignTokens.Spacing.s) {
              resultBadge(entry.result)
              VStack(alignment: .leading, spacing: 1) {
                Text("vs \(entry.opponent.displayName)")
                  .font(.callout)
                  .lineLimit(1)
                Text(
                  "\(entry.wasFirst ? String(localized: "First") : String(localized: "Second")) · \(entry.game.moves.count) moves · \(entry.game.finishedAt.formatted(date: .abbreviated, time: .shortened))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
              }
              Spacer(minLength: 0)
              Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          Divider()
        }
        if detail.games.count > gameLimit && !showAllGames {
          Button("Show all \(detail.games.count) games") { showAllGames = true }
            .buttonStyle(.link)
            .padding(.top, DesignTokens.Spacing.s)
        }
      }
    }
  }

  private func resultBadge(_ result: GameResult) -> some View {
    let (letter, color): (String, Color) =
      switch result {
      case .win: ("W", .green)
      case .draw: ("D", .secondary)
      case .loss: ("L", .red)
      }
    return Text(letter)
      .font(.caption.weight(.bold).monospaced())
      .foregroundStyle(color)
      .frame(width: 22, height: 22)
      .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
      .accessibilityLabel(
        result == .win ? "Won" : (result == .draw ? "Drawn" : "Lost"))
  }

  private func section<Content: View>(
    _ title: LocalizedStringKey, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
      Text(title).font(.headline)
      content()
    }
  }
}
