import C4AI
import C4Core
import SwiftUI

/// Steps through a finished game on a read-only board. Each AI move shows its full trace:
/// prompt (eye button), thoughts, reasoning, distribution and timing. Takes a `GameRecord`,
/// not the live view model, so saved games and benchmark games open the same way.
struct ReplayView: View {
  var record: GameRecord
  /// Show the Done button (when presented as a sheet).
  var showsDone = true

  @State private var state: ReplayState
  @State private var exportDocument: GameDocument?
  @State private var isExporting = false
  @Environment(\.dismiss) private var dismiss

  init(record: GameRecord, showsDone: Bool = true, initialPly: Int = 0) {
    self.record = record
    self.showsDone = showsDone
    _state = State(initialValue: ReplayState(record: record, ply: initialPly))
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      HStack(spacing: 0) {
        VStack(spacing: DesignTokens.Spacing.m) {
          ReplayBoard(state: state, humanDisc: record.humanDisc)
            .padding(.horizontal, DesignTokens.Spacing.m)
          controls
        }
        .padding(.vertical, DesignTokens.Spacing.m)
        .frame(maxWidth: .infinity)
        .background { MeshBackground(isPaused: true) }
        Divider()
        tracePane
          .frame(width: 340)
      }
    }
    .frame(minWidth: 860, minHeight: 600)
    .background(.background)
    #if DEBUG
      .onAppear {
        if let ply = UserDefaults.standard.string(forKey: "demoReplayPly").flatMap(Int.init) {
          state.seek(to: ply)
        }
      }
    #endif
    .fileExporter(
      isPresented: $isExporting, document: exportDocument, contentType: .json,
      defaultFilename: record.exportFilename
    ) { _ in }
    .onChange(of: record.id) { state = ReplayState(record: record, ply: 0) }
  }

  // MARK: Header

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.m) {
      VStack(alignment: .leading, spacing: 2) {
        Text(record.resultTitle).font(.title3.weight(.semibold))
        Text(record.summaryLine)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Export", systemImage: "square.and.arrow.up") {
        exportDocument = try? GameDocument(record: record)
        isExporting = exportDocument != nil
      }
      .help("Export this game as JSON")
      if showsDone {
        Button("Done") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(DesignTokens.Spacing.m)
  }

  // MARK: Controls

  private var controls: some View {
    VStack(spacing: DesignTokens.Spacing.s) {
      HStack(spacing: DesignTokens.Spacing.s) {
        Button("Previous move", systemImage: "chevron.left") {
          withAnimation(DesignTokens.Motion.drop) { state.stepBack() }
        }
        .keyboardShortcut(.leftArrow, modifiers: [])
        .disabled(!state.canStepBack)
        Slider(
          value: Binding(
            get: { Double(state.ply) },
            set: { value in withAnimation { state.seek(to: Int(value.rounded())) } }
          ),
          in: 0...Double(max(1, state.plyCount)), step: 1
        )
        .disabled(state.plyCount == 0)
        .accessibilityLabel("Move")
        .accessibilityValue(Text("\(state.ply) of \(state.plyCount)"))
        Button("Next move", systemImage: "chevron.right") {
          withAnimation(DesignTokens.Motion.drop) { state.stepForward() }
        }
        .keyboardShortcut(.rightArrow, modifiers: [])
        .disabled(!state.canStepForward)
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .controlSize(.large)

      Text(stepCaption)
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
        .contentTransition(.numericText())
    }
    .padding(.horizontal, DesignTokens.Spacing.l)
  }

  private var stepCaption: String {
    guard let column = state.lastColumn, let index = state.lastMoveIndex else {
      return String(localized: "Start of the game · use the left and right arrow keys")
    }
    let who =
      state.isHumanMove(at: index) ? String(localized: "You") : record.opponentName
    return String(
      localized: "Move \(state.ply) of \(state.plyCount) · \(who) played column \(column + 1)")
  }

  // MARK: Trace

  @ViewBuilder
  private var tracePane: some View {
    if let trace = state.trace {
      TurnDetailView(
        turn: GameViewModel.AITurn(trace: trace), style: trace.style, title: trace.provider,
        subtitle:
          "\(trace.style.displayName) · \(trace.difficulty.displayName) · move \(trace.ply + 1)",
        providerName: trace.modelID ?? trace.provider, isLive: false
      )
      .id(trace.id)
    } else {
      ContentUnavailableView {
        Label(
          state.lastMoveIndex == nil ? "Start of the game" : "Your move",
          systemImage: state.lastMoveIndex == nil ? "flag" : "hand.point.down")
      } description: {
        Text(
          state.lastMoveIndex == nil
            ? "Step forward to see each move. The model's thinking appears on its moves."
            : "The model's reply, with its thinking, is on the next step.")
      }
    }
  }
}

// MARK: Board

/// The board for replay: same plate and discs as the game, no input. The last move is
/// ringed and marked with a chevron above its column.
struct ReplayBoard: View {
  var state: ReplayState
  var humanDisc: Disc

  var body: some View {
    GeometryReader { geometry in
      let metrics = BoardMetrics.fitting(geometry.size)
      let board = state.board
      let winning = board.winningCells ?? []
      let discs = PlacedDisc.all(on: board)
      VStack(spacing: metrics.ghostGap) {
        marker(metrics)
        ZStack(alignment: .topLeading) {
          ForEach(discs) { placed in
            DiscView(
              side: placed.disc == humanDisc ? .human : .ai, diameter: metrics.discDiameter
            )
            .position(metrics.center(column: placed.cell.column, row: placed.cell.row))
            .opacity(!winning.isEmpty && !winning.contains(placed.cell) ? 0.4 : 1)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
          }
          BoardPlate(metrics: metrics)
          lastMoveRing(discs: discs, metrics: metrics)
          ForEach(Array(winning), id: \.self) { cell in
            let rect = metrics.holeRect(column: cell.column, row: cell.row).insetBy(dx: -2, dy: -2)
            Circle()
              .strokeBorder(.white.opacity(0.9), lineWidth: 2)
              .frame(width: rect.width, height: rect.height)
              .position(x: rect.midX, y: rect.midY)
          }
        }
        .frame(width: metrics.plateSize.width, height: metrics.plateSize.height)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      Text("Board after \(state.ply) moves"))
  }

  private func side(of column: Column?, plyIndex: Int?) -> DiscSide {
    guard let plyIndex else { return .human }
    let disc: Disc = plyIndex.isMultiple(of: 2) ? .first : .second
    return disc == humanDisc ? .human : .ai
  }

  @ViewBuilder
  private func marker(_ metrics: BoardMetrics) -> some View {
    ZStack(alignment: .leading) {
      Color.clear
      if let column = state.lastColumn {
        Image(systemName: "chevron.down")
          .font(.system(size: metrics.cell * 0.34, weight: .bold))
          .foregroundStyle(side(of: column, plyIndex: state.lastMoveIndex).fill)
          .frame(width: metrics.cell)
          .offset(x: metrics.center(column: column, row: 0).x - metrics.cell / 2)
          .animation(DesignTokens.Motion.ghost, value: column)
      }
    }
    .frame(width: metrics.plateSize.width, height: metrics.cell)
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private func lastMoveRing(discs: [PlacedDisc], metrics: BoardMetrics) -> some View {
    if let last = discs.last {
      let rect = metrics.holeRect(column: last.cell.column, row: last.cell.row).insetBy(
        dx: -2, dy: -2)
      Circle()
        .strokeBorder(.white.opacity(0.85), lineWidth: 2)
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
    }
  }
}

// MARK: Record summaries

extension GameRecord {
  /// "You won", "Qwen3 4B Instruct won", "Draw", or "Unfinished game".
  var resultTitle: String {
    switch outcome {
    case .win(let disc) where disc == humanDisc: String(localized: "You won")
    case .win: String(localized: "\(opponentName) won")
    case .draw: String(localized: "Draw")
    case nil: String(localized: "Unfinished game")
    }
  }

  /// "Explain · Moderate · 16 moves · Oct 4, 3:30 PM"
  var summaryLine: String {
    let date = startedAt.formatted(date: .abbreviated, time: .shortened)
    return "\(opponentName) · \(style.displayName) · \(difficulty.displayName) · "
      + String(localized: "\(moves.count) moves") + " · \(date)"
  }
}
