import C4Core

/// Minimax at a fixed depth. Bench anchor, Engine opponent, and the error fallback (d2).
public struct EngineMoveProvider: MoveProvider {
    public let engine: Engine
    public var name: String { "Minimax d\(engine.depth)" }

    public init(depth: Int) { engine = Engine(depth: depth) }

    public func move(_ context: TurnContext) -> AsyncStream<TurnEvent> {
        let engine = engine
        return AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let start = ContinuousClock.now
                let column = engine.bestMove(context.board)
                let elapsed = ContinuousClock.now - start
                var probabilities = [Double](repeating: 0, count: Board.columnCount)
                probabilities[column] = 1
                let masked = Set(Board.allColumns).subtracting(context.board.legalMoves)
                let distribution = ColumnDistribution(probabilities: probabilities, masked: masked)
                guard !Task.isCancelled else { return continuation.finish() }
                continuation.yield(.distribution(distribution))
                let timings = MoveTimings(totalMs: elapsed.milliseconds)
                continuation.yield(.decided(AIMove(column: column, distribution: distribution, timings: timings)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Uniformly random legal moves, seeded per move. The weakest bench anchor.
public struct RandomMoveProvider: MoveProvider {
    public var name: String { "Random" }

    public init() {}

    public func move(_ context: TurnContext) -> AsyncStream<TurnEvent> {
        AsyncStream { continuation in
            let legal = context.board.legalMoves
            guard !legal.isEmpty else {
                continuation.yield(.failed(MoveError("no legal moves")))
                return continuation.finish()
            }
            var rng = SplitMix64(seed: context.seed)
            let column = legal[Int(rng.next() % UInt64(legal.count))]
            var probabilities = [Double](repeating: 0, count: Board.columnCount)
            for c in legal { probabilities[c] = 1 / Double(legal.count) }
            let distribution = ColumnDistribution(
                probabilities: probabilities, masked: Set(Board.allColumns).subtracting(legal))
            continuation.yield(.distribution(distribution))
            continuation.yield(.decided(AIMove(column: column, distribution: distribution)))
            continuation.finish()
        }
    }
}

/// Wraps a provider so that errors (never bad output) become a depth-2 engine move with
/// `source: .fallback` (§3.3.7). All other events pass through unchanged.
public struct FallbackMoveProvider<Primary: MoveProvider>: MoveProvider {
    public let primary: Primary
    public let fallback: EngineMoveProvider

    public init(_ primary: Primary, fallbackDepth: Int = 2) {
        self.primary = primary
        self.fallback = EngineMoveProvider(depth: fallbackDepth)
    }

    public var name: String { primary.name }

    public func move(_ context: TurnContext) -> AsyncStream<TurnEvent> {
        let primary = primary
        let fallback = fallback
        return AsyncStream { continuation in
            let task = Task {
                for await event in primary.move(context) {
                    guard case .failed = event else {
                        continuation.yield(event)
                        continue
                    }
                    if Task.isCancelled { break }
                    for await fallbackEvent in fallback.move(context) {
                        if case .decided(var move) = fallbackEvent {
                            move.source = .fallback
                            continuation.yield(.decided(move))
                        } else {
                            continuation.yield(fallbackEvent)
                        }
                    }
                    break
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
