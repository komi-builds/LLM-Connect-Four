import C4AI
import C4Core
import SwiftUI

/// The Thinking inspector (§4, §6): plain text on the system surface, no glass inside.
struct InspectorView: View {
  var game: GameViewModel

  var body: some View {
    if let turn = game.aiTurn {
      TurnDetailView(
        turn: turn, style: game.record.style, title: game.opponentName,
        subtitle: "\(game.record.style.displayName) · \(game.record.difficulty.displayName)",
        providerName: game.provider.name, isLive: turn.isStreaming,
        isStreaming: game.isAIStreaming || turn.isStreaming)
    } else {
      VStack(alignment: .leading, spacing: 0) {
        TurnHeader(
          title: game.opponentName,
          subtitle: "\(game.effectiveStyle.displayName) · \(game.difficulty.displayName)",
          isStreaming: false, prompt: nil, showPrompt: .constant(false))
        YourMoveEmptyState(game: game)
        Spacer(minLength: 0)
      }
    }
  }
}

/// One AI turn, live or from a saved trace: header, scrolling thoughts and reasoning, and
/// the confidence bars and stats pinned below so they never jump while text streams in.
/// Used by the inspector and by the replay.
struct TurnDetailView: View {
  var turn: GameViewModel.AITurn
  var style: ThinkingStyle
  var title: String
  var subtitle: String
  var providerName: String
  var isLive: Bool
  var isStreaming = false

  @State private var showPrompt = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      TurnHeader(
        title: title, subtitle: subtitle, isStreaming: isStreaming, prompt: turn.prompt,
        showPrompt: $showPrompt)

      ScrollViewReader { proxy in
        ScrollView {
          ThinkingPanel(turn: turn, style: style, isLive: isLive)
            .padding(.horizontal, DesignTokens.Spacing.m)
            .padding(.bottom, DesignTokens.Spacing.m)
          Color.clear.frame(height: 1).id(ThinkingPanel.bottomID)
        }
        .scrollContentBackground(.hidden)
        .onChange(of: turn.reasoning) { scrollToEnd(proxy) }
        .onChange(of: turn.thinking) { scrollToEnd(proxy) }
      }

      Divider()
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
        InspectorSection("Confidence") {
          ConfidenceBars(
            distribution: turn.distribution, chosen: turn.move?.column, isLive: turn.isStreaming)
        }
        if let move = turn.move {
          StatsLine(move: move, providerName: providerName)
        } else if isLive {
          Text("Streaming…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(DesignTokens.Spacing.m)
    }
    #if DEBUG
      .onAppear {
        if UserDefaults.standard.bool(forKey: "demoPrompt"), turn.prompt != nil {
          showPrompt = true
        }
      }
    #endif
    .sheet(isPresented: $showPrompt) {
      if let prompt = turn.prompt {
        PromptInspector(prompt: prompt, subtitle: "\(title) · \(subtitle)")
      }
    }
  }

  private func scrollToEnd(_ proxy: ScrollViewProxy) {
    guard isLive else { return }
    proxy.scrollTo(ThinkingPanel.bottomID, anchor: .bottom)
  }
}

struct TurnHeader: View {
  var title: String
  var subtitle: String
  var isStreaming: Bool
  var prompt: Prompt?
  @Binding var showPrompt: Bool

  var body: some View {
    HStack(alignment: .center, spacing: DesignTokens.Spacing.s) {
      DiscView(side: .ai, diameter: 26)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.headline)
          .lineLimit(1)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      if isStreaming {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Thinking")
      }
      Button {
        showPrompt = true
      } label: {
        Label("What the model sees", systemImage: "eye")
          .labelStyle(.iconOnly)
      }
      .buttonStyle(.borderless)
      .disabled(prompt == nil)
      .help(prompt == nil ? "No prompt for this move" : "What the model sees")
    }
    .padding(DesignTokens.Spacing.m)
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
        .padding(.horizontal, DesignTokens.Spacing.m)
      }
    }
    .padding(.top, DesignTokens.Spacing.xl)
  }
}

/// Thoughts (Deep think, collapsible, dim monospace, with a token counter) and reasoning
/// (body text), streaming live.
struct ThinkingPanel: View {
  static let bottomID = "thinking-panel-bottom"

  var turn: GameViewModel.AITurn
  var style: ThinkingStyle
  var isLive: Bool

  @State private var thoughtsExpanded = true

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
      if style == .deepThink || !turn.thinking.isEmpty {
        DisclosureGroup(isExpanded: $thoughtsExpanded) {
          ThoughtsText(text: turn.thinking, isLive: isLive)
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
              .contentTransition(.numericText())
              .animation(.default, value: turn.thinkingTokens)
          }
        }
      }

      InspectorSection(
        "Reasoning",
        trailing: style == .explain && turn.reasoningTokens > 0
          ? Text("\(turn.reasoningTokens) / \(style.defaultBudget) tokens") : nil
      ) {
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

/// The thoughts in a height-capped scroller that follows the newest token while live.
private struct ThoughtsText: View {
  var text: String
  var isLive: Bool

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          Text(text.isEmpty ? String(localized: "Waiting for the first thought…") : text)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
          Color.clear.frame(height: 1).id("thoughts-end")
        }
      }
      .frame(maxHeight: 190)
      .fixedSize(horizontal: false, vertical: true)
      .onChange(of: text) {
        if isLive { proxy.scrollTo("thoughts-end", anchor: .bottom) }
      }
    }
  }
}

/// Time to first token, tok/s, total time, and a source badge.
struct StatsLine: View {
  var move: AIMove
  var providerName: String

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
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

/// `model`, `self-checked` or `fallback`. Each has its own colour and symbol; fallback
/// carries the warning tint.
struct SourceBadge: View {
  var source: MoveSource

  var body: some View {
    let (title, symbol, color, help): (LocalizedStringKey, String, Color, LocalizedStringKey) =
      switch source {
      case .model:
        ("model", "cpu", DesignTokens.Colors.aiText, "The model's own answer")
      case .modelAfterSelfCheck:
        (
          "self-checked", "checkmark.seal", DesignTokens.Colors.selfChecked,
          "The model answered again after a self-check"
        )
      case .fallback:
        (
          "fallback", "exclamationmark.triangle.fill", DesignTokens.Colors.warning,
          "The model failed, so a simple engine played this move"
        )
      }
    Label(title, systemImage: symbol)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .foregroundStyle(color)
      .background(Capsule().fill(color.opacity(source == .fallback ? 0.2 : 0.14)))
      .help(help)
      .accessibilityElement(children: .ignore)
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
