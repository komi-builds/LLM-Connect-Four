import C4AI
import C4Core
import SwiftUI

/// The game window: gradient, board, status area, system toolbar and the Thinking inspector.
struct ContentView: View {
  @Bindable var game: GameViewModel

  @FocusState private var boardFocused: Bool

  var body: some View {
    ZStack {
      MeshBackground(isPaused: game.isAIStreaming)
        .ignoresSafeArea()
        .backgroundExtensionEffect()

      VStack(spacing: DesignTokens.Spacing.l) {
        BoardView(game: game)
        StatusArea(game: game)
          .frame(height: 76)
      }
      .padding(.horizontal, DesignTokens.Spacing.xl)
      .padding(.top, DesignTokens.Spacing.m)
      .padding(.bottom, DesignTokens.Spacing.l)
    }
    .focusable()
    .focusEffectDisabled()
    .focused($boardFocused)
    .onKeyPress(characters: .decimalDigits, phases: .down) { press in
      guard let digit = Int(press.characters), (1...Board.columnCount).contains(digit) else {
        return .ignored
      }
      game.humanDrop(digit - 1)
      return .handled
    }
    .onAppear { boardFocused = true }
    .onChange(of: game.board.winner) { _, winner in
      if winner != nil { Feedback.gameWon() }
    }
    .toolbar { GameToolbar(game: game) }
    .inspector(isPresented: $game.showThinking) {
      InspectorView(game: game)
        .inspectorColumnWidth(
          min: DesignTokens.Window.inspectorMin, ideal: DesignTokens.Window.inspectorIdeal,
          max: DesignTokens.Window.inspectorMax)
    }
    .navigationTitle("LLM Connect Four")
  }
}

// MARK: Toolbar

/// The system toolbar (§6): segmented pickers, the model menu, New Game, then plain items,
/// with groups separated by `ToolbarSpacer`. No custom pill container.
struct GameToolbar: ToolbarContent {
  @Bindable var game: GameViewModel
  @Environment(\.openWindow) private var openWindow

  private var lockedHelp: LocalizedStringKey { "Change this between games" }

  var body: some ToolbarContent {
    ToolbarItem {
      Picker("Difficulty", selection: $game.difficulty) {
        ForEach(Difficulty.allCases) { difficulty in
          Text(difficulty.displayName).tag(difficulty)
        }
      }
      .pickerStyle(.segmented)
      .disabled(!game.canChangeSettings)
      .help(game.canChangeSettings ? "Difficulty" : lockedHelp)
    }
    ToolbarSpacer(.fixed)
    ToolbarItem {
      Picker("Thinking style", selection: styleBinding) {
        ForEach(ThinkingStyle.allCases) { style in
          Text(style.displayName)
            .tag(style)
            .selectionDisabled(style == .deepThink && !game.canDeepThink)
        }
      }
      .pickerStyle(.segmented)
      .disabled(!game.canChangeSettings)
      .help(styleHelp)
    }
    ToolbarSpacer(.fixed)
    ToolbarItem {
      ModelMenu(game: game)
    }
    ToolbarSpacer(.fixed)
    ToolbarItem {
      Button("New Game", systemImage: "arrow.counterclockwise") { game.newGame() }
        .labelStyle(.titleOnly)
        .buttonStyle(.glassProminent)
        .tint(DesignTokens.Colors.human)
        .help("Start a new game (⌘N)")
    }
    ToolbarSpacer(.fixed)
    ToolbarItemGroup {
      Button("Leaderboard", systemImage: "trophy") { openWindow(id: "leaderboard") }
        .help("Leaderboard (⌘L)")
      Toggle("Show Thinking", systemImage: "brain.head.profile", isOn: $game.showThinking)
        .help("Show thinking (⌘T)")
    }
  }

  /// Rejects Deep think for models without native thinking, even if a picker lets it through.
  private var styleBinding: Binding<ThinkingStyle> {
    Binding(
      get: { game.style },
      set: { newValue in
        if newValue == .deepThink, !game.canDeepThink { return }
        game.style = newValue
      })
  }

  private var styleHelp: LocalizedStringKey {
    if !game.canChangeSettings { return lockedHelp }
    if !game.canDeepThink {
      return
        "Deep think needs a model with native thinking. \(game.opponentName) answers with Explain instead."
    }
    return "How much the model thinks before it answers"
  }
}

/// The model choice. Selecting only stores it for now; the integration step loads it.
private struct ModelMenu: View {
  @Bindable var game: GameViewModel

