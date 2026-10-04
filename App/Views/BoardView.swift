import C4AI
import C4Core
import SwiftUI

/// Geometry shared by the plate, the discs, the ghost and hit testing.
struct BoardMetrics: Equatable {
  var cell: CGFloat

  /// Vertical plate padding; the horizontal padding is scaled so the plate is exactly 7:6.
  var padY: CGFloat { cell * DesignTokens.Spacing.platePaddingRatio }
  var padX: CGFloat { padY * 7 / 6 }
  var plateSize: CGSize {
    CGSize(
      width: CGFloat(Board.columnCount) * cell + 2 * padX,
      height: CGFloat(Board.rowCount) * cell + 2 * padY)
  }
  var holeDiameter: CGFloat { cell * (1 - DesignTokens.Spacing.holeInsetRatio) }
  var discDiameter: CGFloat { holeDiameter * DesignTokens.Spacing.discOverscan }
  /// Gap between the ghost row and the plate.
  var ghostGap: CGFloat { cell * 0.12 }
  var cornerRadius: CGFloat { min(DesignTokens.Radius.board, cell * 0.36) }

  /// Centre of a cell in plate coordinates. Row 0 is the bottom row.
  func center(column: Column, row: Int) -> CGPoint {
    CGPoint(
      x: padX + (CGFloat(column) + 0.5) * cell,
      y: padY + (CGFloat(Board.rowCount - 1 - row) + 0.5) * cell)
  }

  func holeRect(column: Column, row: Int) -> CGRect {
    let c = center(column: column, row: row)
    let d = holeDiameter
    return CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
  }

  /// The column under an x position in plate coordinates (clamped to the board).
  func column(atX x: CGFloat) -> Column {
    let raw = Int(((x - padX) / cell).rounded(.down))
    return min(max(raw, 0), Board.columnCount - 1)
  }

  /// Ghost row centre, relative to the plate's top edge.
  var ghostCenterY: CGFloat { -(ghostGap + cell / 2) }

  /// The largest board that fits `size`, leaving one cell of ghost row above the plate.
  static func fitting(_ size: CGSize) -> BoardMetrics {
    let p = DesignTokens.Spacing.platePaddingRatio
    let widthUnits = CGFloat(Board.columnCount) + 2 * p * 7 / 6
    let heightUnits = CGFloat(Board.rowCount) + 2 * p + 1.12
    return BoardMetrics(cell: max(8, min(size.width / widthUnits, size.height / heightUnits)))
  }
}

/// One disc on the board, with the ply that placed it.
struct PlacedDisc: Identifiable, Equatable {
  var ply: Int
  var cell: Cell
  var disc: Disc
  var id: Int { ply }

  static func all(on board: Board) -> [PlacedDisc] {
    var heights = [Int](repeating: 0, count: Board.columnCount)
    return board.moves.enumerated().map { ply, column in
      defer { heights[column] += 1 }
      return PlacedDisc(
        ply: ply, cell: Cell(column: column, row: heights[column]),
        disc: ply.isMultiple(of: 2) ? .first : .second)
    }
  }
}

/// The playing surface: ghost row, discs, the punched plate and the VoiceOver grid.
struct BoardView: View {
  @Bindable var game: GameViewModel

  @State private var hoverColumn: Column?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var ghostColumn: Column? {
    guard let hoverColumn, game.canDrop(hoverColumn) else { return nil }
    return hoverColumn
  }

