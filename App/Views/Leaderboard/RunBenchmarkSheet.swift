import C4AI
import C4Bench
import C4Core
import SwiftUI

/// The Run benchmark sheet: choose what to run and see the estimate, then watch progress
/// with a live mini-board (§5.5).
struct RunBenchmarkSheet: View {
  @Bindable var model: BenchRunModel
  var store: BenchStore
  var onFinish: @MainActor @Sendable () -> Void

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      switch model.state {
      case .idle: setup
      case .running: running
      case .finished(let summary): finished(summary)
      case .failed(let message): failed(message)
      }
    }
    .frame(width: 560)
    .frame(minHeight: 380)
    .background(.background)
    .interactiveDismissDisabled(model.isRunning)
  }

  // MARK: Setup

  private var setup: some View {
    VStack(spacing: 0) {
      Form {
        Section("Models") {
          ForEach(model.models) { spec in
            Toggle(isOn: binding(for: spec.id)) {
              HStack {
                Text(spec.name)
                Spacer()
                Text(String(format: "%.1f GB", spec.sizeGB))
                  .monospacedDigit()
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
        Section("Configurations") {
          LabeledContent("Thinking styles") {
            HStack(spacing: DesignTokens.Spacing.m) {
              ForEach(ThinkingStyle.allCases) { style in
                Toggle(style.displayName, isOn: binding(style: style))
              }
            }
          }
          LabeledContent("Difficulties") {
            HStack(spacing: DesignTokens.Spacing.m) {
              ForEach(Difficulty.allCases) { difficulty in
                Toggle(difficulty.displayName, isOn: binding(difficulty: difficulty))
              }
            }
          }
          Picker("Prompt variant", selection: $model.variant) {
            ForEach(PromptVariant.all, id: \.id) { variant in
              Text(variant.id).tag(variant)
            }
          }
          Picker("Suite", selection: $model.preset) {
            Text("Quick").tag(SuitePreset.quick)
            Text("Standard").tag(SuitePreset.standard)
            Text("Full").tag(SuitePreset.full)
          }
          .pickerStyle(.segmented)
          Text(suiteCaption)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Section {
          estimateView
          Text(
            "Large runs take hours; the Mac stays awake. The game's model stays loaded, so prefer the c4bench command line tool for long runs."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          if model.useMock {
            Label("Mock model: no real LLM is loaded.", systemImage: "wand.and.stars")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .formStyle(.grouped)
      Divider()
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Start benchmark") {
          model.start(store: store, onFinish: onFinish)
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(model.contestants.isEmpty)
      }
      .padding(DesignTokens.Spacing.m)
    }
  }

  private var suiteCaption: String {
    switch model.preset {
    case .quick: String(localized: "Puzzles plus 14 games against each of 3 anchors.")
    case .standard: String(localized: "Puzzles plus 50 games against each of 5 anchors.")
    case .full:
      String(
        localized: "Standard plus a round robin between the selected models that fit in memory.")
    }
  }

  @ViewBuilder
  private var estimateView: some View {
    let contestants = model.contestants
    if contestants.isEmpty {
      Label(
        "Choose at least one model, style and difficulty.", systemImage: "exclamationmark.circle"
      )
      .foregroundStyle(.secondary)
    } else {
      let estimate = model.estimate(store: store)
      VStack(alignment: .leading, spacing: 2) {
        Text("Estimated time: \(estimate.durationText)")
          .font(.headline)
        Text(
          "\(contestants.count) configurations, \(estimate.gamesToPlay) games and \(estimate.puzzlesToAnswer) puzzles to play"
            + (estimate.gamesAlreadyDone > 0
              ? String(localized: ", \(estimate.gamesAlreadyDone) games already saved") : "")
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
      }
    }
  }

  private func binding(for modelID: String) -> Binding<Bool> {
    Binding(
      get: { model.selectedModelIDs.contains(modelID) },
      set: { on in
        if on {
          model.selectedModelIDs.insert(modelID)
        } else {
          model.selectedModelIDs.remove(modelID)
        }
      })
  }

  private func binding(style: ThinkingStyle) -> Binding<Bool> {
    Binding(
      get: { model.styles.contains(style) },
      set: { on in
        if on { model.styles.insert(style) } else { model.styles.remove(style) }
      })
  }

  private func binding(difficulty: Difficulty) -> Binding<Bool> {
    Binding(
      get: { model.difficulties.contains(difficulty) },
      set: { on in
        if on {
          model.difficulties.insert(difficulty)
        } else {
          model.difficulties.remove(difficulty)
        }
      })
  }

  // MARK: Running

  private var running: some View {
    VStack(spacing: DesignTokens.Spacing.m) {
      HStack(alignment: .top, spacing: DesignTokens.Spacing.l) {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
          Text("Benchmark running").font(.title3.weight(.semibold))
          Text(model.phaseText)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
          progressBar(
            title: "Games", done: model.progress?.gamesDone ?? 0,
            total: model.progress?.gamesTotal ?? 0)
          progressBar(
            title: "Puzzles", done: model.progress?.puzzlesDone ?? 0,
            total: model.progress?.puzzlesTotal ?? 0)
          if let eta = model.etaText {
            Label(eta, systemImage: "clock")
              .font(.callout)
              .foregroundStyle(.secondary)
              .contentTransition(.numericText())
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        MiniBoard(board: model.progress?.currentBoard)
      }
      Spacer(minLength: 0)
      Text(
        "Cancelling stops after the current move. Finished games and puzzle answers are kept, and starting the same suite again resumes where it stopped."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      Divider()
      HStack {
        Button("Hide") { dismiss() }
          .help("Keep running in the background")
        Spacer()
        Button("Cancel run", role: .cancel) { model.cancel() }
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(DesignTokens.Spacing.m)
  }

  private func progressBar(title: LocalizedStringKey, done: Int, total: Int) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title)
        Spacer()
        Text("\(done) of \(total)")
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      .font(.callout)
      ProgressView(value: Double(done), total: Double(max(total, 1)))
    }
  }

  // MARK: Done

  private func finished(_ summary: BenchSummary) -> some View {
    VStack(spacing: DesignTokens.Spacing.m) {
      ContentUnavailableView {
        Label(
          summary.cancelled ? "Benchmark cancelled" : "Benchmark finished",
          systemImage: summary.cancelled ? "stop.circle" : "checkmark.circle")
      } description: {
        VStack(spacing: 4) {
          Text(
            "\(summary.gamesPlayed) games and \(summary.puzzlesAnswered) puzzle answers saved this run."
          )
          .monospacedDigit()
          if summary.cancelled {
            Text("Everything finished is kept. Start the same suite again to resume.")
          }
          ForEach(summary.notes, id: \.self) { note in
            Text(note).font(.caption)
          }
        }
      }
      Divider()
      HStack {
        Spacer()
        Button("Done") {
          model.reset()
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
      .padding([.horizontal, .bottom], DesignTokens.Spacing.m)
    }
  }

  private func failed(_ message: String) -> some View {
    VStack(spacing: DesignTokens.Spacing.m) {
      ContentUnavailableView {
        Label("The benchmark stopped", systemImage: "exclamationmark.triangle")
      } description: {
        Text(message)
      }
      Divider()
      HStack {
        Spacer()
        Button("Back") { model.reset() }
        Button("Close") {
          model.reset()
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
      .padding([.horizontal, .bottom], DesignTokens.Spacing.m)
    }
  }
}

/// The game in progress, drawn with the game's own plate and discs at a small size.
struct MiniBoard: View {
  var board: Board?
  var cell: CGFloat = 24

  var body: some View {
    let metrics = BoardMetrics(cell: cell)
    let discs = board.map { PlacedDisc.all(on: $0) } ?? []
    ZStack(alignment: .topLeading) {
      ForEach(discs) { placed in
        DiscView(side: placed.disc == .first ? .human : .ai, diameter: metrics.discDiameter)
          .position(metrics.center(column: placed.cell.column, row: placed.cell.row))
      }
      BoardPlate(metrics: metrics)
    }
    .frame(width: metrics.plateSize.width, height: metrics.plateSize.height)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Current game, \(discs.count) moves played")
  }
}
