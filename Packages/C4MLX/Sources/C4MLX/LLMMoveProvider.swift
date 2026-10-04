import C4AI
import C4Core
import Foundation
import MLXHuggingFace
import MLXLLM
import MLXLMCommon

/// The LLM opponent, running in-process with MLX (§3). One generation at a time.
///
/// Turn pipeline: build prompt → reuse the cached static-prefix KV → stream reasoning /
/// thoughts within the budget → append `"Column: "` → one forward step with every logit
/// except the allowed digits set to −∞ → softmax → sample or argmax → `.decided`.
/// Errors are reported as `.failed`; wrap in `FallbackMoveProvider` for the engine fallback.
public actor LLMMoveProvider: LoadableMoveProvider {
    public let spec: ModelSpec
    public nonisolated var name: String { spec.name }

    public init(spec: ModelSpec) {
        self.spec = spec
    }

    public var isReady: Bool { fatalError("TODO: agent D") }

    /// Downloads (if needed), loads, discovers digit tokens, prefills and caches the static
    /// system prefix, and runs one throwaway step to compile the Metal kernels.
    public func load(progress: @escaping @Sendable (LoadProgress) -> Void) async throws {
        fatalError("TODO: agent D")
    }

    public func unload() async {
        fatalError("TODO: agent D")
    }

    public nonisolated func move(_ context: TurnContext) -> AsyncStream<TurnEvent> {
        fatalError("TODO: agent D")
    }
}
