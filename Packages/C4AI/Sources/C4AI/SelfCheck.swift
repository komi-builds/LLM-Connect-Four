import C4Core
import Foundation

/// The Hard-mode self-check (§3.5), shared by the app's game loop and the bench.
public enum SelfCheck {
  public struct Outcome: Sendable {
    /// The move that stands. After a self-check it is the second answer with source
    /// `.modelAfterSelfCheck` (unless the second answer fell back to the engine).
    public var move: AIMove
    /// The prompt behind `move` (the re-prompt, if a self-check happened).
    public var prompt: Prompt?
    /// True if the first answer was a blunder and the model was asked again.
    public var selfChecked: Bool
    /// The first answer, when `selfChecked`.
    public var firstMove: AIMove?
    /// What the first answer got wrong, when `selfChecked`.
    public var blunder: Blunder?
  }

  /// The facts for the re-prompt, in the same wording as the normal prompt facts.
  public static func facts(for blunder: Blunder, board: Board, played: Column) -> [String] {
    var facts = PromptFacts.compute(board: board, level: .winsAndBlocks)
    let label = BoardEncoder.label(played)
    switch blunder {
    case .missedWin:
      facts.insert("Your first answer, column \(label), missed an immediate win.", at: 0)
    case .missedBlock:
      facts.insert("Your first answer, column \(label), did not stop an immediate threat.", at: 0)
    }
    return facts
  }

  /// Plays one turn through `provider`. If the decided move is a `missedWin` or
  /// `missedBlock` and `context.profile.selfCheck` is on, asks once more with the fact in
  /// `extraFacts` and keeps the second answer. Returns nil if the turn was cancelled or the
  /// provider failed without a fallback (wrap providers in `FallbackMoveProvider`).
  /// `onEvent` sees the events of both attempts.
  public static func run(
    provider: any MoveProvider, context: TurnContext,
    onEvent: (@Sendable (TurnEvent) -> Void)? = nil
  ) async -> Outcome? {
    guard let first = await drain(provider, context, onEvent) else { return nil }
    guard let (second, blunder) = recheck(after: first.move, context: context) else {
      return Outcome(move: first.move, prompt: first.prompt, selfChecked: false)
    }
    guard let again = await drain(provider, second, onEvent) else { return nil }
    var move = again.move
    if move.source == .model { move.source = .modelAfterSelfCheck }
    // Time spent includes the first attempt.
    move.timings.totalMs += first.move.timings.totalMs
    move.timings.generatedTokens += first.move.timings.generatedTokens
    return Outcome(
      move: move, prompt: again.prompt ?? first.prompt, selfChecked: true, firstMove: first.move,
      blunder: blunder)
  }

  /// The re-prompt context if `move` should be self-checked: the profile asks for it, the
  /// move is the model's own first answer, and it missed an immediate win or block. Facts
  /// the prompt already states are not repeated.
  public static func recheck(after move: AIMove, context: TurnContext) -> (TurnContext, Blunder)? {
    guard context.profile.selfCheck, move.source == .model,
      let blunder = Tactics.blunder(on: context.board, played: move.column)
    else { return nil }
    let stated = Set(PromptFacts.compute(board: context.board, level: context.profile.facts))
    let added = facts(for: blunder, board: context.board, played: move.column)
      .filter { !stated.contains($0) }
    var second = context
    second.extraFacts = context.extraFacts + added
    return (second, blunder)
  }

  private static func drain(
    _ provider: any MoveProvider, _ context: TurnContext,
    _ onEvent: (@Sendable (TurnEvent) -> Void)?
  ) async -> (move: AIMove, prompt: Prompt?)? {
    var prompt: Prompt?
    for await event in provider.move(context) {
      onEvent?(event)
      switch event {
      case .prompt(let p): prompt = p
      case .decided(let move): return (move, prompt)
      case .failed: return nil
      default: break
      }
    }
    return nil
  }
}
