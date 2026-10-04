import C4AI
import C4Core
import SwiftUI

/// Seven bars, one per column, lined up 1...7. Masked columns are hatched. A plain
/// placeholder for agent F's Swift Charts version.
struct ConfidenceBars: View {
  var distribution: ColumnDistribution?
  var chosen: Column?
  var isLive: Bool

  var body: some View {
    let probabilities = distribution?.probabilities ?? Array(repeating: 0, count: Board.columnCount)
    let top = max(probabilities.max() ?? 0, 0.01)
    HStack(alignment: .bottom, spacing: 6) {
      ForEach(Board.allColumns, id: \.self) { column in
        let p = probabilities[column]
        let masked = distribution?.masked.contains(column) ?? false
        VStack(spacing: 4) {
          Text(masked ? "·" : "\(Int((p * 100).rounded()))")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(column == chosen ? DesignTokens.Colors.aiText : Color.secondary)
          ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 3).fill(.quaternary.opacity(0.5))
            if masked {
              HatchedBar()
            } else {
              RoundedRectangle(cornerRadius: 3)
                .fill(column == chosen ? DesignTokens.Colors.aiText : Color.secondary.opacity(0.55))
                .frame(height: max(2, 72 * p / top))
            }
          }
          .frame(height: 72)
          Text("\(column + 1)")
            .font(.caption.weight(column == chosen ? .bold : .regular).monospacedDigit())
            .foregroundStyle(column == chosen ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          masked
            ? Text("Column \(column + 1), not offered")
            : Text("Column \(column + 1), \(Int((p * 100).rounded())) percent"))
      }
    }
    .animation(isLive ? .easeInOut(duration: 0.3) : nil, value: probabilities)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Confidence per column")
  }
}

/// Diagonal hatching for a masked column.
private struct HatchedBar: View {
  var body: some View {
    Canvas { context, size in
      var path = Path()
      var x: CGFloat = -size.height
      while x < size.width {
        path.move(to: CGPoint(x: x, y: size.height))
        path.addLine(to: CGPoint(x: x + size.height, y: 0))
        x += 5
      }
      context.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3))
      context.stroke(path, with: .color(.secondary.opacity(0.45)), lineWidth: 1)
    }
  }
}
