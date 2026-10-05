# MLX findings

What the real `mlx-swift-lm` 3.32.3 API looks like, how `C4MLX` uses it, and measured
numbers that replace the estimates in plan §3.2. Machine: M3 Pro, 18 GB, macOS 27,
Xcode 27, Release build. Resolved versions: mlx-swift-lm 3.32.3, mlx-swift 0.32.3,
swift-huggingface 0.12.0, swift-transformers 1.3.4, swift-jinja 2.5.1.

## Code layout

| File | Role |
|---|---|
| `Packages/C4MLX/Sources/C4MLX/MLXSession.swift` | **The only file that calls MLX / Hub APIs.** Loading, tokenizer, chat template, prefix KV cache, forward passes, sampling, digit-logit readout, memory. |
| `Packages/C4MLX/Sources/C4MLX/LLMMoveProvider.swift` | The actor. Turn logic on plain token arrays (`[Int]`) and an opaque `Logits` handle; no MLX imports. |
| `Packages/C4MLX/Sources/C4MLX/ColumnConstraint.swift` | Digit-token discovery and the legal-digit mask (pure Swift, unit tested). |
| `Tools/mlx-smoke/main.swift` | CLI smoke test (Xcode tool target, module `MLXSmoke`, scheme `mlx-smoke`). |

## Confirmed API surface

**Loading**
- `LLMModelFactory.shared.load(from: #hubDownloader(), using: #huggingFaceTokenizerLoader(), configuration: LLMModelFactory.shared.configuration(id:), progressHandler:) async throws -> sending ModelContext`. `loadContainer(...)` is the same but wraps it in a `ModelContainer`. Free functions `loadModel(...)` / `loadModelContainer(...)` exist too.
- Local folder, no network: `LLMModelFactory.shared.load(from: URL, using: #huggingFaceTokenizerLoader())` (or `ModelConfiguration(directory:)`).
- `#hubDownloader()` expands to a `Downloader` around `HuggingFace.HubClient()`; `#huggingFaceTokenizerLoader()` wraps `Tokenizers.AutoTokenizer.from(modelFolder:)`. Both need `import HuggingFace` and `import Tokenizers` in the calling file.
- Cache: `HubCache.default` = `$HF_HUB_CACHE`, else `$HF_HOME/hub`, else `~/.cache/huggingface/hub` (not sandboxed) or `Library/Caches/huggingface/hub` (sandboxed). Python-compatible layout (`blobs/`, `refs/main`, `snapshots/<commit>/`). Snapshot path: `cache.resolveRevision(repo:kind:ref:)` + `cache.snapshotPath(repo:kind:commitHash:)` (exposed as `LLMMoveProvider.cachedModelDirectory(for:)`).
- Progress: the handler gets a byte-weighted parent `Foundation.Progress`, sampled every 100 ms on the **main actor**. **Surprise:** a parent's `completedUnitCount` only moves when a whole file finishes; in-flight bytes are only in `fractionCompleted`. Using `completedUnitCount` made the bar sit at 1% for the whole 2.2 GB weights file. `DownloadMeter` uses `fractionCompleted × totalUnitCount`.
- A cached snapshot hits a fast path (`Progress` 1/1, no network). If the file listing fails (offline), it also falls back to the cache.

**`ModelContainer` vs `ModelContext`.** `ModelContainer.perform { (ModelContext) async throws -> R }` exists (the `(model, tokenizer)` forms are deprecated). I keep the `ModelContext` (returned `sending` by `load`) **inside the actor** instead: the KV caches are non-`Sendable` classes, and keeping both in one isolation domain avoids `perform(nonSendable:)` region gymnastics. A turn runs synchronously on the actor, which also guarantees one generation at a time.

**Tokenizer** (`MLXLMCommon.Tokenizer`, `Sendable`)
- `encode(text:addSpecialTokens:)`, `decode(tokenIds:skipSpecialTokens:)`, `convertTokenToId(_:)`, `eosTokenId`, `unknownTokenId`.
- `applyChatTemplate(messages: [[String: any Sendable]], tools:, additionalContext: [String: any Sendable]?) throws -> [Int]`. The bridge always passes `add_generation_prompt: true`. `additionalContext` is where `enable_thinking` goes (as a `Bool`).
- `NaiveStreamingDetokenizer` exists, but I decode each phase's tokens as a whole and diff the strings (simple, and needed anyway to detect `Column:` and `</think>`).

**Forward pass and logits**
- `LanguageModel.prepare(_ input: LMInput, cache: [KVCache], state: LMOutput.State?, prefill: PrefillParameters) throws -> PrepareResult` (`.tokens(rest)` or `.logits(LMOutput)`), then `model(rest[text: .newAxis], cache:, state:) -> LMOutput`; logits are `[1, T, vocab]`.
- `PrefillParameters(stepSize:chunking:progress:)`, default step 512. Passing `stepSize = count - 1` makes `prepare` fill the cache for all but the last token without running the LM head on them: **about 6% faster prefill** (460 to 435 ms for 214 tokens on the 4B).
- `model.newCache(parameters: nil) -> [KVCache]`.

