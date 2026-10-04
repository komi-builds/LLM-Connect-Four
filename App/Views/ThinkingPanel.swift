import C4AI
import C4Core
import SwiftUI

/// The Thinking inspector (§4, §6): plain text on the system surface, no glass inside.
/// Agent F replaces `ThinkingPanel` and `ConfidenceBars` with the full versions.
struct InspectorView: View {
  var game: GameViewModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
        InspectorHeader(game: game)
        if let turn = game.aiTurn {
          ThinkingPanel(turn: turn, style: game.record.style, isLive: game.isAITurnActive)
          InspectorSection("Confidence") {
            ConfidenceBars(
              distribution: turn.distribution, chosen: turn.move?.column, isLive: turn.isStreaming)
          }
          if let move = turn.move {
            StatsLine(move: move, providerName: game.provider.name)
          }
        } else {
          YourMoveEmptyState(game: game)
        }
      }
      .padding(DesignTokens.Spacing.m)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollContentBackground(.hidden)
  }
}

private struct InspectorHeader: View {
  var game: GameViewModel

  var body: some View {
    HStack(alignment: .center, spacing: DesignTokens.Spacing.s) {
      DiscView(side: .ai, diameter: 26)
      VStack(alignment: .leading, spacing: 1) {
        Text(game.opponentName)
          .font(.headline)
          .lineLimit(1)
        Text("\(game.effectiveStyle.displayName) · \(game.difficulty.displayName)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      if game.isAIStreaming {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Thinking")
      }
    }
  }
}

/// A titled block in the inspector.
struct InspectorSection<Content: View>: View {
  var title: LocalizedStringKey
  var trailing: Text?
  @ViewBuilder var content: Content

  init(_ title: LocalizedStringKey, trailing: Text? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.trailing = trailing
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
      HStack(alignment: .firstTextBaseline) {
        Text(title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        trailing?
          .font(.caption.monospacedDigit())
          .foregroundStyle(.tertiary)
      }
      content
    }
  }
}

/// "Your move": shown before the first AI turn of a game, with load progress if relevant.
private struct YourMoveEmptyState: View {
  var game: GameViewModel

  var body: some View {
    VStack(spacing: DesignTokens.Spacing.m) {
      ContentUnavailableView {
        Label("Your move", systemImage: "hand.point.down")
      } description: {
        Text(
          "Drop a disc with a click or the keys 1 to 7. The model's thinking streams here while it plays."
        )
      }
      if let progress = game.loadProgress, !game.isModelReady {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
          ProgressView(value: progress.fraction)
          Text(LoadProgressText(progress: progress).description)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, DesignTokens.Spacing.s)
      }
    }
    .padding(.top, DesignTokens.Spacing.xl)
  }
}

/// Thoughts (Deep think, collapsible, monospaced) and reasoning (body text).
struct ThinkingPanel: View {
  var turn: GameViewModel.AITurn
  var style: ThinkingStyle
  var isLive: Bool

  @State private var thoughtsExpanded = true

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
      if style == .deepThink || !turn.thinking.isEmpty {
        DisclosureGroup(isExpanded: $thoughtsExpanded) {
          Text(
            turn.thinking.isEmpty
              ? String(localized: "Waiting for the first thought…") : turn.thinking
          )
          .font(.callout.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, DesignTokens.Spacing.xs)
        } label: {
          HStack {
            Text("Thoughts")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.secondary)
            Spacer()
            Text("\(turn.thinkingTokens) / \(style.defaultBudget) tokens")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.tertiary)
          }
        }
      }

      InspectorSection("Reasoning") {
        Group {
          if !turn.reasoning.isEmpty {
            Text(turn.reasoning)
          } else if style == .instinct {
            Text("Instinct answers in a single step, with no written reasoning.")
              .foregroundStyle(.secondary)
          } else if let error = turn.error {
            Text(error).foregroundStyle(.red)
          } else {
            Text(isLive ? "Reading the board…" : "No reasoning for this move.")
              .foregroundStyle(.secondary)
          }
        }
        .font(.body)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.default, value: turn.reasoning.isEmpty)
      }
    }
  }
}

/// Time to first token, tok/s, total time, and a source badge.
struct StatsLine: View {
  var move: AIMove
  var providerName: String

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
      HStack(spacing: DesignTokens.Spacing.s) {
        SourceBadge(source: move.source)
        Text(providerName)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Text(stats)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
  }

  private var stats: String {
    let t = move.timings
    var parts = [String(localized: "First token \(Int(t.timeToFirstTokenMs.rounded())) ms")]
    if t.decodeTokensPerSecond > 0 {
      parts.append(String(localized: "\(Int(t.decodeTokensPerSecond.rounded())) tok/s"))
    }
    parts.append(String(localized: "\(String(format: "%.1f", t.totalMs / 1000)) s total"))
    return parts.joined(separator: " · ")
  }
}

struct SourceBadge: View {
  var source: MoveSource

  var body: some View {
    let (title, color): (LocalizedStringKey, Color) =
      switch source {
      case .model: ("model", DesignTokens.Colors.aiText)
      case .modelAfterSelfCheck: ("self-checked", .indigo)
      case .fallback: ("fallback", .orange)
      }
    Text(title)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .foregroundStyle(color)
      .background(Capsule().fill(color.opacity(0.14)))
      .accessibilityLabel(Text("Source: \(Text(title))"))
  }
}

/// "Downloading 42%  ·  42 MB/s" and friends.
struct LoadProgressText: CustomStringConvertible {
  var progress: LoadProgress

  var description: String {
    let percent = Int((progress.fraction * 100).rounded())
    switch progress.phase {
    case .downloading:
      if let speed = progress.bytesPerSecond {
        let rate = ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file)
        return String(localized: "Downloading \(percent)% · \(rate)/s")
      }
      return String(localized: "Downloading \(percent)%")
    case .loading: return String(localized: "Loading \(percent)%")
    case .warmingUp: return String(localized: "Warming up… \(percent)%")
    case .ready: return String(localized: "Ready")
    }
  }
}
