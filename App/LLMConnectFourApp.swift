import AppKit
import C4AI
import C4MLX
import SwiftUI

@main
struct LLMConnectFourApp: App {
  /// One game per app: the model is loaded once and shared by the window and the menus.
  @State private var game: GameViewModel

  init() {
    // `-mockModel YES` (or any demo position) plays against the mock instead of loading an
    // LLM, for demos and screenshots.
    let defaults = UserDefaults.standard
    let useMock =
      defaults.bool(forKey: "mockModel") || defaults.string(forKey: "demoPosition") != nil
    let game = GameViewModel(providerFactory: { spec -> any MoveProvider in
      if useMock { return MockMoveProvider(name: spec.name) }
      return LLMMoveProvider(spec: spec)
    })
    game.gameStore = .default
    #if DEBUG
      DemoPositions.applyLaunchArguments(to: game)
    #endif
    _game = State(initialValue: game)
  }

  var body: some Scene {
    Window("LLM Connect Four", id: "main") {
      ContentView(game: game)
        .frame(minWidth: DesignTokens.Window.minWidth, minHeight: DesignTokens.Window.minHeight)
        #if DEBUG
          .onAppear { DemoPositions.windowAppeared() }
        #endif
    }
    .defaultSize(width: 1240, height: 820)
    .windowToolbarStyle(.unified)
    .commands { GameCommands(game: game) }

    Window("Leaderboard", id: "leaderboard") {
      Text("Leaderboard")
        .frame(minWidth: 720, minHeight: 420)
    }

    Settings {
      SettingsView(game: game)
    }
  }
}

/// ⌘N new game, ⌘T thinking, ⌘L leaderboard. (⌘, comes with the Settings scene; 1 to 7 are
/// handled by the board so they never steal typing elsewhere.)
struct GameCommands: Commands {
  @Bindable var game: GameViewModel
  @Environment(\.openWindow) private var openWindow
  @FocusedBinding(\.showRecentGames) private var showRecentGames

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Game") { game.newGame() }
        .keyboardShortcut("n")
    }
    CommandGroup(before: .sidebar) {
      Toggle("Show Thinking", isOn: $game.showThinking)
        .keyboardShortcut("t")
      Divider()
    }
    CommandGroup(before: .windowList) {
      Button("Leaderboard") { openWindow(id: "leaderboard") }
        .keyboardShortcut("l")
      Button("Recent Games") { showRecentGames = true }
        .keyboardShortcut("y")
        .disabled(showRecentGames == nil)
      Divider()
    }
  }
}
