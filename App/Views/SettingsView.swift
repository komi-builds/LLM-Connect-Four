import C4AI
import SwiftUI

/// The Settings scene (⌘,): opponent, model, Deep think budget, and an About pane with the
/// honesty note from §4. Game settings are locked while a game is in progress.
struct SettingsView: View {
  @Bindable var game: GameViewModel

  var body: some View {
    TabView {
      Tab("Opponent", systemImage: "cpu") {
        OpponentSettings(game: game)
      }
      Tab("About", systemImage: "info.circle") {
        AboutPane()
      }
    }
    .frame(width: 560, height: 520)
  }
}

private struct OpponentSettings: View {
  @Bindable var game: GameViewModel
  @State private var customID = ""

  var body: some View {
    Form {
      if !game.canChangeSettings {
        Label("Finish or start a new game to change these.", systemImage: "lock")
          .foregroundStyle(.secondary)
      }

      Section {
        Picker("Play against", selection: $game.opponent) {
          Text("Language model").tag(GameViewModel.Opponent.model)
          Text("Minimax engine").tag(GameViewModel.Opponent.engine)
        }
        .pickerStyle(.segmented)
      } footer: {
        Text(
          "The engine is a non-LLM reference: depth 2, 4 or 7 for Easy, Moderate and Hard."
        )
        .foregroundStyle(.secondary)
      }

      Section("Model") {
        Picker("Model", selection: $game.selectedModelID) {
          ForEach(game.models) { model in
            ModelRow(model: model).tag(Optional(model.id))
          }
        }
        .pickerStyle(.inline)
        .labelsHidden()

        if let model = game.selectedModel {
          MemoryNote(model: model)
        }

        HStack {
          TextField("Custom model", text: $customID, prompt: Text("mlx-community/…"))
            .onSubmit(addCustom)
          Button("Add", action: addCustom)
            .disabled(!isValidCustomID)
        }
      }
      .disabled(game.opponent == .engine)

      Section {
        LabeledContent("Deep think budget") {
          HStack {
            Slider(
              value: budgetBinding,
              in: Double(
                ThinkingStyle.deepThinkBudgetRange.lowerBound)...Double(
                  ThinkingStyle.deepThinkBudgetRange.upperBound),
              step: 64)
            Text("\(game.deepThinkBudget) tokens")
              .monospacedDigit()
              .frame(width: 92, alignment: .trailing)
          }
        }
      } footer: {
        Text(
          game.canDeepThink
            ? "More thinking tokens can find better moves but take longer. About 25 ms per token on an M3 Pro."
            : "\(game.selectedModel?.name ?? "This model") has no native thinking, so Deep think isn't offered."
        )
        .foregroundStyle(.secondary)
      }
      .disabled(!game.canDeepThink || game.opponent == .engine)
    }
    .formStyle(.grouped)
    .disabled(!game.canChangeSettings)
  }

  private var budgetBinding: Binding<Double> {
    Binding(
      get: { Double(game.deepThinkBudget) },
      set: { game.deepThinkBudget = Int($0) })
  }

  private var trimmedID: String { customID.trimmingCharacters(in: .whitespaces) }

  /// A Hugging Face repo id: `owner/name`, not already listed.
  private var isValidCustomID: Bool {
    let parts = trimmedID.split(separator: "/")
    return parts.count == 2 && !parts.contains { $0.isEmpty || $0.contains(" ") }
      && !game.models.contains { $0.id == trimmedID }
  }

  private func addCustom() {
    guard isValidCustomID else { return }
    game.customModelIDs.append(trimmedID)
    game.selectedModelID = trimmedID
    customID = ""
  }
}

private struct ModelRow: View {
  var model: ModelSpec

  var body: some View {
    HStack {
      Text(model.name)
      if model.thinking {
        Text("thinks")
          .font(.caption)
          .padding(.horizontal, 6)
          .padding(.vertical, 1)
          .background(.quaternary, in: .capsule)
      }
      Spacer()
      Text(model.sizeGB > 0 ? String(format: "%.1f GB", model.sizeGB) : "custom")
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
  }
}

/// Warns above 40% of RAM; the provider refuses above 60% (§12).
private struct MemoryNote: View {
  var model: ModelSpec

  var body: some View {
    switch model.memoryVerdict() {
    case .ok:
      EmptyView()
    case .warn:
      Label(
        "\(model.name) uses more than 40% of this Mac's memory. Close other apps, or pick a smaller model.",
        systemImage: "exclamationmark.triangle"
      )
      .foregroundStyle(.orange)
    case .refuse:
      Label(
        "\(model.name) needs more than 60% of this Mac's memory, so it won't load here.",
        systemImage: "xmark.octagon"
      )
      .foregroundStyle(.red)
    }
  }
}

private struct AboutPane: View {
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        Text("LLM Connect Four")
          .font(.title2.weight(.semibold))
        Text(
          "Play Connect Four against a language model running entirely on your Mac with MLX, and watch it think. No cloud, no API key."
        )
        Text("How the model plays")
          .font(.headline)
        Text(
          "Every move really comes from the model. It reads the board, optionally reasons, and then the app writes \"Column: \" and lets it pick only from the legal columns. Difficulty changes how much help the prompt gives and how freely the answer is sampled, never who decides."
        )
        Text("A note on honesty")
          .font(.headline)
        Text(
          "The reasoning you see is the model's own text, and it comes before the answer, so it can influence the choice. It is not a guaranteed explanation of why the model chose a column. The confidence bars, read straight from the model's probabilities, are the more objective signal."
        )
        Text("Credits")
          .font(.headline)
        Text(
          "Built on MLX and mlx-swift-lm by Apple's machine learning research team. Visual inspiration from liquid-glass-js and liquidGL. MIT License."
        )
        .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(24)
    }
  }
}
