import AppKit

/// Sounds and haptics (§6, §12): built-in `NSSound` names, so there are no audio assets.
@MainActor
enum Feedback {
  /// A disc reached its resting position.
  static func discLanded() {
    play(DesignTokens.Sounds.drop, volume: 0.55)
    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
  }

  /// The ghost disc moved to another column.
  static func columnChanged() {
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
  }

  /// Four in a row.
  static func gameWon() {
    play(DesignTokens.Sounds.win, volume: 0.45)
  }

  private static func play(_ name: String, volume: Float) {
    // A copy per play, so quick successive drops overlap instead of cutting off.
    guard let sound = NSSound(named: name)?.copy() as? NSSound else { return }
    sound.volume = volume
    sound.play()
  }
}
