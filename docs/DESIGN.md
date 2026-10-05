# LLM Connect Four: design

The design document the app was built from. Section numbers match the `§` references in
code comments. Where the shipped code refines a decision (package layout, the model list,
prompt version), `docs/ARCHITECTURE.md` and the code are the source of truth.

## Decisions (locked)

| Area | Choice | Why |
|---|---|---|
| App shell | **SwiftUI, native macOS 26+** | Real Apple Liquid Glass (`.glassEffect`), not a WebGL imitation. The JS libs (liquid-glass-js, liquidGL) are not used, but their look is the reference. |
| LLM runtime | **MLX, in-process via `mlx-swift-lm`** | Fastest path on Apple Silicon. No Python, no server, nothing extra to install: the app downloads the model from Hugging Face on first run. |
| AI design | **The LLM really decides** | The model reads the board, optionally reasons, and its answer becomes the move. Constrained decoding guarantees the answer is a legal column, so nothing is hardcoded and no output needs parsing. |
| Thinking styles | **Instinct / Explain / Deep think** | Three speeds of reasoning, all visible in the Thinking panel. See [§3.2](#32-how-it-answers-thinking-styles). |
| Difficulty | **Easy / Moderate / Hard** | Controls prompt help, sampling and safety checks. The model always decides. See [§3.6](#36-difficulty-easy--moderate--hard). |
| Benchmarking | **Built in: CLI plus in-app leaderboard** | Any model or configuration can be ranked on the same scale. See [§5](#5-benchmarking-and-leaderboard). |
| Platform | **Mac first, Mac only for now** | See [§9](#9-scope-mac-first). |
| Target machine | M3 Pro, 18 GB unified memory | The default model must leave plenty of headroom. |

## 1. Gameplay flow

```
App launch ──► board shown, human's turn immediately
          └──► background Task: load model (download if needed) → cache system-prompt KV → warm-up
Human drops disc (1-7 keys or click)
  └─► model ready?  yes ─► AI turn
                    no  ─► glass "Warming up… 63%" pill until ready, then AI turn
AI turn: encode board ─► prompt (static prefix reused from cache) ─► think/reason (streamed)
         ─► forced "Column:" + legal-digit mask ─► column ─► animate drop ─► win/draw check
Repeat until four in a row or a full board ─► result sheet (rematch / swap model / replay)
```

- The human always moves first. The model loads while the human thinks about move one,
  which hides the load time behind something the user is already doing.
- Warm-up does two things. It prefills the static system prompt once and keeps that
  KV cache, and it runs a single throwaway step so the Metal kernels are compiled before
  the first real move.
- Input is locked during the AI turn. The Thinking panel streams live, so the wait reads
  as deliberate rather than frozen.

## 2. Architecture

One Xcode project with an app target and four local Swift packages. Game logic has no
knowledge of the UI or of MLX, so it is fully unit-testable.

```
LLMConnectFour/
├── App/                          SwiftUI app target
│   ├── GameViewModel.swift       @Observable game loop, async AI turn, cancellation
│   ├── Views/                    BoardView, DiscView, ThinkingPanel, ConfidenceBars,
│   │                             PromptInspector, ReplayView, LeaderboardView,
│   │                             BenchRunSheet, SettingsView, ResultSheet
│   └── Theme/                    MeshGradient background, glass styles, sounds
├── Packages/
│   ├── C4Core/                   Pure Swift, no dependencies
│   │   ├── Board.swift           6×7 bitboard, drop/undo, legalMoves, winner, isDraw
│   │   ├── Engine.swift          alpha-beta minimax + transposition table
│   │   ├── Tactics.swift         immediateWins, mustBlock, unsafeMoves, threatsCreated
│   │   └── Puzzles.swift         puzzle generator + checker (used by the bench)
│   ├── C4AI/
│   │   ├── MoveProvider.swift    protocol: func move(_ ctx: TurnContext) -> AsyncStream<TurnEvent>
│   │   ├── LLMMoveProvider.swift MLX: prompt → stream → forced answer → AIMove
│   │   ├── EngineMoveProvider.swift / RandomMoveProvider.swift   (bench anchors, fallback)
│   │   ├── BoardEncoder.swift    grid / column / combined views (§3.1)
│   │   ├── PromptBuilder.swift   system prefix + per-turn prompt, PromptVariant enum
│   │   ├── ColumnConstraint.swift  logit mask over legal-digit tokens (§3.3)
│   │   ├── ThinkingStyle.swift, DifficultyProfile.swift
│   │   ├── ModelRegistry.swift   models.json + per-model capability flags
│   │   └── MoveTrace.swift       everything about one move, Codable (§4, §5)
│   └── C4Bench/                  library + `c4bench` CLI: suites, rating, reports
└── Resources/  models.json, puzzles.json, prompts/ (versioned prompt templates)
```

A turn emits `TurnEvent`s (`.thinkingToken`, `.reasoningToken`, `.distribution`,
`.decided(AIMove)`). The UI and the benchmark consume the same stream. That stream is
how the Thinking panel shows thinking live.

`AIMove` holds: `column`, `distribution` (probability per legal column),
`reasoning`/`thinking` text, `source` (`.model` / `.modelAfterSelfCheck` / `.fallback`),
and timings (prefill ms, time to first token, decode tok/s, total ms). Each AI move is
stored as a `MoveTrace`, which also keeps the exact prompt, the seed and the prompt
version, so any move can be inspected or reproduced.

### Model loading and swapping

- Dependency: `ml-explore/mlx-swift-lm` **3.32.3**, pinned with `.upToNextMinor`, which
  pulls in `swift-huggingface` and `swift-transformers`. Products: `MLXLLM`,
  `MLXLMCommon`, `MLXHuggingFace`. Verified 2026-10-04: `LogitProcessor`/`LogitSampler`,
  `KVCache.copy()`, prompt-cache save/load, `UserInput.additionalContext` and
  `ThinkingBudget` all exist. **Turn off the default `FoundationModelsIntegration` trait**
  (`traits: []` in XcodeGen 2.46+), because it needs the macOS 27 SDK and may break
  Xcode 26 builds. All MLX calls stay inside
  `LLMMoveProvider` so API changes are contained in one file.
- Load with `LLMModelFactory.shared.loadContainer(from: #hubDownloader(), using:
  #huggingFaceTokenizerLoader(), configuration: ModelConfiguration(id:), progressHandler:)`.
  Downloads use swift-huggingface's `HubClient`. In the sandbox the cache is
  app-scoped (`Library/Caches/huggingface/hub`), so only the first launch downloads, and
  the cache is not shared with Python `mlx_lm`. `ModelConfiguration(directory:)` loads a
  local folder with no download. Loading works offline from the cache; an interrupted
  download keeps finished files but restarts the interrupted one.
- Set `MLX.Memory.cacheLimit` (`GPU.set(cacheLimit:)` is deprecated) to around 512 MB to 1 GB so memory does not
  creep up. Unload the current model before loading another.
- `Resources/models.json` is the only file that changes when adding a model, and
  Settings also accepts any custom `mlx-community/...` ID:

```json
[
  { "id": "mlx-community/Qwen3-4B-Instruct-2507-4bit", "name": "Qwen3 4B Instruct",
    "default": true, "sizeGB": 2.3, "thinking": false },
  { "id": "mlx-community/Qwen3-4B-Thinking-2507-4bit", "name": "Qwen3 4B Thinking",
    "sizeGB": 2.3, "thinking": true, "thinkTags": ["<think>", "</think>"] },
  { "id": "mlx-community/Qwen3-1.7B-4bit", "name": "Qwen3 1.7B", "sizeGB": 1.0,
    "thinking": true, "thinkTags": ["<think>", "</think>"],
    "chatTemplateArgs": { "enable_thinking": "$deepThink" } },
  { "id": "mlx-community/Qwen3-8B-4bit", "name": "Qwen3 8B", "sizeGB": 4.6, "thinking": true,
    "thinkTags": ["<think>", "</think>"], "chatTemplateArgs": { "enable_thinking": "$deepThink" } },
  { "id": "mlx-community/gemma-3-4b-it-4bit", "name": "Gemma 3 4B", "sizeGB": 3.4, "thinking": false, "notes": "loads text-only; vision weights still downloaded" },
  { "id": "mlx-community/Llama-3.2-3B-Instruct-4bit", "name": "Llama 3.2 3B", "sizeGB": 1.8, "thinking": false },
  { "id": "mlx-community/Qwen3.5-4B-4bit", "name": "Qwen3.5 4B", "sizeGB": 3.1, "thinking": true,
    "notes": "newer; benchmark against Qwen3 4B" }
]
```

- The capability flags drive the UI. **Deep think** is offered only when
  `thinking: true`; other models fall back to Explain with a longer budget. Confirm the
  repo names on Hugging Face at build time. The leaderboard picks the final default.

## 3. The model's turn: input, output, speed, stability

### 3.1 What the model sees

Small models fail mostly on **perception** (misreading the board, forgetting gravity),
not on strategy. The encoding's job is to remove every bit of work that is not real
decision-making.

**Rules for the encoding:**
- **Fixed perspective.** The model is always `O` ("you") and the opponent is always `X`,
  whoever moved first and whatever colours the UI uses. Pieces are relabelled before
  encoding, so the model never has to work out which side it is.
- **Unambiguous tokens.** Only the characters `X`, `O` and `.` appear, separated by spaces
  so each cell tokenizes on its own. Columns are numbered 1-7 (not 0-6) and rows are
  numbered 1 at the bottom to 6 at the top, printed top-down the way a person sees it.
- **Pre-computed gravity.** Each legal column is shown with the row a disc would land in.
  The model never has to simulate falling pieces.
- **Stateless turns.** Every turn is a fresh prompt containing the full board. There is no
  growing chat history to confuse the model, every move can be reproduced, and the static
  prefix stays cacheable.
- **Facts, never answers.** Hints from `Tactics` (wins, blocks, unsafe moves) are added
  depending on difficulty (§3.6). The prompt never says "play column N" unless that is a
  forced fact such as "you can win immediately in column 6".

**Static system prefix.** This part never changes during a game. It is prefilled once at
warm-up and its KV cache is reused on every turn. About 300-400 tokens, including two
short worked examples (few-shot), which cost nothing after warm-up:

```
You are an expert Connect Four player. You are O. Your opponent is X.
The board has 7 columns (1-7, left to right) and 6 rows (1 = bottom, 6 = top).
A disc dropped in a column lands on the lowest empty row. Four in a row
horizontally, vertically or diagonally wins.
Priorities: 1) win now  2) block the opponent's win  3) do not give the
opponent a winning square  4) build threats, prefer the centre columns.
Finish with a line "Column: N".
[2 short worked examples]
```

**Per-turn prompt** (this example is from Moderate, using the combined view):

```
Board (row 6 at top):
   1 2 3 4 5 6 7
6  . . . . . . .
5  . . . . . . .
4  . . . . . . .
3  . . . X . . .
2  . . . O X . .
1  . . X X O . .

Columns (bottom → top):
1: empty → lands row 1        5: O X → lands row 3
2: empty → lands row 1        6: empty → lands row 1
3: X → lands row 2            7: empty → lands row 1
4: X O X → lands row 4

Moves so far: X4 O4 X3 O5 X4 ... (11 total)
Facts: X threatens to win in column 2. You must block unless you can win first.
Legal columns: 1 2 3 4 5 6 7
```

- **Prompt variants** are an enum (`PromptVariant`): grid only, columns only, combined,
  with or without few-shot examples, with or without move history. The default is the
  variant that wins on the leaderboard. Templates live as files in `Resources/prompts/`
  with a version number, and every trace records that version. This turns "which prompt
  is better" into something measured rather than guessed.

### 3.2 How it answers: thinking styles

The model always generates its own answer. Style controls **how much it thinks
first**, and every style ends the same way: the app writes `Column: ` into the model's
output and restricts the next token to the legal digits (§3.3).

| Style | What happens | Visible in the Thinking panel | Est. move time (4B, M3 Pro) |
|---|---|---|---|
| **Instinct** | No generated text. One forward pass after `Column: `, then read the probability of each legal digit. | Confidence bars only | ~0.3-0.6 s |
| **Explain** (default) | Short reasoning, capped at about 64 tokens, then the forced answer. Reasoning comes **before** the answer, so it can actually influence the choice. | Streaming reasoning + bars | ~2-3 s |
| **Deep think** | The model's native thinking mode (`<think>…</think>`) with a token budget (default 512, adjustable). When the budget runs out, the app closes the tag itself and forces the answer. | Streaming thoughts (collapsible) + reasoning + bars | ~8-15 s |

The times are estimates: an M3 Pro has about 150 GB/s of memory bandwidth, so a 2.3 GB
4-bit model's ceiling is about 65 tok/s, and MLX realistically gets about 35-45 tok/s. Phase 3 replaces these estimates with
measured numbers.

**Thinking-view requirement:** the move really comes from the model's own generation,
so the option to see its thinking applies. The Thinking panel (§4) shows it.

### 3.3 Stable outputs

This list gives the same input → the same move, and the output is always valid:

1. **Forced answer prefix plus a legal-digit mask.** At load time, tokenize
   `"Column: 1"` … `"Column: 7"` and compare each against `"Column: "` to find the exact
   token ID for each digit in that tokenizer. This catches tokenizers that merge a
   leading space into the digit. If any digit does not come out as exactly one token,
   that model is flagged and its load fails clearly. When answering, every logit except
   the legal columns' tokens is set to −∞. Illegal or unparseable output becomes
   **impossible**, so no JSON, no parser and no retry loop are needed.
2. **The answer is a probability distribution, not just a token.** Softmax over the
   legal digits gives a confidence per column. The UI shows it, and the bench uses it.
   - Greedy (argmax) for Hard.
   - Sampling with a difficulty temperature for Easy and Moderate. The RNG seed for each
     move is `hash(gameSeed, ply)` and is stored in the trace, so any game, including any
     benchmark game, can be replayed exactly.
3. **Budgets with a clean close.** Reasoning and thinking have token caps. When a cap is
   hit, the app appends `</think>` (if open) and `\nColumn: `, so the model never trails
   off without answering.
4. **Low temperature for reasoning text** (0.3), separate from the column temperature,
   plus a mild repetition penalty so small models don't loop.
5. **The chat template comes from the model's tokenizer**, never handwritten, so every
   model gets its native format. Per-model quirks live in `models.json`, never in code.
6. **"Would-be illegal" is still measured.** Before masking, the bench records whether
   the model's unmasked top choice was legal. This shows whether the model actually
   understands the board, even though the mask hides its mistakes during play.
7. **Fallback is for errors only.** If something fails (out of memory, a cancelled task,
   a model error), `EngineMoveProvider` at depth 2 plays the move with `source: .fallback`
   and the UI shows a badge. It is never triggered by bad output.

### 3.4 Speed

| Lever | Effect |
|---|---|
| Static prefix KV cache, reused each turn | Only the per-turn part (~150-250 tokens) is prefilled. The first token arrives in a fraction of a second. |
| Output length is the main cost | Explain caps reasoning at 64 tokens; Instinct generates nothing. Most of the time per move is spent decoding output. |
| 4-bit quantised weights | Decode speed is limited by memory bandwidth, and 4-bit is about 2× faster than 8-bit. |
| Warm-up at load | No slow first move. |
| One model resident, `ModelContainer` reused | No reloads between games. A model switch is the only reload. |
| Start the AI turn the moment the human's disc lands | The prompt is prefilled while the drop animation (~350 ms) plays. |
| Thinking budget slider | The user chooses between speed and depth in Deep think. |

### 3.5 Self-check (Hard only)

After the forced answer, `Tactics` checks the chosen column. If the model missed an
immediate win or a forced block, it is re-prompted once with that fact in the prompt.
The second answer stands, and the move is marked `.modelAfterSelfCheck`. The bench
reports how often this happens.

### 3.6 Difficulty: Easy / Moderate / Hard

The difficulty control is a three-segment picker in the toolbar. It can only be
changed between games. On all three levels the model chooses the move. Difficulty only
changes how much help it gets and how freely it samples.

| | Easy | Moderate (default) | Hard |
|---|---|---|---|
| Facts in prompt | None | Immediate wins, must-blocks | Wins, blocks, unsafe moves, threats it can create |
| Legal columns offered | All | All | Moves that hand the opponent an immediate win are masked out, unless every move does |
| Column sampling | Temperature 1.0 | Temperature 0.5 | Greedy |
| Self-check | No | No | Yes (§3.5) |
| Expected feel | Beatable, makes human-like blunders | Rarely misses a win or a block | Tactically sound; needs real strategy to beat |

- `DifficultyProfile` holds these values in one place. The bench checks that the three
  levels are clearly separated on the leaderboard.
- Difficulty and thinking style are separate controls, with defaults of Moderate and
  Explain. The model is a third setting, and is never switched automatically, because a
  reload takes seconds.
- **Engine opponent** (Settings): minimax depth 2 / 4 / 7 for the same three levels, as
  a non-LLM reference.

## 4. Seeing what the model thinks

The **"Show thinking"** toggle is on by default, with a keyboard shortcut (⌘T). When it
is off, the panel is hidden but the trace is still recorded.

- **Thinking panel** (a system `.inspector`, streams live):
  - **Thoughts.** The Deep think content, in a collapsible block in a dimmer monospace
    font, with a token counter against the budget.
  - **Reasoning.** The Explain text, in normal type.
  - **Confidence bars.** Seven solid Swift Charts bars that line up with the board's
    columns and show the model's probability for each legal column. Masked columns are hatched.
    This view also works for Instinct, so it is never empty.
  - **Stats line.** Time to first token, tok/s and total time, plus a source badge
    (`model` / `self-checked` / `fallback`).
- **Board overlay.** While the model is thinking, the confidence bars also appear as a
  faint glow above each column, so you can watch the model "lean" before it drops.
- **"What the model sees" inspector** (click the eye icon): the exact system and
  per-turn prompt for this move, with the facts that were added highlighted. This is
  the most useful view for learning how the prompt works.
- **Replay.** After a game, step through the moves. Each AI move shows its full trace:
  prompt, thoughts, reasoning, distribution and timing. Games are saved as JSON and can
  be exported.
- **Honesty note** (About pane and README): reasoning is the model's own generated text
  and comes before the answer, but it is not a guaranteed explanation of why the model
  chose a column. The confidence bars are the more objective signal.

## 5. Benchmarking and leaderboard

The goal is that any model and setting can be ranked on one scale, reproducibly, from
both the app and the command line.

### 5.1 What gets ranked

A **contestant** is one configuration: `model × thinking style × difficulty × prompt
variant`, for example "Qwen3 4B · Explain · Hard · combined-v3". Anchor players have a
fixed strength and keep the scale stable:
`Random`, `Minimax d1`, `d2`, `d4`, `d6`.

### 5.2 Suites

| Suite | What it is | Why |
|---|---|---|
| **Puzzles** | About 150 positions in `Resources/puzzles.json`, generated once by `C4Core.Puzzles` from random playouts and checked by the engine. Categories: win-in-1, block-in-1, avoid-the-blunder, win-in-3. Each has its set of correct columns. | Fast, deterministic, and points to *which* skill is missing. |
| **Matches** | Each contestant plays every anchor. Games start from varied two-move openings and each opening is played with both colours, so greedy runs are not repeats of the same game. | Real playing strength. |
| **Round robin** (optional) | Contestants play each other. Two models are loaded at once only when their combined size is under 6 GB. | Direct comparisons. Not required for ratings, because everyone plays the anchors. |

Presets:
- **Quick:** puzzles + 14 games against each of 3 anchors.
- **Standard:** puzzles + 50 games against each of 5 anchors.
- **Full:** Standard + round robin.

Rough timing for one 4B configuration in Quick: about 3 minutes with Instinct, about 20
with Explain. Long runs keep the Mac awake with `ProcessInfo.beginActivity` and can be
cancelled and resumed, because every finished game is already saved.

### 5.3 Rating

- **Bradley-Terry maximum-likelihood fit over all games**, with a weak prior (one virtual
  draw for each contestant against `Minimax d2`). Without it, the fit diverges for any player
  that won or lost every game, such as Random or d6. Ratings are reported on an Elo-like
  scale with `Minimax d2` fixed at 1000 and draws counted as half a win. Unlike Elo
  updated game by game, the result does not depend on the order games were played.
- **95% confidence interval** from a bootstrap over games, shown as ± in the table.
  Rows whose intervals overlap are shown as tied, which keeps the board honest.
- New contestants can be added at any time; the ratings are recomputed from all saved games.

### 5.4 Leaderboard columns

| Rank | Contestant | Rating ± CI | Puzzles % (by category) | Win % vs d4 | Blunders / game | Would-be illegal % | Median move time | tok/s | Load time | Peak RAM | Size |
|---|---|---|---|---|---|---|---|---|---|---|---|

- **Blunders** are measured with `Tactics`: a missed immediate win, or a missed forced
  block.
- Speed columns depend on the hardware. Every run is tagged with the chip, RAM, macOS
  version and app/prompt version. The leaderboard filters by machine for speed columns,
  while strength columns (seeded, so reproducible) can be compared across machines.

### 5.5 Storage and interfaces

- **Storage:** one JSONL file per game under
  `~/Library/Application Support/LLMConnectFour/bench/`, holding every `MoveTrace`. The
  leaderboard is always recomputed from these files and never edited by hand. Any
  benchmark game opens in Replay with its full thinking.
- **CLI:**
  - `c4bench run --model <id> --style explain --difficulty hard --suite quick`
  - `c4bench puzzles --model <id>`
  - `c4bench report --format md|csv|json` generates `LEADERBOARD.md` and the README
    table.
- **In-app Leaderboard window:**
  - A sortable native `Table`.
  - A "Run benchmark" sheet: choose models, styles, difficulties and suite, then see
    progress with an estimated time remaining and a live mini-board of the current game.
  - Click a row for a breakdown: W/D/L per anchor, a puzzle category chart and its
    worst blunders.
  - Click any game to replay it.

## 6. UI: Liquid Glass in SwiftUI

Apple's rule: glass is the **control layer floating above content**, never the content
itself. The board, discs, text and tables are content. The toolbar, ghost disc and
transient cards are glass. The liquid-glass-js / liquidGL look comes from vivid content
under a few well-placed pieces of glass, not from making everything glass.

- **Background:** a `MeshGradient` that drifts slowly (period of 30 s or more, redrawn by
  `TimelineView` at 30 fps). It pauses while the AI streams text and when the window is
  inactive. Separate light and dark palettes. Static under Reduce Motion.
- **Board (content, not glass):** a translucent tinted plate drawn in `Canvas`. The holes are
  punched out with `.blendMode(.destinationOut)` inside `.compositingGroup()`, and each has
  an inner shadow. The gradient shows through the holes.
- **Discs:** solid coral (human) and cyan (AI), with a radial specular highlight
  (`.plusLighter`). AI discs have an inner ring, so the two sides never rely on colour alone.
  The drop uses `.spring(duration: 0.35, bounce: 0.25)` and lands with a sound and
  `NSHapticFeedbackManager` `.levelChange`.
- **Ghost disc (glass):** `.glassEffect(.clear.tint(coral.opacity(0.3)), in: .circle)` above
  the hovered column (`onContinuousHover`). It moves with a spring and appears and
  disappears with `glassEffectTransition`. A haptic `.alignment` tick fires on each column
  change.
- **Toolbar (system glass):** a real `.toolbar` with a unified title bar:
  - difficulty and style as segmented `Picker`s, disabled during a game;
  - the model as a `Menu`;
  - New Game as `.buttonStyle(.glassProminent)`;
  - Leaderboard and Show thinking as plain items;
  - groups separated with `ToolbarSpacer`.
  No custom pill container.
- **Thinking panel:** an `.inspector` 280-420 pt wide (ideal 320), toggled with ⌘T. Plain
  text on the system surface: thoughts in a secondary monospaced `DisclosureGroup`,
  reasoning in body type, and confidence bars as solid Swift Charts `BarMark`s (masked
  columns hatched). No glass inside the panel.
- **Board glow:** a gradient per column whose opacity follows the model's probability while
  it thinks. Hidden under Increase Contrast.
- **Win:**
  - A Metal `.layerEffect` specular sweep across the four winning discs, falling back to
    a gradient sweep. This is the native equivalent of the liquidGL highlights.
  - The other discs dim to 40%.
  - A `GlassEffectContainer` card appears with Rematch (`.glassProminent`) and Replay /
    Swap model (`.glass`).
- **Empty and loading states:** a "Warming up… 63%" glass capsule, a "Your move" message
  in the panel before the first AI turn, and an inline banner with Retry when a download
  fails.
- **Keyboard:** 1-7 drop a disc, ⌘N new game, ⌘T thinking, ⌘L leaderboard, ⌘, Settings.
- **Accessibility:** system glass adapts by itself. The custom pieces read
  `accessibilityReduceTransparency` (opaque board, no glass ghost), `colorSchemeContrast`,
  `accessibilityReduceMotion` (no bounce, drift or sweep) and
  `accessibilityDifferentiateWithoutColor`. The board is a VoiceOver grid, and the bars use
  `accessibilityChartDescriptor`.
- **Window:** the standard unified title bar (not hidden), a minimum size of 960×640, the
  board kept at a 7:6 ratio, and the gradient extended under the inspector with
  `.backgroundExtensionEffect()`.
- **Leaderboard window:** a native `Table` with sorting, `.monospacedDigit()` numbers and
  the standard background. Glass appears only in its toolbar.
- **App icon:** Icon Composer layered glass (a disc over a grid).
- **Checked against the macOS 26 SDK:** `.interactive()` with a
  pointer, `backgroundExtensionEffect` on macOS, and the `glassEffectTransition` case names.
  The design review marked these unverified.

## 7. Build phases

Each phase ends with something that runs.

| # | Phase | Done when |
|---|---|---|
| 0 | Scaffold + contracts | XcodeGen `project.yml` (no hand-edited `.pbxproj`), packages, Swift Testing, `.gitignore`, MIT license, and all shared types and protocols as compiling stubs (§11.1). Builds clean. |
| 1 | `C4Core` | Bitboard, win/draw, tactics, minimax, puzzle generator. Tests cover every win direction, full columns, draws, a forced win in 3, and puzzle answers checked by the engine. |
| 2 | Playable vs Engine | A full game against minimax with the glass board, drop animation and win highlight. No LLM yet. |
| 3 | MLX + Explain | Background load and warm-up, prefix KV cache, `BoardEncoder`, `PromptBuilder`, digit-token discovery, legal mask, streaming Explain, difficulty profiles, measured latencies replacing the estimates in §3.2. |
| 4 | Thinking views | Instinct and Deep think, confidence bars and board glow, prompt inspector, traces, replay. |
| 5 | Bench + leaderboard | Suites, Bradley-Terry with CIs, the CLI, the in-app leaderboard. Run Standard on the model list. The results set the default model, prompt variant and difficulty tuning. |
| 6 | Polish | Sounds, accessibility, app icon, error states (download failed, low memory, offline on first run). Check memory with Instruments over a long session. |
| 7 | Showcase | README, demo video, screenshots, `LEADERBOARD.md`, tagged release. |

## 9. Scope: Mac first

This build targets **Apple Silicon Macs (M1 or newer) on macOS 26+**.
- **8 GB Macs:** pick Qwen3 1.7B. Settings warns when the selected model is larger than
  about 40% of physical memory.
- **Intel Macs:** not supported, because MLX needs Apple Silicon.

**Later (roadmap only):** a `.ultraThinMaterial` fallback for macOS 14/15; an
OpenAI-compatible `MoveProvider` (Ollama, LM Studio, `mlx_lm.server`), which would put
those models on the same leaderboard; and a Windows/Linux port using `C4Core`, the
prompt templates and `puzzles.json` as the spec.

## 10. Risks

| Risk | Mitigation |
|---|---|
| The `mlx-swift-lm` API changes, or has no logit-processor or KV-cache hook | Pin the version; contain MLX in one file. If there is no logit hook, sample the column token manually from the logits of a single forward step, which is the same technique Instinct uses. |
| A tokenizer splits digits oddly | Digit-token discovery at load; that model is rejected with a clear message. |
| The model plays badly, which looks bad in a demo | Moderate as the default, Hard for strong play; the leaderboard frames it as a measured experiment. |
| Deep think is slow | Budget slider; Explain as the default; the leaderboard shows whether thinking actually helps. |
| Benchmarks take hours | Quick preset, Instinct for wide sweeps, resumable runs. |
| First-run download (about 2 GB) feels broken | Progress with MB/s; the board is playable immediately; clear offline error. |
| Glass looks flat in screenshots | Keep glass to the control layer so the vivid gradient stays visible; win sweep shader; capture in light and dark mode. |
| Memory growth over long sessions | GPU cache limit, one `ModelContainer`, Instruments check in Phase 6. |

## 12. Pre-answered build questions

Decisions that would otherwise be made ad hoc in code. These answers are the defaults;
change them here, not in code.

### Toolchain

| Question | Answer |
|---|---|
| Swift and Xcode version? | Swift 6 language mode with strict concurrency, built with Xcode 26 or newer, macOS 26.0 minimum, arm64 only. |
| Project generator? | XcodeGen (`brew install xcodegen`). `project.yml` is committed; `.xcodeproj` is gitignored. |
| Which dependencies are allowed? | Only `mlx-swift-lm` and what it pulls in (`swift-huggingface`, `swift-transformers`, swift-syntax for its macros). Use Swift Charts for charts. No other third-party packages. |
| Sandbox and entitlements? | App Sandbox on, with `network.client` for Hugging Face downloads. Model cache in the app container's Caches folder. |
| Bundle ID and name? | `com.komi.LLMConnectFour`; display name "LLM Connect Four". |
| Formatting? | `swift format` (bundled with the Xcode toolchain) with the default configuration, run before merge. |
| CI? | Tests run locally. A GitHub Actions job for `C4Core` and `C4Bench` is optional. |
| Logging? | `os.Logger`, subsystem = bundle ID, with categories `game`, `llm`, `bench`. |

### Architecture

| Question | Answer |
|---|---|
| State management? | `@Observable` + `@MainActor` view models. No TCA, no Combine. |
| Concurrency for the LLM? | `LLMMoveProvider` is an `actor` and runs one generation at a time. New Game or quitting cancels the turn `Task`; generation checks for cancellation on every token. |
| Bitboard layout? | Pascal Pons layout: 7 bits per column, `UInt64`, with a position + mask pair. |
| Column indexing? | **0-based everywhere in code.** 1-based only in prompts and visible UI, converted in `BoardEncoder` and the views. |
| Player naming in Core? | `Disc.first` / `Disc.second`. The encoder relabels them to "you" (`O`) and "opponent" (`X`); the UI maps them to human and AI. |
| Persistence? | JSON/JSONL files in Application Support (`games/`, `bench/`). No SwiftData or Core Data. Settings use `@AppStorage`. Keep the last 200 played games; keep bench data forever. |
| Windows and scenes? | A main game window, a separate `Window` scene for the Leaderboard, and a `Settings` scene. |
| Undo or hint for the human? | Not in v1, which keeps games honest and the scope small. |
| Who moves first? | In the app, the human always does. In the bench, colours alternate per opening. |
| Sounds and haptics? | Built-in `NSSound` names (for example `Pop` and `Tink`), so there are no audio assets, plus `NSHapticFeedbackManager` when a disc lands and when the ghost changes column. |
| Localization? | English only, but strings go in a String Catalog. |

### Model and prompt

| Question | Answer |
|---|---|
| Model without a system role (for example Gemma)? | Rely on the tokenizer's chat template. If the template rejects a system role, put the system text at the start of the first user message. |
| No KV-cache reuse API? | Skip caching and accept the extra prefill time. Note it in the trace. Not a blocker. |
| No logit-processor hook? | Run one forward step manually after `Column: ` and take the softmax over the legal digits. This is the same code path as Instinct. |
| Sampling settings? | Column temperature from `DifficultyProfile`. Reasoning text: temperature 0.3, top-p 0.9, repetition penalty 1.1. |
| Token budgets? | Explain 64. Deep think 512 by default, adjustable from 128 to 2048. |
| Hugging Face token? | Not needed; public repos only. |
| Memory guard? | Warn when a model is larger than 40% of RAM. Refuse to load one larger than 60%. |
| Deep think on a model that can't think? | The option is disabled in the UI, with a tooltip explaining why. |

### Bench and engine

| Question | Answer |
|---|---|
| Rating implementation? | Write it ourselves: Bradley-Terry fitted with the MM algorithm (about 60 lines), with 1,000 bootstrap resamples. |
| Do bench contestants sample? | Yes, according to their difficulty, using seeds of the form `hash(gameSeed, ply)`. Results are reproducible. |
| Engine tie-breaking? | Centre-first column order, so the engine is deterministic. Variety comes from the openings. |
| Puzzle generation? | Run once with a fixed seed; the JSON is committed. Regenerate only on purpose. |
| Engine time limit? | None needed. Depth 7 with a bitboard and transposition table is fast; the test enforces under 100 ms **in the Release configuration** (Debug builds can be 10× slower). |

### UI

| Question | Answer |
|---|---|
| Colours? | Human coral `#FF6B5B`, AI cyan `#3FD0E0` (AI discs also get an inner ring). For text in light mode, use the darker `#D9473A` / `#1F8FA0`. Defined in `DesignTokens.swift`. |
| Layout? | Minimum window 960×640, standard unified toolbar. Board at a 7:6 ratio; Thinking panel is an `.inspector` (ideal 320 pt). |
| Light and dark mode? | Both, with separate mesh-gradient palettes for each. |
| App icon? | Made by hand in Icon Composer at the Showcase phase; a placeholder until then. |
