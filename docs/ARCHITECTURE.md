# Architecture

How the code is laid out and why. The design rationale is in [DESIGN.md](DESIGN.md);
measured MLX behaviour is in [MLX-FINDINGS.md](MLX-FINDINGS.md).

## Packages

| Package | Depends on | Test with | Contents |
|---|---|---|---|
| `Packages/C4Core` | nothing | `swift test` | `Board` (bitboard), `Engine` (alpha-beta + transposition table), `Tactics`, `PuzzleGenerator`, seeded RNG |
| `Packages/C4AI` | C4Core | `swift test` | the `MoveProvider` protocol and turn events, `BoardEncoder`, `PromptBuilder`, `DifficultyProfile`, `ModelRegistry`, `SelfCheck`, mock / engine / random / fallback providers, `MoveTrace`, `GameRecord` |
| `Packages/C4MLX` | C4AI, mlx-swift-lm | `Scripts/xc.sh` | `LLMMoveProvider`, `ColumnConstraint`. The only code that imports MLX; every MLX call is in `MLXSession.swift`. |
| `Packages/C4Bench` | C4AI | `swift test` | contestants, openings, the runner, resumable storage, Bradley-Terry rating, leaderboard, md/csv/json reports |
| `Tools/c4bench` | all | `Scripts/xc.sh` | the benchmark CLI (module name `C4BenchCLI`, distinct from `C4Bench` on a case-insensitive disk) |
| `Tools/mlx-smoke` | C4MLX | `Scripts/xc.sh` | loads one model and plays fixed boards; prints digit tokens, distributions and timings |
| `App/` | all | `Scripts/xc.sh` | the SwiftUI app |

Everything except MLX builds and tests with plain `swift test`. Targets that link MLX must
build with `xcodebuild`, because SwiftPM alone does not compile MLX's Metal shader library.

## A turn

```
Board ─► BoardEncoder ─► PromptBuilder ─► LLMMoveProvider
                                            ├─ cached static-prefix KV
                                            ├─ stream thoughts / reasoning (budgeted)
                                            ├─ append "Column: ", one forward step
                                            └─ logits of the 7 digit tokens, masked to legal
                                         ─► ColumnDistribution ─► sample or argmax ─► AIMove
```

A turn is an `AsyncStream<TurnEvent>`: `.prompt`, `.thinkingToken`, `.reasoningToken`,
`.distribution`, then `.decided` or `.failed`. The app's Thinking panel and the benchmark
consume the same stream. `FallbackMoveProvider` turns `.failed` (errors only, never bad
output) into a depth-2 engine move marked `fallback`. On Hard, `SelfCheck` re-prompts once
after a missed immediate win or block.

## Resources

SwiftPM can't reference files outside a package, so resources live with the code that
loads them:

- `Packages/C4AI/Sources/C4AI/Resources/models.json`: the model list
- `Packages/C4AI/Sources/C4AI/Resources/prompts/v<N>/`: versioned prompt templates
- `Packages/C4Bench/Sources/C4Bench/Resources/puzzles.json`: 152 engine-verified puzzles
- `Resources/`: app assets, the string catalog, and JSON schemas in `Resources/schemas/`

## Data on disk

- App games: `~/Library/Containers/com.komi.LLMConnectFour/Data/Library/Application Support/LLMConnectFour/games/` (the app is sandboxed; the last 200 games are kept)
- Benchmark results from the CLI: `~/Library/Application Support/LLMConnectFour/bench/`, one JSONL file per game. The leaderboard is always recomputed from these files. The app's Leaderboard window can open this folder with "Open bench folder…".
- Models: the app's container cache; the CLI uses `~/.cache/huggingface/hub`.

## Toolchain notes

- Swift 6 language mode with strict concurrency, macOS 26 minimum, arm64 only.
- `mlx-swift-lm` is pinned with `.upToNextMinor(from: "3.32.3")` and its
  `FoundationModelsIntegration` trait is turned off. Its `#hubDownloader()` and
  `#huggingFaceTokenizerLoader()` macros need `swift-huggingface` and `swift-transformers`
  declared by the consumer.
- `Scripts/xc.sh build|test` runs XcodeGen and passes `-skipMacroValidation`. In the Xcode
  GUI, trust the `MLXHuggingFaceMacros` macro once when prompted.
- Signing is ad hoc, so no Apple Developer account is needed to build or run.
- Formatting: `swift format` with its default configuration.
