#if DEBUG
  import AppKit
  import Darwin
  import C4AI
  import C4Core

  /// Scripted positions for screenshots, set with launch arguments (DEBUG builds only):
  ///
  ///     LLMConnectFour -demoPosition midgame|win -demoAppearance light|dark
  ///                    -demoMoves 3,2,4 -demoSnapshot name.png -demoSnapshotDelay 12
  ///
  /// `-demoSnapshot` captures the main window (as the window server composites it) into
  /// the sandbox temp folder and quits.
  @MainActor
  enum DemoPositions {
    /// Twelve plies, human to move. The model's three in a row on row 2 is blocked at both ends.
    static let midgame: [Column] = [3, 3, 4, 2, 2, 4, 5, 5, 1, 6, 6, 3]
    /// Continues `midgame`; the model completes the diagonal 7-6-5-4 on ply 16.
    static let win: [Column] = midgame + [5, 4, 4, 3]

    static func applyLaunchArguments(to game: GameViewModel) {
      if let script = UserDefaults.standard.string(forKey: "demoMoves") {
        play(script.split(separator: ",").compactMap { Int($0) }, in: game)
        return
      }
      switch UserDefaults.standard.string(forKey: "demoPosition") {
      case "midgame": show(midgame, in: game, reasoning: midgameReasoning)
      case "win": show(win, in: game, reasoning: winReasoning)
      default: break
      }
    }

    /// Plays the human's moves (0-based columns) against the real provider, waiting for
    /// each AI reply, so a screenshot shows a genuine game.
    private static func play(_ columns: [Column], in game: GameViewModel) {
      Task {
        try? await Task.sleep(for: .seconds(0.8))
        for column in columns where !game.board.isGameOver {
          game.humanDrop(column)
          await game.waitForAITurn()
          try? await Task.sleep(for: .milliseconds(500))
        }
      }
    }

    /// Called when the main window appears.
    static func windowAppeared() {
      applyAppearance()
      guard let name = UserDefaults.standard.string(forKey: "demoSnapshot") else { return }
      Task {
        let delay = UserDefaults.standard.double(forKey: "demoSnapshotDelay")
        try? await Task.sleep(for: .seconds(delay > 0 ? delay : 2.5))
        snapshot(named: name)
        NSApp.terminate(nil)
      }
    }

    private static func snapshot(named name: String) {
      guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
        return
      }
      let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
      // The window server's own composite (glass included) of this app's window. The
      // symbol is unavailable to Swift in the current SDK, so look it up at run time.
      typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
      if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        // .optionIncludingWindow = 1 << 3; .boundsIgnoreFraming = 1 << 0, .bestResolution = 1 << 3
        if let image = create(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?
          .takeRetainedValue()
        {
          let rep = NSBitmapImageRep(cgImage: image)
          try? rep.representation(using: .png, properties: [:])?.write(to: url)
          print("snapshot (window server): \(url.path)")
          return
        }
      }
      print("snapshot failed")
    }

    static func applyAppearance() {
      switch UserDefaults.standard.string(forKey: "demoAppearance") {
      case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
      case "light": NSApp.appearance = NSAppearance(named: .aqua)
      default: break
      }
    }

    private static func show(_ moves: [Column], in game: GameViewModel, reasoning: String) {
      guard let board = try? Board(moves: moves) else { return }
      let lastAI = moves.count - (board.toMove == game.aiDisc ? 2 : 1)
      let before = try? Board(moves: moves.prefix(lastAI))
      let column = moves[lastAI]
      let legal = before?.legalMoves ?? Board.allColumns
      var logits = Board.allColumns.map { 1.2 - Double(abs($0 - 3)) * 0.35 }
      logits[column] += 2.1
      let distribution = ColumnDistribution.softmax(logits: logits, allowed: legal)
      let move = AIMove(
        column: column, distribution: distribution, reasoning: reasoning, source: .model,
        timings: MoveTimings(
          prefillMs: 41, timeToFirstTokenMs: 63, decodeTokensPerSecond: 38, totalMs: 2140,
          generatedTokens: 52, prefixCacheHit: true))
      var turn = GameViewModel.AITurn(ply: lastAI)
      turn.reasoning = reasoning
      turn.reasoningTokens = 52
      turn.distribution = distribution
      turn.move = move
      game.setPosition(moves, aiTurn: turn)
    }

    static let midgameReasoning =
      "X just blocked column 7, so row 2 is closed for now. Column 4 keeps the centre and lands on row 3, above my discs on row 2. X has no immediate threat that needs an answer."
    static let winReasoning =
      "My discs at column 7 row 1, column 6 row 2 and column 5 row 3 form a diagonal. Column 4 lands on row 4 and completes four in a row."
  }
#endif