**Sampling hooks** (all exist as the plan expected)
- `protocol LogitProcessor { mutating prompt(_:), process(logits:), mutating didSample(token:) }`, `protocol LogitSampler { sample(logits:) }`.
- `RepetitionContext(repetitionPenalty:repetitionContextSize:)`, `TopPSampler(temperature:topP:topK:minP:seed:)`, `CategoricalSampler`, `ArgMaxSampler`, `GenerateParameters.sampler()/processor()`. A `seed` makes reasoning text reproducible; I pass `context.seed`.
- `ThinkingBudgetProcessor` / `ThinkingBudgetConfiguration` exist, but I don't use them: the budget is enforced by my own loop so the close (`</think>`, `\nColumn: `) is explicit.
- I don't use `TokenIterator` / `generate(...)`. `TokenIterator` computes token N+1 before it returns N (`asyncEval` pipelining), so the cache would already hold a token past `Column:`. My loop samples, checks, then feeds.

**KV cache**
- `protocol KVCache` with `offset`, `state`, `isTrimmable`, `trim(_:)`, `copy() -> any KVCache`. `KVCacheSimple.copy()` slices the arrays to `offset`, which is cheap. Qwen3 uses `KVCacheSimple` (trimmable). Hybrid models (`MambaCache`/`ArraysCache`, for example Qwen3.5) are not trimmable, so `LLMMoveProvider` falls back to a full re-prefill when it must back up.
- Prompt cache to disk: `savePromptCache(url:cache:metadata:)`, `loadPromptCacheSnapshot(url:) -> PromptCacheSnapshot` (`loadPromptCache` is the older form). Not used: prefilling the prefix again takes about 400 ms, so a disk cache isn't worth it.

**Memory**: `MLX.Memory.cacheLimit` (settable static; `GPU.cacheLimit` is deprecated), `MLX.Memory.activeMemory/peakMemory/cacheMemory`, `MLX.Memory.clearCache()`. Set to 768 MB at load.

## How a turn works (as built)

