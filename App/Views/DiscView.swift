import SwiftUI

/// Which side a disc belongs to, from the UI's point of view.
enum DiscSide: Sendable {
  case human, ai

  var fill: Color { self == .human ? DesignTokens.Colors.human : DesignTokens.Colors.ai }
  var shade: Color { self == .human ? DesignTokens.Colors.humanShade : DesignTokens.Colors.aiShade }
}

/// A solid disc with a radial specular highlight (`.plusLighter`). AI discs carry an inner
/// ring, so the two sides never rely on colour alone (§6).
struct DiscView: View {
  var side: DiscSide
  var diameter: CGFloat

  @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let d = diameter
    ZStack {
      // Body: a flat disc, shading only toward the rim.
      Circle()
        .fill(
          RadialGradient(
            colors: [side.fill, side.fill, side.shade],
            center: UnitPoint(x: 0.46, y: 0.42), startRadius: 0, endRadius: d * 0.62))
      // A shallow groove, like a moulded playing piece.
      Circle()
        .strokeBorder(side.shade.opacity(0.35), lineWidth: max(0.5, d * 0.02))
        .padding(d * 0.1)

      // Bevel: a bright upper edge and a darker lower edge.
      Circle()
        .strokeBorder(
          LinearGradient(
            colors: [.white.opacity(0.45), .white.opacity(0.05), .black.opacity(0.25)],
            startPoint: .top, endPoint: .bottom),
          lineWidth: max(1, d * 0.035))

      if side == .ai {
        aiRing(d)
      } else if differentiateWithoutColor {
        // A second, distinct mark for the human side as well.
        Circle()
          .fill(.white.opacity(0.85))
          .frame(width: d * 0.16, height: d * 0.16)
      }

      // Specular highlight.
      Ellipse()
        .fill(
          RadialGradient(
            colors: [DesignTokens.Colors.specular, .white.opacity(0)], center: .center,
            startRadius: 0,
            endRadius: d * 0.3)
        )
        .frame(width: d * 0.6, height: d * 0.3)
        .offset(x: -d * 0.08, y: -d * 0.25)
        .blendMode(.plusLighter)
        .opacity(contrast == .increased ? 0.5 : 1)
    }
    .frame(width: d, height: d)
    .compositingGroup()
  }

  @ViewBuilder
  private func aiRing(_ d: CGFloat) -> some View {
    let strong = differentiateWithoutColor || contrast == .increased
    ZStack {
      Circle()
        .strokeBorder(
          DesignTokens.Colors.aiRing.opacity(strong ? 1 : 0.75),
          lineWidth: d * (strong ? 0.075 : 0.055))
      Circle()
        .strokeBorder(.white.opacity(0.35), lineWidth: max(0.5, d * 0.012))
        .padding(d * 0.055)
    }
    .frame(width: d * 0.6, height: d * 0.6)
  }
}

#Preview {
  HStack(spacing: 24) {
    DiscView(side: .human, diameter: 96)
    DiscView(side: .ai, diameter: 96)
  }
  .padding(40)
  .background(.indigo)
}
