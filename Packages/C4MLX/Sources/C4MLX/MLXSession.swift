// The only file that calls mlx-swift / mlx-swift-lm / swift-huggingface APIs. If MLX
// changes, this is the file to update. `LLMMoveProvider` drives turns through it with
// plain token arrays and the opaque `Logits` handle.

import C4AI
import C4Core
import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers
import os

/// The next-token logits after a forward pass (shape `[1, vocab]`, float32). Opaque outside
/// this file.
struct Logits {
  fileprivate let array: MLXArray
}

/// A loaded model plus its KV caches. Not thread-safe: owned and used only by the
/// `LLMMoveProvider` actor, one turn at a time.
final class MLXSession {
  private var context: ModelContext
  let digits: DigitTokenMap
  /// Tokens that end the assistant turn (EOS, `<|im_end|>`, …).
  let stopTokens: Set<Int>

  /// One cached static prefix: the tokens and the KV cache after prefilling them.
  private struct PrefixEntry {
    var key: String
    var tokens: [Int]
    var cache: [KVCache]
    var state: LMOutput.State?
  }
  /// Most recently used last. Small, because each entry holds ~60 MB of KV for a 4B model.
  private var prefixes: [PrefixEntry] = []
  private static let maxPrefixes = 3
  /// Static-prefix token arrays per key, so the template is rendered once per key.
  private var prefixTokenCache: [String: [Int]] = [:]

  // Per-turn state.
  private var cache: [KVCache] = []
  private var state: LMOutput.State?
  private var processor: RepetitionContext?
  private var sampler: TopPSampler?

  private static let logger = Logger(subsystem: "com.komi.LLMConnectFour", category: "llm")

  private init(context: consuming ModelContext, digits: DigitTokenMap, stopTokens: Set<Int>) {
    self.context = context
    self.digits = digits
    self.stopTokens = stopTokens
  }

  // MARK: Loading

  /// GPU buffer cache limit (§2): keeps memory from creeping up between turns.
  static let cacheLimitBytes = 768 * 1024 * 1024

  /// Downloads (if needed) and loads a model. `directory` loads a local folder with no
  /// network access. `download` receives the Hub's byte-based `Progress`.
  static func load(
    id: String, directory: URL?, download: @escaping @Sendable (Progress) -> Void
  ) async throws -> sending MLXSession {
    MLX.Memory.cacheLimit = cacheLimitBytes
    let context: ModelContext
    if let directory {
      context = try await LLMModelFactory.shared.load(
        from: directory, using: #huggingFaceTokenizerLoader())
    } else {
      context = try await LLMModelFactory.shared.load(
        from: #hubDownloader(), using: #huggingFaceTokenizerLoader(),
        configuration: LLMModelFactory.shared.configuration(id: id), progressHandler: download)
    }
    let tokenizer = context.tokenizer
    let digits = try ColumnConstraint.discover {
      tokenizer.encode(text: $0, addSpecialTokens: false)
    }
    var stops = context.configuration.eosTokenIds
    if let eos = tokenizer.eosTokenId { stops.insert(eos) }
    let named = context.configuration.extraEOSTokens.union([
      "<|im_end|>", "<|endoftext|>", "<end_of_turn>", "<|eot_id|>", "<|end|>",
    ])
    for name in named { if let id = tokenizer.convertTokenToId(name) { stops.insert(id) } }
    // The unknown token can be what convertTokenToId falls back to; never stop on it.
    if let unk = tokenizer.unknownTokenId { stops.remove(unk) }
    logger.info("loaded \(id, privacy: .public); digits \(digits.tokenIDs, privacy: .public)")
    return MLXSession(context: context, digits: digits, stopTokens: stops)
  }

  /// The Hub cache snapshot folder for `id`, if it has been downloaded before. Loading
  /// from it needs no network.
  static func cachedSnapshotDirectory(for id: String) -> URL? {
    let cache = HubCache.default
    guard let repo = Repo.ID(rawValue: id),
      let commit = cache.resolveRevision(repo: repo, kind: .model, ref: "main"),
      let snapshot = try? cache.snapshotPath(repo: repo, kind: .model, commitHash: commit),
      FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("config.json").path)
    else { return nil }
    return snapshot
  }