1. `promptBuilder(context)` (injectable) gives `Prompt`; `.prompt` is emitted first.
2. Render system + user with the tokenizer's chat template (+ `chatTemplateArgs`, `"$deepThink"` becomes a Bool). If the template throws, it retries with the system text at the start of the user message.
3. **Static prefix**: the longest common prefix of two renders with different user text (`"A1"` / `"Z9"`), cached per `(template args, system text)`. Its KV is built once and kept (LRU of 3, about 30 MB each on the 4B). Each turn copies it (`copy()`) and prefills only the rest. If the prompt doesn't start with the prefix tokens, it does a full prefill (`prefixCacheHit = false`).
4. **Think tags**: if the generation prompt leaves `<think>` open (thinking-only templates) and the style isn't Deep think, it appends `\n</think>\n\n`. For Deep think it appends `<think>\n` if the template didn't.
5. **Instinct**: `Column: ` is part of the prompt, so one prefill gives the answer logits.
6. **Explain**: sample (temp 0.3, top-p 0.9, repetition penalty 1.1 over the last 64 tokens, seeded) up to the budget, streaming `.reasoningToken` deltas. A tail that could start `Column:` is held back so it never flickers into the panel. If the model writes `Column:`, it backs up to just before it (cache `trim`, or a re-prefill if the cache can't trim), feeds `Column: ` and does the masked step (its own digit is never used). On budget or EOS it feeds `\nColumn: `.
7. **Deep think** (only if `spec.thinking`): stream `.thinkingToken` up to the budget. On `</think>` it switches to reasoning with Explain's budget of 64; if the budget runs out it feeds `\n</think>\n\n` itself. Deep think on a non-thinking model is Explain with the context's (longer) budget.
8. Gather the 7 digit logits on the GPU. `unmaskedTopChoiceLegal` = the argmax of the 7 is a column `board.canPlay` allows (not just the Hard-allowed set). Distribution = `ColumnDistribution.softmax` over `prompt.allowedColumns`, which is exactly "every other logit is −∞" (`ColumnConstraint.mask` is the full-vocabulary reference, unit tested). Column = `distribution.sample(temperature: profile.columnTemperature, using: &SplitMix64(seed: context.seed))`.
9. `Task.checkCancellation()` before every token. A cancelled consumer (`onTermination` cancels the task) ends the turn with `.failed("Cancelled")`; any error becomes `.failed`, never a fallback move.

Digit discovery tries `"Column: "` plus a bare digit first, then `"Column:"` plus a `" N"` token (merged-space tokenizers, recorded in `DigitTokenMap.answerPrefix`), and otherwise throws `digitNotSingleToken`. Qwen3: digits `[16…22]`, prefix `"Column: "`.

## Measured numbers

Qwen3 4B Instruct 2507 4-bit (`mlx-community/Qwen3-4B-Instruct-2507-4bit`). Smoke prompt: system prefix 199 tokens (Instinct) / 215 (Explain), total about 413 to 426 tokens, so about 214 per-turn tokens.

| Measure | Value |
|---|---|
| Cold first launch: download 2.3 GB + load + warm-up | 144 s (about 16 MB/s on this connection; the download dominates) |
| Cached load via the Hub (no download) | load 0.72 s + warm-up 0.92 s = **1.6 s** |
| Offline load from the snapshot folder (`modelDirectory`) | load 0.50 s + warm-up 0.90 s = **1.4 s** |
| Prefill, per-turn part only (prefix cache hit, ~214 tokens) | **420 to 440 ms** |
| Prefill, whole prompt (prefix cache miss, ~413 tokens) | **810 to 870 ms** |
| **Instinct** move (prefix hit) | **0.43 to 0.47 s** (plan estimate 0.3 to 0.6 s) |
| **Explain** move (16 to 64 tokens) | **1.2 to 1.9 s**, average 1.47 s (plan estimate 2 to 3 s) |
| Decode speed | **38 to 46 tok/s** (dropped to about 30 while other builds were running) |
| Time to first reasoning token | about 0.39 to 0.44 s |
| GPU memory with the model loaded | active 2.28 GB, peak 2.71 GB, MLX buffer cache at its 768 MB limit; process peak footprint 3.8 GB |
| Cancellation | next move starts 21 ms after the consumer cancels |

Qwen3 1.7B 4-bit (`mlx-community/Qwen3-1.7B-4bit`, `thinking: true`):

| Measure | Value |
|---|---|
| Fresh download (1 GB) + load + warm-up | 25 s (progress bar moving, 22 to 54 MB/s) |
| Cached load + warm-up | 0.9 s |
| Prefill with / without prefix cache | 170 ms / 320 ms |
| Instinct move | 0.17 to 0.18 s |
| Explain move | 0.35 to 0.61 s, decode 80 to 91 tok/s |
| **Deep think** move (512 thought tokens + 64 reasoning) | **6.8 to 8.8 s** (plan estimate 8 to 15 s for the 4B) |

Decode is memory-bandwidth bound (about 41 tok/s for 2.3 GB means about 95 GB/s effective). Prefill is compute bound (about 490 tok/s on the 4B), so the static-prefix cache saves about 400 ms per move and the per-turn prompt length matters: each 100 tokens of board text cost about 200 ms per move.

## Observations

- **Explain quality depends on brevity.** With a system prompt that says "one short sentence (at most 25 words)", 3 of 4 Explain moves finished on their own in 32 to 44 tokens and wrote `Column:` themselves. With a vaguer prompt the model wrote a "Facts:" paragraph, hit the 64-token cap mid-thought, and in 2 of 4 cases the forced answer was **column 1 with 99% confidence** (an "enumeration" continuation such as `Row 6: …`), including a missed immediate win. The same thing happens after Deep think when the reasoning is cut. Prompt v2 therefore asks for one short sentence. A soft landing (about 16 extra tokens to finish the sentence) is an option if the benchmark shows budget-hit moves are worse.
- **Prefixes depend on style**, so the first Instinct move after a warm-up done for Explain pays a prefix miss (+400 ms). The app should call `provider.prepare(for:)` with the current style and variant after load and whenever they change.
- Hard Instinct is deterministic: the same board twice gives the same column and an identical distribution.
- `unmaskedTopChoiceLegal` was `true` on every test board, including the full-centre-column board: Qwen3 4B never preferred the full column, so the mask didn't change any of these moves.

## Download resume

Read from the source and tested by killing the process mid-download:
- Files are downloaded with a `URLSessionDownloadTask` into a CFNetwork temp file, then moved into `blobs/`. `.incomplete` blobs plus an HTTP `Range` resume exist in the code, but only for bytes already appended to an `.incomplete` file, which a killed process never writes.
- **Result:** after an interrupted download, finished files are kept and the interrupted file starts again from 0. The mlx-community 4B weights are one 2.2 GB file, so in practice the download restarts. The killed process also leaves its `CFNetworkDownload_*.tmp` (350 MB in the test) in `$TMPDIR`; the OS cleans it up eventually.
- **Offline:** a second load needs no network. The Hub path takes the cached-snapshot fast path, and `LLMMoveProvider(spec:modelDirectory:)` loads the snapshot folder directly. Both were tested.

## Not tested / left open

- Gemma's system-role fallback runs in code but hasn't been run against Gemma (3.4 GB download).
- The non-trimmable re-prefill path (hybrid models such as Qwen3.5) runs in code but hasn't been run.
- Deep think's reasoning after `</think>` is capped at 64 tokens and usually hits the cap (see above).
- A prompt-cache file on disk is not used (re-prefilling takes about 0.4 s).
