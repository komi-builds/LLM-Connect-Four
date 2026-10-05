import Accessibility
import C4AI
import C4Core
import Charts
import SwiftUI

/// Seven solid bars, one per column in board order (§4). Height is the model's probability.
/// Masked columns (full, or hidden by difficulty) get a faint track and diagonal hatching.
/// The chosen column is emphasised once the move is decided; the rest recede.
struct ConfidenceBars: View {
  var distribution: ColumnDistribution?
  var chosen: Column?
  var isLive: Bool

  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var probabilities: [Double] {
    distribution?.probabilities ?? Array(repeating: 0, count: Board.columnCount)
  }
  private func isMasked(_ column: Column) -> Bool { distribution?.masked.contains(column) ?? false }
  private static let barWidthRatio = 0.72

  var body: some View {
    let probabilities = probabilities
    VStack(spacing: 4) {
      // Labels sit in seven equal cells above and below the chart, whose plot area spans
      // the full width, so they line up with the bars (and with the board's columns).
      columnRow { column in
        Text(label(column: column, masked: isMasked(column)))
          .font(.caption2.weight(column == chosen ? .bold : .regular).monospacedDigit())
          .foregroundStyle(column == chosen ? DesignTokens.Colors.aiText : Color.secondary)
      }
      Chart {
        ForEach(Board.allColumns, id: \.self) { column in
          let masked = isMasked(column)
          // The track, always full height.
          BarMark(
            x: .value("Column", String(column + 1)), y: .value("Track", 1.0),
            width: .ratio(Self.barWidthRatio), stacking: .unstacked
          )
          .foregroundStyle(Color.secondary.opacity(masked ? 0.08 : 0.14))
          .clipShape(.rect(cornerRadius: 5))
          if !masked {
            BarMark(
              x: .value("Column", String(column + 1)),
              y: .value("Probability", probabilities[column]),
              width: .ratio(Self.barWidthRatio), stacking: .unstacked
            )
            .foregroundStyle(fill(for: column))
            .clipShape(.rect(cornerRadius: 5))
          }
        }
      }
      .chartYScale(domain: 0...1)
      .chartYAxis(.hidden)
      .chartXAxis(.hidden)
      .chartOverlay { proxy in
        HatchOverlay(proxy: proxy, masked: distribution?.masked ?? [], ratio: Self.barWidthRatio)
      }
      .frame(height: DesignTokens.Chart.height)
      columnRow { column in
        Text("\(column + 1)")
          .font(.caption.weight(column == chosen ? .bold : .regular).monospacedDigit())
          .foregroundStyle(column == chosen ? Color.primary : Color.secondary)
      }
    }
    .animation(isLive && !reduceMotion ? .smooth(duration: 0.3) : nil, value: probabilities)
    .animation(.smooth(duration: 0.35), value: chosen)
    .accessibilityChartDescriptor(
      ConfidenceChartDescriptor(
        probabilities: probabilities, masked: distribution?.masked ?? [], chosen: chosen))
  }

  private func columnRow<Content: View>(@ViewBuilder _ content: @escaping (Column) -> Content)
    -> some View
  {
    HStack(spacing: 0) {
      ForEach(Board.allColumns, id: \.self) { column in
        content(column).frame(maxWidth: .infinity)
      }
    }
    .accessibilityHidden(true)
  }

  private func label(column: Column, masked: Bool) -> String {
    if masked { return "·" }
    guard distribution != nil else { return "-" }
    return "\(Int((probabilities[column] * 100).rounded()))"
  }

  private func fill(for column: Column) -> Color {
    let base = contrast == .increased ? DesignTokens.Colors.aiText : DesignTokens.Colors.ai
    guard let chosen else { return base.opacity(0.85) }
    return column == chosen ? base : base.opacity(0.32)
  }
}

/// Diagonal hatching over the tracks of masked columns, positioned from the chart's scale.
private struct HatchOverlay: View {
  var proxy: ChartProxy
  var masked: Set<Column>
  var ratio: Double

  var body: some View {
    GeometryReader { geometry in
      if !masked.isEmpty, let plotAnchor = proxy.plotFrame {
        let plot = geometry[plotAnchor]
        let step = plot.width / CGFloat(Board.columnCount)
        let barWidth = step * ratio
        Canvas { context, _ in
          for column in masked {
            let center = plot.minX + step * (CGFloat(column) + 0.5)
            let rect = CGRect(
              x: center - barWidth / 2, y: plot.minY, width: barWidth, height: plot.height)
            let clip = Path(roundedRect: rect, cornerRadius: 5)
            var stripes = Path()
            var x = rect.minX - rect.height
            while x < rect.maxX {
              stripes.move(to: CGPoint(x: x, y: rect.maxY))
              stripes.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
              x += 6
            }
            context.drawLayer { layer in
              layer.clip(to: clip)
              layer.stroke(stripes, with: .color(.secondary.opacity(0.5)), lineWidth: 1)
            }
            context.stroke(clip, with: .color(.secondary.opacity(0.25)), lineWidth: 0.75)
          }
        }
        .allowsHitTesting(false)
      }
    }
    .accessibilityHidden(true)
  }
}

/// VoiceOver's audio graph and table for the bars.
struct ConfidenceChartDescriptor: AXChartDescriptorRepresentable {
  var probabilities: [Double]
  var masked: Set<Column>
  var chosen: Column?

  func makeChartDescriptor() -> AXChartDescriptor {
    let categories = Board.allColumns.map { String($0 + 1) }
    let x = AXCategoricalDataAxisDescriptor(
      title: String(localized: "Column"), categoryOrder: categories)
    let y = AXNumericDataAxisDescriptor(
      title: String(localized: "Probability"), range: 0...1, gridlinePositions: [0.25, 0.5, 0.75]
    ) { value in
      String(localized: "\(Int((value * 100).rounded())) percent")
    }
    let points = Board.allColumns.map { column in
      AXDataPoint(
        x: categories[column], y: probabilities[column],
        label: masked.contains(column)
          ? String(localized: "Column \(column + 1), not offered")
          : String(
            localized:
              "Column \(column + 1), \(Int((probabilities[column] * 100).rounded())) percent"
          ))
    }
    let series = AXDataSeriesDescriptor(
      name: String(localized: "Confidence per column"), isContinuous: false, dataPoints: points)
    let summary =
      chosen.map { String(localized: "The model chose column \($0 + 1).") }
      ?? String(localized: "The model's current lean for each column.")
    return AXChartDescriptor(
      title: String(localized: "Confidence per column"), summary: summary, xAxis: x, yAxis: y,
      additionalAxes: [], series: [series])
  }

  func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
    descriptor.series = makeChartDescriptor().series
  }
}