  /// Drops every cache and returns freed GPU buffers to the system.
  func release() {
    cache = []
    prefixes = []
    prefixTokenCache = [:]
    MLX.Memory.clearCache()
  }

  static func clearMemory() { MLX.Memory.clearCache() }

  /// Active, peak and cached GPU memory in MB.
  static func memoryReport() -> (activeMB: Int, peakMB: Int, cacheMB: Int) {
    let mb = 1024 * 1024
    return (MLX.Memory.activeMemory / mb, MLX.Memory.peakMemory / mb, MLX.Memory.cacheMemory / mb)
  }

  // MARK: Tokenizer

  func encode(_ text: String) -> [Int] {
    context.tokenizer.encode(text: text, addSpecialTokens: false)
  }

  func decode(_ tokens: [Int]) -> String {
    context.tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false)
  }

  /// The full chat prompt (system + user + generation prompt) from the tokenizer's own
  /// template. If the template rejects a system role (some Gemma templates raise), the
  /// system text is put at the start of the user message instead (§12).
  func chatTokens(system: String, user: String, templateArgs: [String: any Sendable]) throws
    -> [Int]
  {
    let tokenizer = context.tokenizer
    let args = templateArgs.isEmpty ? nil : templateArgs
    do {
      return try tokenizer.applyChatTemplate(
        messages: [["role": "system", "content": system], ["role": "user", "content": user]],
        tools: nil, additionalContext: args)
    } catch {
      Self.logger.notice("chat template rejected a system role; merging it into the user turn")
      return try tokenizer.applyChatTemplate(
        messages: [["role": "user", "content": system + "\n\n" + user]], tools: nil,
        additionalContext: args)
    }
  }

  /// The tokens every turn with this system prompt starts with: the longest common
  /// prefix of two renders whose user messages differ from their first character.
  func staticPrefixTokens(key: String, system: String, templateArgs: [String: any Sendable]) throws
    -> [Int]
  {
    if let cached = prefixTokenCache[key] { return cached }
    let a = try chatTokens(system: system, user: "A1", templateArgs: templateArgs)
    let b = try chatTokens(system: system, user: "Z9", templateArgs: templateArgs)
    let common = zip(a, b).prefix { $0 == $1 }.count
    let tokens = Array(a.prefix(common))
    prefixTokenCache[key] = tokens
    return tokens
  }

  // MARK: Forward passes

  /// Starts a turn: reuses (or builds) the static-prefix KV cache for `prefixKey`, then
  /// prefills the rest of `prompt`. Returns the logits after the last prompt token,
  /// whether the cached prefix was reused, and the prefill time (on a miss this includes
  /// building the prefix cache).
  func startTurn(
    prompt: [Int], prefixKey: String, prefixTokens: [Int], seed: UInt64,
    reasoningTemperature: Float,
    topP: Float, repetitionPenalty: Float
  ) throws -> (logits: Logits, prefixHit: Bool, prefillMs: Double) {
    let clock = ContinuousClock()
    let t0 = clock.now
    var hit = false
    var start = 0
    if !prefixTokens.isEmpty, prefixTokens.count < prompt.count, prompt.starts(with: prefixTokens) {
      if let index = prefixes.firstIndex(where: { $0.key == prefixKey && $0.tokens == prefixTokens }
      ) {
        let entry = prefixes.remove(at: index)
        prefixes.append(entry)
        hit = true
      } else {
        // Build and keep the prefix cache.
        let prefixCache = try context.model.newCache(parameters: nil)
        var prefixState: LMOutput.State?
        _ = try forward(prefixTokens, cache: prefixCache, state: &prefixState)
        eval(prefixCache.flatMap(\.state))
        prefixes.append(
          PrefixEntry(key: prefixKey, tokens: prefixTokens, cache: prefixCache, state: prefixState))
        if prefixes.count > Self.maxPrefixes { prefixes.removeFirst() }
      }
      let entry = prefixes[prefixes.count - 1]
      cache = entry.cache.map { $0.copy() }
      state = entry.state
      start = prefixTokens.count
    } else {
      cache = try context.model.newCache(parameters: nil)
      state = nil
    }

    var processor = RepetitionContext(
      repetitionPenalty: repetitionPenalty, repetitionContextSize: 64)
    processor.prompt(MLXArray(prompt[start...].map { Int32($0) }))
    self.processor = processor
    sampler = TopPSampler(temperature: reasoningTemperature, topP: topP, seed: seed)

    let logits = try forward(Array(prompt[start...]), cache: cache, state: &state)
    let ms = (clock.now - t0).milliseconds
    return (Logits(array: logits), hit, ms)
  }

  /// Feeds tokens after the current position and returns the logits after the last one.
  func feed(_ tokens: [Int]) throws -> Logits {
    Logits(array: try forward(tokens, cache: cache, state: &state))
  }

  /// Whether `trim(_:)` can remove tokens from the end of the turn cache.
  var canTrim: Bool { !cache.isEmpty && cache.allSatisfy(\.isTrimmable) }

  /// Removes the last `count` tokens from the turn cache.
  func trim(_ count: Int) {
    guard count > 0 else { return }
    for layer in cache { layer.trim(count) }
  }

  /// Restarts the turn cache from scratch with `tokens` (used when trimming is not
  /// possible, for example on hybrid attention / SSM models).
  func restart(with tokens: [Int]) throws -> Logits {
    cache = try context.model.newCache(parameters: nil)
    state = nil
    return try feed(tokens)
  }

  /// Samples one reasoning token: repetition penalty, then temperature + top-p.
  func sampleReasoningToken(_ logits: Logits) -> Int {
    var processed = processor?.process(logits: logits.array) ?? logits.array
    processed = processed.asType(.float32)
    let token = (sampler ?? TopPSampler(temperature: 0.3, topP: 0.9)).sample(logits: processed)
    processor?.didSample(token: token)
    return token.item(Int.self)
  }

  /// The seven digit logits (index = column) from a forward pass, unmasked.
  func digitLogits(_ logits: Logits) -> [Double] {
    let ids = MLXArray(digits.tokenIDs.map { Int32($0) })
    let picked = logits.array.asType(.float32).take(ids, axis: -1)
    return picked.asArray(Float.self).map(Double.init)
  }

  /// Ends a turn and drops its cache (the prefix cache is kept).
  func endTurn() {
    cache = []
    state = nil
    processor = nil
    sampler = nil
  }

  /// Runs the model over `tokens`, extending `cache`. Uses the model's own `prepare` so
  /// long inputs are chunked the way the library does it. Returns `[1, vocab]` logits.
  private func forward(_ tokens: [Int], cache: [KVCache], state: inout LMOutput.State?) throws
    -> MLXArray
  {
    precondition(!tokens.isEmpty)
    return try autoreleasepool {
      let input = LMInput(tokens: MLXArray(tokens.map { Int32($0) }))
      let remaining: LMInput.Text
      // A step size below the token count makes the model's prefill fill the cache for
      // all but the last token without running the LM head on them; the last token
      // then produces the only logits needed.
      let step = tokens.count > 1 ? min(tokens.count - 1, PrefillParameters.defaultStepSize) : nil
      let prefill = PrefillParameters(stepSize: step)
      switch try context.model.prepare(input, cache: cache, state: state, prefill: prefill) {
      case .tokens(let rest):
        remaining = rest
      case .logits(let output):
        state = output.state
        let logits = output.logits[0..., -1, 0...].asType(.float32)
        eval(logits)
        return logits
      }
      let output = context.model(remaining[text: .newAxis], cache: cache, state: state)
      state = output.state
      let logits = output.logits[0..., -1, 0...].asType(.float32)
      eval(logits)
      return logits
    }
  }
}
