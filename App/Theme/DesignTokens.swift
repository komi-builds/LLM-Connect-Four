import SwiftUI

/// The one shared look: colours, radii, spacing and animation curves (§6, §12).
/// UI code reads these instead of hard-coding values.
enum DesignTokens {
  enum Colors {
    /// Human disc fill.
    static let human = Color(hex: 0xFF6B5B)
    /// AI disc fill (AI discs also get an inner ring).
    static let ai = Color(hex: 0x3FD0E0)
    /// Text versions that keep contrast in light mode.
    static let humanText = Color(light: Color(hex: 0xD9473A), dark: Color(hex: 0xFF6B5B))
    static let aiText = Color(light: Color(hex: 0x1F8FA0), dark: Color(hex: 0x3FD0E0))

    /// Board plate tint (translucent; the gradient shows through).
    static let boardPlate = Color(
      light: Color(hex: 0x2B3A67, opacity: 0.78), dark: Color(hex: 0x141C33, opacity: 0.82))
    /// Opaque plate for Reduce Transparency.
    static let boardPlateOpaque = Color(light: Color(hex: 0x2B3A67), dark: Color(hex: 0x141C33))
    /// Light catching the top edge of the plate and the lower lip of each hole.
    static let boardRim = Color.white.opacity(0.22)
    /// Inner shadow inside each hole.
    static let holeShadow = Color.black.opacity(0.55)

    /// Darker shades for the disc body gradient (edge of the disc).
    static let humanShade = Color(hex: 0xC8392C)
    static let aiShade = Color(hex: 0x1A8EA3)
    /// The AI disc's inner ring, so the sides never rely on colour alone.
    static let aiRing = Color(hex: 0x0E5E6E)
    /// Specular highlight added with `.plusLighter`.
    static let specular = Color.white.opacity(0.5)
    /// Ghost disc glass tint.
    static let ghostTint = human.opacity(0.3)

    /// Mesh-gradient palettes, 3×3 points, row-major.
    static let meshLight: [Color] = [
      Color(hex: 0xFFD6C9), Color(hex: 0xFFE9B8), Color(hex: 0xC9F1F5),
      Color(hex: 0xF7B2C4), Color(hex: 0xE7D4FF), Color(hex: 0xA9E4EE),
      Color(hex: 0xFFC2A8), Color(hex: 0xB9C8FF), Color(hex: 0x9EDCE8),
    ]
    static let meshDark: [Color] = [
      Color(hex: 0x2A1235), Color(hex: 0x14204A), Color(hex: 0x0B2D3A),
      Color(hex: 0x4A1A2E), Color(hex: 0x1C1640), Color(hex: 0x0E3442),
      Color(hex: 0x3A1424), Color(hex: 0x16255A), Color(hex: 0x0A3A40),
    ]
  }

  enum Radius {
    static let board: CGFloat = 28
    static let card: CGFloat = 22
    static let small: CGFloat = 10
  }

  enum Spacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 40
    /// Gap between holes, as a fraction of the cell size.
    static let holeInsetRatio: CGFloat = 0.12
    /// Plate padding around the outer holes, as a fraction of the cell size.
    static let platePaddingRatio: CGFloat = 0.22
    /// Disc diameter relative to the hole, so the rim covers the disc edge.
    static let discOverscan: CGFloat = 1.04
  }

  enum Motion {
    /// Disc drop.
    static let drop = Animation.spring(duration: 0.35, bounce: 0.25)
    /// Drop under Reduce Motion: no bounce.
    static let dropReduced = Animation.easeOut(duration: 0.2)
    /// Ghost disc following the pointer.
    static let ghost = Animation.spring(duration: 0.25, bounce: 0.15)
    /// Board glow following the distribution.
    static let glow = Animation.easeInOut(duration: 0.3)
    /// Background drift period.
    static let meshPeriod: TimeInterval = 30
    static let meshFrameRate: Double = 30
    /// Time from the start of the drop spring to first contact with the resting
    /// position, when the landing sound and haptic fire.
    static let dropContact: Duration = .milliseconds(170)
    /// One pass of the specular sweep across the winning discs.
    static let winSweepPeriod: TimeInterval = 2.4
    /// Opacity of discs that are not part of the winning line.
    static let dimmedDiscOpacity: Double = 0.4
    /// Result card entrance.
    static let card = Animation.spring(duration: 0.45, bounce: 0.2)
  }

  enum Window {
    static let minWidth: CGFloat = 960
    static let minHeight: CGFloat = 640
    static let inspectorMin: CGFloat = 280
    static let inspectorIdeal: CGFloat = 320
    static let inspectorMax: CGFloat = 420
  }

  enum Sounds {
    static let drop = "Pop"
    static let win = "Glass"
    static let tick = "Tink"
  }
}

extension Color {
  init(hex: UInt32, opacity: Double = 1) {
    self.init(
      .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255, opacity: opacity)
  }

  /// A colour that resolves differently in light and dark appearance.
  init(light: Color, dark: Color) {
    self.init(
      nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
      })
  }
}