  var body: some View {
    Menu {
      Picker("Model", selection: $game.selectedModelID) {
        ForEach(game.models) { model in
          Text(model.name + (model.thinking ? String(localized: " · thinks") : ""))
            .tag(Optional(model.id))
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()
    } label: {
      Label(game.opponentName, systemImage: "cpu")
        .labelStyle(.titleAndIcon)
    }
    .disabled(!game.canChangeSettings || game.models.isEmpty)
    .help(game.canChangeSettings ? "Model" : "Change this between games")
  }
}

// MARK: Status area

/// Below the board: whose turn it is, the warming-up pill, or the result card.
private struct StatusArea: View {
  var game: GameViewModel

  var body: some View {
    ZStack {
      switch game.status {
      case .humanTurn:
        if let error = game.loadError {
          LoadErrorBanner(message: error) { game.startLoading() }
        } else {
          TurnIndicator(
            side: .human, title: "Your move",
            detail: game.board.plyCount == 0 ? "Click a column or press 1 to 7" : nil)
        }
      case .aiThinking:
        TurnIndicator(
          side: .ai, title: "\(game.opponentName) is thinking…", detail: nil, showsProgress: true)
      case .warmingUp:
        WarmingUpPill(progress: game.loadProgress)
      case .gameOver(let outcome):
        ResultCard(game: game, outcome: outcome)
      }
    }
    .frame(maxWidth: .infinity)
    .animation(DesignTokens.Motion.card, value: game.status)
  }
}

private struct TurnIndicator: View {
  var side: DiscSide
  var title: LocalizedStringKey
  var detail: LocalizedStringKey?
  var showsProgress = false

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.s) {
      DiscView(side: side, diameter: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.title3.weight(.semibold))
        if let detail {
          Text(detail).font(.callout).foregroundStyle(.secondary)
        }
      }
      if showsProgress {
        ProgressView().controlSize(.small).padding(.leading, DesignTokens.Spacing.xs)
      }
    }
    .transition(.opacity)
    .accessibilityElement(children: .combine)
  }
}

/// "Warming up… 63%": the human moved before the model finished loading (§1).
private struct WarmingUpPill: View {
  var progress: LoadProgress?

  var body: some View {
    let fraction = progress?.fraction ?? 0
    HStack(spacing: DesignTokens.Spacing.s) {
      ProgressView(value: fraction)
        .progressViewStyle(.circular)
        .controlSize(.small)
      Text("Warming up… \(Int((fraction * 100).rounded()))%")
        .font(.callout.weight(.medium).monospacedDigit())
    }
    .padding(.horizontal, DesignTokens.Spacing.m)
    .padding(.vertical, 10)
    .glassEffect(.regular, in: .capsule)
    .transition(.opacity.combined(with: .scale(scale: 0.9)))
    .accessibilityElement(children: .combine)
  }
}

private struct LoadErrorBanner: View {
  var message: String
  var retry: () -> Void

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.s) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      Text("The model couldn't load: \(message)")
        .lineLimit(2)
      Button("Retry", action: retry)
    }
    .font(.callout)
    .padding(.horizontal, DesignTokens.Spacing.m)
    .padding(.vertical, 10)
    .background(.background.secondary, in: .rect(cornerRadius: DesignTokens.Radius.small))
  }
}

/// The game-over card (§6): a `GlassEffectContainer` with Rematch, Replay and Swap model.
private struct ResultCard: View {
  var game: GameViewModel
  var outcome: GameOutcome

  var body: some View {
    GlassEffectContainer(spacing: DesignTokens.Spacing.m) {
      HStack(spacing: DesignTokens.Spacing.l) {
        HStack(spacing: DesignTokens.Spacing.s + 2) {
          resultMark
          VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
          }
        }
        HStack(spacing: DesignTokens.Spacing.s) {
          Button("Replay", systemImage: "play.circle") {}
            .buttonStyle(.glass)
            .disabled(true)
            .help("Replay arrives with the Thinking views")
          SwapModelMenu(game: game)
          Button("Rematch", systemImage: "arrow.counterclockwise") { game.newGame() }
            .buttonStyle(.glassProminent)
            .tint(DesignTokens.Colors.human)
            .keyboardShortcut(.defaultAction)
        }
        .labelStyle(.titleOnly)
        .controlSize(.large)
      }
      .padding(.leading, DesignTokens.Spacing.l)
      .padding(.trailing, DesignTokens.Spacing.m)
      .padding(.vertical, DesignTokens.Spacing.m)
      .glassEffect(.regular, in: .rect(cornerRadius: DesignTokens.Radius.card))
    }
    .transition(.opacity.combined(with: .offset(y: 12)))
  }

  @ViewBuilder
  private var resultMark: some View {
    switch outcome {
    case .win(let disc): DiscView(side: disc == game.humanDisc ? .human : .ai, diameter: 28)
    case .draw:
      HStack(spacing: -10) {
        DiscView(side: .human, diameter: 24)
        DiscView(side: .ai, diameter: 24)
      }
    }
  }

  private var title: LocalizedStringKey {
    switch outcome {
    case .win(let disc) where disc == game.humanDisc: "You win"
    case .win: "\(game.opponentName) wins"
    case .draw: "Draw"
    }
  }

  private var subtitle: LocalizedStringKey {
    switch outcome {
    case .win: "Four in a row after \(game.board.plyCount) moves."
    case .draw: "The board is full."
    }
  }
}

private struct SwapModelMenu: View {
  var game: GameViewModel

  var body: some View {
    Menu("Swap model") {
      ForEach(game.models) { model in
        Button(model.name) {
          game.selectedModelID = model.id
          game.newGame()
        }
        .disabled(model.id == game.selectedModelID)
      }
    }
    .menuIndicator(.hidden)
    .buttonStyle(.glass)
    .disabled(game.models.count < 2)
  }
}
