import C4AI
import C4Bench
import C4Core
import C4MLX
import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.komi.LLMConnectFour", category: "bench")

/// The state behind the Run benchmark sheet: what to run, the estimate, and the live run.
@MainActor
@Observable
final class BenchRunModel {
  enum State {
    case idle
    case running
    case finished(BenchSummary)
    case failed(String)
  }

  let models: [ModelSpec]
  var selectedModelIDs: Set<String>
  var styles: Set<ThinkingStyle> = [.explain]
  var difficulties: Set<Difficulty> = [.moderate]
  var variant = PromptVariant.default
  var preset = SuitePreset.quick

  private(set) var state = State.idle
  private(set) var progress: BenchProgress?

  /// True for `-mockModel YES`: runs use `MockMoveProvider` instead of loading an LLM.
  let useMock: Bool
  /// Pace of the mock's streamed tokens; the demo slows it so a run can be photographed.
  var mockTokenDelay = Duration.milliseconds(4)
  @ObservationIgnored private var task: Task<Void, Never>?

  init(
    models: [ModelSpec] = ModelRegistry.bundled(),
    useMock: Bool = UserDefaults.standard.bool(forKey: "mockModel")
  ) {
    self.models = models
    self.useMock = useMock
    selectedModelIDs = Set(
      (models.first(where: \.isDefault) ?? models.first).map { [$0.id] } ?? [])
  }

  var isRunning: Bool {
    if case .running = state { return true }
    return false
  }

  /// Model × style × difficulty, skipping Deep think for models that cannot think.
  var contestants: [Contestant] {
    var out: [Contestant] = []
    for model in models where selectedModelIDs.contains(model.id) {
      for style in ThinkingStyle.allCases where styles.contains(style) {
        if style == .deepThink && !model.thinking { continue }
        for difficulty in Difficulty.allCases where difficulties.contains(difficulty) {
          out.append(
            Contestant(
              kind: .llm(
                modelID: model.id, style: style, difficulty: difficulty, variantID: variant.id),
              modelName: model.name))
        }
      }
    }
    return out
  }

  func configuration(machine: MachineInfo = .current) -> BenchConfiguration {
    BenchConfiguration(
      preset: preset, contestants: contestants, models: models, machine: machine)
  }

  func estimate(store: BenchStore) -> BenchEstimate {
    BenchEstimate.make(configuration: configuration(), store: store)
  }

  /// The provider factory for a run: the mock under `-mockModel YES`, otherwise MLX.
  func providers() -> ProviderFactory {
    let models = models
    let useMock = useMock
    let delay = mockTokenDelay
    return BenchProviders.standard(llm: { modelID in
      let spec = models.first { $0.id == modelID }
      if useMock {
        return MockMoveProvider(
          name: spec?.name ?? "Mock Model", tokenDelay: delay,
          loadDuration: .milliseconds(300))
      }
      return LLMMoveProvider(
        spec: spec ?? ModelSpec(id: modelID, name: modelID, sizeGB: 0, thinking: false))
    })
  }

  func start(store: BenchStore, onFinish: @escaping @MainActor @Sendable () -> Void) {
    guard !isRunning else { return }
    let runner = BenchRunner(
      configuration: configuration(), store: store, providers: providers())
    state = .running
    progress = nil
    let (stream, continuation) = AsyncStream<BenchProgress>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    let worker = Task.detached(priority: .userInitiated) { () -> Result<BenchSummary, any Error> in
      defer { continuation.finish() }
      do {
        return .success(try await runner.run(progress: { continuation.yield($0) }))
      } catch {
        return .failure(error)
      }
    }
    task = Task { [weak self] in
      for await update in stream { self?.progress = update }
      let result = await withTaskCancellationHandler {
        await worker.value
      } onCancel: {
        worker.cancel()
      }
      guard let self else { return }
      switch result {
      case .success(let summary):
        log.info("bench finished: \(summary.gamesPlayed) games, cancelled \(summary.cancelled)")
        state = .finished(summary)
      case .failure(let error):
        log.error("bench failed: \(String(describing: error), privacy: .public)")
        state = .failed(String(describing: error))
      }
      task = nil
      onFinish()
    }
  }

  /// Stops after the current move. Everything finished is already on disk.
  func cancel() {
    task?.cancel()
  }

  func reset() {
    if !isRunning {
      state = .idle
      progress = nil
    }
  }

  // MARK: Progress text

  var phaseText: String {
    guard let progress else { return String(localized: "Starting…") }
    switch progress.phase {
    case .loading(let model, let fraction):
      return String(localized: "Loading \(model) (\(Int(fraction * 100))%)")
    case .puzzles(let contestant):
      return contestant.isEmpty
        ? (progress.message ?? "") : String(localized: "Puzzles: \(contestant)")
    case .game(let first, let second):
      return String(localized: "Game: \(first) vs \(second)")
    case .finished:
      return String(localized: "Finished")
    }
  }

  var etaText: String? {
    guard let seconds = progress?.etaSeconds else { return nil }
    let minutes = Int((seconds / 60).rounded(.up))
    if seconds < 60 { return String(localized: "under a minute left") }
    if minutes < 60 { return String(localized: "about \(minutes) min left") }
    let rest = minutes % 60
    return String(localized: "about \(minutes / 60) h \(rest) min left")
  }
}