  var body: some View {
    GeometryReader { geometry in
      let metrics = BoardMetrics.fitting(geometry.size)
      VStack(spacing: metrics.ghostGap) {
        GhostRow(column: ghostColumn, metrics: metrics)
        ZStack(alignment: .topLeading) {
          ConfidenceGlow(game: game, metrics: metrics)
          DiscLayer(game: game, metrics: metrics)
          BoardPlate(metrics: metrics)
          WinRings(game: game, metrics: metrics)
          BoardAccessibilityGrid(game: game, metrics: metrics)
        }
        .frame(width: metrics.plateSize.width, height: metrics.plateSize.height)
      }
      .contentShape(Rectangle())
      .onContinuousHover { phase in
        switch phase {
        case .active(let location):
          let column = metrics.column(atX: location.x)
          if column != hoverColumn {
            hoverColumn = column
            if game.canDrop(column) { Feedback.columnChanged() }
          }
        case .ended:
          hoverColumn = nil
        }
      }
      .onTapGesture { location in
        game.humanDrop(metrics.column(atX: location.x))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

// MARK: Ghost

/// The glass ghost disc above the hovered column (§6). Plain outline under Reduce Transparency.
private struct GhostRow: View {
  var column: Column?
  var metrics: BoardMetrics

  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let d = metrics.discDiameter
    GlassEffectContainer {
      ZStack(alignment: .leading) {
        Color.clear
        if let column {
          ghost(d)
            .offset(x: metrics.center(column: column, row: 0).x - d / 2)
        }
      }
    }
    .frame(width: metrics.plateSize.width, height: metrics.cell)
    .animation(reduceMotion ? .easeOut(duration: 0.12) : DesignTokens.Motion.ghost, value: column)
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }

  @ViewBuilder
  private func ghost(_ d: CGFloat) -> some View {
    if reduceTransparency {
      Circle()
        .strokeBorder(DesignTokens.Colors.human, lineWidth: 2)
        .background(Circle().fill(DesignTokens.Colors.human.opacity(0.35)))
        .frame(width: d, height: d)
        .transition(.opacity)
    } else {
      Color.clear
        .frame(width: d, height: d)
        .glassEffect(.clear.tint(DesignTokens.Colors.ghostTint), in: .circle)
        .glassEffectTransition(.materialize)
    }
  }
}

// MARK: Glow

/// While the model thinks, a soft cyan light in each column behind the plate, strongest for
/// the columns it currently favours (§4). It shows through the empty holes and spills above
/// the plate. Opacity follows the live distribution; it fades out when the AI disc drops.
/// Part of the board, so it stays on whether or not the Thinking panel is shown; hidden
/// under Increase Contrast, where the bars carry the information.
struct ConfidenceGlow: View {
  var game: GameViewModel
  var metrics: BoardMetrics

  @Environment(\.colorSchemeContrast) private var contrast

  /// Opacity of a column's light for probability `p`.
  static func opacity(for p: Double) -> Double {
    DesignTokens.Chart.glowPeak * pow(max(0, min(1, p)), DesignTokens.Chart.glowExponent)
  }

  var body: some View {
    let turn = game.aiTurn
    let active = turn?.isStreaming == true && !game.board.isGameOver && contrast != .increased
    let probabilities =
      turn?.distribution?.probabilities ?? Array(repeating: 0, count: Board.columnCount)
    let top = metrics.cell + metrics.ghostGap
    let height = top + metrics.plateSize.height
    ZStack(alignment: .topLeading) {
      ForEach(Board.allColumns, id: \.self) { column in
        let op = Self.opacity(for: probabilities[column])
        LinearGradient(
          stops: [
            .init(color: DesignTokens.Colors.ai.opacity(0), location: 0),
            .init(color: DesignTokens.Colors.ai.opacity(op * 0.85), location: top / height),
            .init(color: DesignTokens.Colors.ai.opacity(op), location: 1),
          ], startPoint: .top, endPoint: .bottom
        )
        .frame(width: metrics.cell * 0.94, height: height)
        .blur(radius: metrics.cell * 0.06)
        .offset(x: metrics.padX + (CGFloat(column) + 0.03) * metrics.cell, y: -top)
      }
    }
    .frame(width: metrics.plateSize.width, height: metrics.plateSize.height, alignment: .topLeading)
    .opacity(active ? 1 : 0)
    .animation(DesignTokens.Motion.glow, value: probabilities)
    .animation(.easeOut(duration: 0.35), value: active)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

// MARK: Discs

private struct DiscLayer: View {
  var game: GameViewModel
  var metrics: BoardMetrics

  var body: some View {
    let winning = game.winningCells
    let hasWinner = !winning.isEmpty
    ZStack(alignment: .topLeading) {
      ForEach(PlacedDisc.all(on: game.board)) { placed in
        let isWinning = winning.contains(placed.cell)
        let center = metrics.center(column: placed.cell.column, row: placed.cell.row)
        FallingDisc(
          side: placed.disc == game.humanDisc ? .human : .ai, diameter: metrics.discDiameter,
          dropDistance: center.y - metrics.ghostCenterY, animated: placed.ply == game.lastDropPly,
          isWinning: isWinning, sweepIndex: sweepIndex(placed.cell, in: winning)
        )
        .position(center)
        .opacity(hasWinner && !isWinning ? DesignTokens.Motion.dimmedDiscOpacity : 1)
        .animation(.easeInOut(duration: 0.5), value: hasWinner)
      }
    }
    .frame(width: metrics.plateSize.width, height: metrics.plateSize.height, alignment: .topLeading)
    .accessibilityHidden(true)
  }

  /// Position along the winning line, so the sweep travels across the four discs.
  private func sweepIndex(_ cell: Cell, in winning: Set<Cell>) -> Int {
    winning.sorted { ($0.column, $0.row) < ($1.column, $1.row) }.firstIndex(of: cell) ?? 0
  }
}

/// A disc that springs down from the ghost row when it first appears.
private struct FallingDisc: View {
  var side: DiscSide
  var diameter: CGFloat
  var dropDistance: CGFloat
  var animated: Bool
  var isWinning: Bool
  var sweepIndex: Int

  @State private var landed = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    DiscView(side: side, diameter: diameter)
      .modifier(WinSweep(isActive: isWinning, index: sweepIndex))
      .offset(y: animated && !landed ? -dropDistance : 0)
      .onAppear {
        guard animated else { return }
        withAnimation(reduceMotion ? DesignTokens.Motion.dropReduced : DesignTokens.Motion.drop) {
          landed = true
        }
        Task {
          try? await Task.sleep(for: DesignTokens.Motion.dropContact)
          Feedback.discLanded()
        }
      }
  }
}

/// The specular sweep across a winning disc: a Metal `.layerEffect`, static under Reduce Motion.
private struct WinSweep: ViewModifier {
  var isActive: Bool
  var index: Int

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    if isActive {
      TimelineView(.animation(paused: reduceMotion)) { context in
        let period = DesignTokens.Motion.winSweepPeriod
        let t = context.date.timeIntervalSinceReferenceDate / period - Double(index) * 0.08
        // Hold the band off-disc for part of each loop, so the sweeps read as passes.
        let phase = reduceMotion ? 0.45 : min(1, (t - t.rounded(.down)) * 1.6)
        content
          .layerEffect(
            ShaderLibrary.specularSweep(.boundingRect, .float(phase)), maxSampleOffset: .zero)
      }
    } else {
      content
    }
  }
}

/// Rings around the winning holes, drawn above the plate. A soft glow normally; a solid
/// ring under Increase Contrast.
private struct WinRings: View {
  var game: GameViewModel
  var metrics: BoardMetrics

  @Environment(\.colorSchemeContrast) private var contrast
  @State private var shown = false

  var body: some View {
    let cells = game.winningCells
    let color: Color =
      game.board.winner == game.humanDisc ? DesignTokens.Colors.human : DesignTokens.Colors.ai
    ZStack(alignment: .topLeading) {
      ForEach(Array(cells), id: \.self) { cell in
        let rect = metrics.holeRect(column: cell.column, row: cell.row).insetBy(dx: -2, dy: -2)
        Circle()
          .strokeBorder(contrast == .increased ? Color.white : color, lineWidth: 2.5)
          .shadow(
            color: contrast == .increased ? .clear : color.opacity(0.9), radius: metrics.cell * 0.12
          )
          .frame(width: rect.width, height: rect.height)
          .position(x: rect.midX, y: rect.midY)
      }
    }
    .frame(width: metrics.plateSize.width, height: metrics.plateSize.height, alignment: .topLeading)
    .opacity(cells.isEmpty ? 0 : 1)
    .animation(.easeInOut(duration: 0.6), value: cells)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

// MARK: Plate

/// The translucent plate (content, not glass). Holes are punched with `.destinationOut`,
/// each with an inner shadow and a lit lower lip; the gradient shows through.
struct BoardPlate: View {
  var metrics: BoardMetrics

  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    Canvas { context, size in
      let rect = CGRect(origin: .zero, size: size)
      let plate = Path(roundedRect: rect, cornerRadius: metrics.cornerRadius, style: .continuous)
      let d = metrics.holeDiameter

      context.fill(
        plate,
        with: .color(
          reduceTransparency ? DesignTokens.Colors.boardPlateOpaque : DesignTokens.Colors.boardPlate
        ))
      // A soft sheen from the top.
      context.fill(
        plate,
        with: .linearGradient(
          Gradient(colors: [.white.opacity(0.16), .white.opacity(0.02), .clear]), startPoint: .zero,
          endPoint: CGPoint(x: 0, y: size.height * 0.7)))

      var holes = Path()
      for column in Board.allColumns {
        for row in 0..<Board.rowCount {
          holes.addEllipse(in: metrics.holeRect(column: column, row: row))
        }
      }
      context.blendMode = .destinationOut
      context.fill(holes, with: .color(.black))
      context.blendMode = .normal

      for column in Board.allColumns {
        for row in 0..<Board.rowCount {
          let hole = metrics.holeRect(column: column, row: row)
          // Inner shadow: a blurred ring offset downward, clipped to the hole.
          context.drawLayer { layer in
            layer.clip(to: Path(ellipseIn: hole))
            layer.addFilter(.blur(radius: d * 0.07))
            layer.stroke(
              Path(
                ellipseIn: hole.offsetBy(dx: 0, dy: d * 0.07).insetBy(dx: -d * 0.06, dy: -d * 0.06)),
              with: .color(DesignTokens.Colors.holeShadow), lineWidth: d * 0.2)
          }
          // Lower lip catching the light.
          context.drawLayer { layer in
            layer.clip(
              to: Path(
                CGRect(x: hole.minX - 2, y: hole.midY, width: hole.width + 4, height: hole.height)))
            layer.stroke(
              Path(ellipseIn: hole.insetBy(dx: 0.75, dy: 0.75)),
              with: .linearGradient(
                Gradient(colors: [.clear, DesignTokens.Colors.boardRim]),
                startPoint: CGPoint(x: hole.midX, y: hole.midY),
                endPoint: CGPoint(x: hole.midX, y: hole.maxY)), lineWidth: 1.25)
          }
        }
      }

      // Plate edge: bright on top, fading down.
      context.stroke(
        Path(
          roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: metrics.cornerRadius,
          style: .continuous),
        with: .linearGradient(
          Gradient(colors: [.white.opacity(0.45), .white.opacity(0.08), .white.opacity(0.18)]),
          startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)), lineWidth: 1)
    }
    .compositingGroup()
    .shadow(color: .black.opacity(0.22), radius: metrics.cell * 0.3, y: metrics.cell * 0.12)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

// MARK: Accessibility

/// The board as a VoiceOver grid: one element per cell, top row first, with a drop action.
private struct BoardAccessibilityGrid: View {
  var game: GameViewModel
  var metrics: BoardMetrics

  var body: some View {
    let winning = game.winningCells
    ZStack(alignment: .topLeading) {
      ForEach((0..<Board.rowCount).reversed(), id: \.self) { row in
        ForEach(Board.allColumns, id: \.self) { column in
          let center = metrics.center(column: column, row: row)
          Color.clear
            .frame(width: metrics.cell, height: metrics.cell)
            .position(center)
            .accessibilityElement()
            .accessibilityLabel(label(column: column, row: row, winning: winning))
            .accessibilityAddTraits(game.canDrop(column) ? .isButton : [])
            .accessibilityAction(named: Text("Drop disc in column \(column + 1)")) {
              game.humanDrop(column)
            }
        }
      }
    }
    .frame(width: metrics.plateSize.width, height: metrics.plateSize.height, alignment: .topLeading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Board")
  }

  private func label(column: Column, row: Int, winning: Set<Cell>) -> String {
    let cell = Cell(column: column, row: row)
    let content: String
    switch game.board[cell] {
    case nil: content = String(localized: "empty")
    case game.humanDisc: content = String(localized: "your disc")
    default: content = String(localized: "model's disc")
    }
    let base = String(localized: "Column \(column + 1), row \(row + 1), \(content)")
    return winning.contains(cell) ? base + String(localized: ", winning line") : base
  }
}
