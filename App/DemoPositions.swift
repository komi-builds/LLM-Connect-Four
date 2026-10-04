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
      case "stream": showStreaming(in: game)
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
      capture(window, to: url)
      // A sheet (replay, prompt inspector) is its own window: save it beside the main one.
      for sheet in window.sheets + (window.sheets.compactMap { $0.sheets }.flatMap { $0 })
      where sheet.isVisible {
        let name = name.replacingOccurrences(of: ".png", with: "-sheet\(sheet.windowNumber).png")
        capture(sheet, to: url.deletingLastPathComponent().appendingPathComponent(name))
      }
    }

    private static func capture(_ window: NSWindow, to url: URL) {
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

    /// Frozen mid-stream: Deep think on Hard, thoughts and half a sentence of reasoning
    /// written, the distribution leaning toward column 4. The glow is lit.
    private static func showStreaming(in game: GameViewModel) {
      let moves = midgame + [0]
      guard let board = try? Board(moves: moves) else { return }
      let context = TurnContext(
        board: board, style: .deepThink, profile: .profile(for: .hard), gameSeed: 7)
      var turn = GameViewModel.AITurn(ply: moves.count)
      turn.prompt = PromptBuilder.build(for: context)
      turn.thinking =
        "Okay, X just played column 1, which does nothing on the left edge. My three in a row on row 2 is blocked at both ends. Column 4 is open and lands on row 4. If I play column 4, X cannot reach row 5 above it without giving me something. Column 5 would let X play the diagonal. Let me check column 4 again: it keeps my diagonal alive."
      turn.thinkingTokens = 61
      turn.reasoning = "Column 4 keeps the centre and my diagonal, and X has no threat to answer"
      turn.reasoningTokens = 17
      let allowed = (turn.prompt?.allowedColumns ?? board.legalMoves).filter { $0 != 0 && $0 != 6 }
      var logits = Board.allColumns.map { 0.9 - Double(abs($0 - 3)) * 0.45 }
      logits[3] += 1.6
      logits[4] += 0.5
      turn.distribution = ColumnDistribution.softmax(logits: logits, allowed: allowed)
      game.setPosition(moves, aiTurn: turn, style: .deepThink)
    }

    /// A full saved game with traces, for the replay and prompt inspector screenshots.
    static func sampleRecord() -> GameRecord {
      var record = GameRecord(
        startedAt: Date().addingTimeInterval(-600), finishedAt: Date().addingTimeInterval(-540),
        opponentName: "Qwen3 4B Thinking", modelID: "mlx-community/Qwen3-4B-Thinking-2507-4bit",
        style: .deepThink, difficulty: .hard, variantID: PromptVariant.default.id, gameSeed: 7,
        moves: win, outcome: .win(.second))
      for index in win.indices where index.isMultiple(of: 2) == false {
        guard let before = try? Board(moves: win.prefix(index)) else { continue }
        let context = TurnContext(
          board: before, style: .deepThink, profile: .profile(for: .hard), gameSeed: 7)
        let prompt = PromptBuilder.build(for: context)
        var logits = Board.allColumns.map { 0.8 - Double(abs($0 - 3)) * 0.4 }
        logits[win[index]] += 2.2
        let distribution = ColumnDistribution.softmax(
          logits: logits, allowed: prompt.allowedColumns)
        let move = AIMove(
          column: win[index], distribution: distribution,
          thinking:
            "Let me read the board. The last move was column \(win[index - 1] + 1). I want a move that keeps my lines open and does not hand X a square. Column \(win[index] + 1) looks best.",
          reasoning:
            index == win.count - 1
            ? winReasoning
            : "Column \(win[index] + 1) builds toward my diagonal and gives X nothing on the row above.",
          source: index == 5 ? .modelAfterSelfCheck : .model,
          timings: MoveTimings(
            prefillMs: 52, timeToFirstTokenMs: 71, decodeTokensPerSecond: 41,
            totalMs: 2400 + Double(index) * 90, generatedTokens: 84, prefixCacheHit: true))
        record.traces.append(
          MoveTrace(
            context: context, provider: record.opponentName, modelID: record.modelID,
            prompt: prompt, move: move))
      }
      return record
    }

    static let midgameReasoning =
      "X just blocked column 7, so row 2 is closed for now. Column 4 keeps the centre and lands on row 3, above my discs on row 2. X has no immediate threat that needs an answer."
    static let winReasoning =
      "My discs at column 7 row 1, column 6 row 2 and column 5 row 3 form a diagonal. Column 4 lands on row 4 and completes four in a row."
  }
#endif
