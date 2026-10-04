import SwiftUI

/// The vivid content under the glass: a 3×3 `MeshGradient` whose inner points drift slowly
/// (§6). Pauses while the AI streams and while the window is inactive, without jumping when
/// it resumes. Static under Reduce Motion.
struct MeshBackground: View {
  /// Extra pause condition from the caller (the AI is streaming).
  var isPaused: Bool

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.appearsActive) private var appearsActive
  @State private var clock = DriftClock()

  private var paused: Bool { isPaused || reduceMotion || !appearsActive }

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / DesignTokens.Motion.meshFrameRate, paused: paused))
    { context in
      let time = reduceMotion ? 0 : clock.elapsed(at: context.date)
      MeshGradient(
        width: 3, height: 3, points: Self.points(at: time),
        colors: colorScheme == .dark ? DesignTokens.Colors.meshDark : DesignTokens.Colors.meshLight,
        smoothsColors: true)
    }
    .onChange(of: paused, initial: true) { _, paused in
      clock.setPaused(paused, at: .now)
    }
    .accessibilityHidden(true)
  }

  /// Corners stay put; edge midpoints slide along their edge and the centre wanders.
  /// Every term repeats within `meshPeriod` or a multiple of it, so the drift is seamless.
  static func points(at time: TimeInterval) -> [SIMD2<Float>] {
    let phase = Float(time / DesignTokens.Motion.meshPeriod * 2 * .pi)
    func wave(_ amplitude: Float, _ harmonic: Float, _ offset: Float) -> Float {
      amplitude * sin(phase * harmonic + offset)
    }
    return [
      [0, 0], [0.5 + wave(0.18, 1, 0.0), 0], [1, 0],
      [0, 0.5 + wave(0.16, 1, 1.7)],
      [0.5 + wave(0.14, 1, 2.4) + wave(0.04, 2, 0.3), 0.5 + wave(0.12, 1, 4.1)],
      [1, 0.5 + wave(0.16, 1, 3.3)],
      [0, 1], [0.5 + wave(0.18, 1, 5.2), 1], [1, 1],
    ]
  }
}

/// Elapsed drift time that stops while paused, so resuming continues from the same frame.
@MainActor
private final class DriftClock {
  private var accumulated: TimeInterval = 0
  private var resumedAt: Date? = .now

  func elapsed(at date: Date) -> TimeInterval {
    accumulated + (resumedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0)
  }

  func setPaused(_ paused: Bool, at date: Date) {
    if paused, resumedAt != nil {
      accumulated = elapsed(at: date)
      resumedAt = nil
    } else if !paused, resumedAt == nil {
      resumedAt = date
    }
  }
}
