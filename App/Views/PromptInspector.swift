import AppKit
import C4AI
import C4Core
import SwiftUI

/// "What the model sees" (§4): the exact system and per-turn prompt of one move, monospaced
/// and selectable. The facts the prompt builder added are highlighted in the user message.
struct PromptInspector: View {
  var prompt: Prompt
  var subtitle: String

  @Environment(\.dismiss) private var dismiss
  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
          metadata
          InspectorSection("This turn", trailing: Text("\(prompt.facts.count) facts")) {
            promptText(PromptHighlight.attributed(prompt.user, facts: prompt.facts))
          }
          if !prompt.facts.isEmpty { legend }
          InspectorSection("System prompt", trailing: Text(sharedNote)) {
            promptText(AttributedString(prompt.system))
          }
        }
        .padding(DesignTokens.Spacing.m)
      }
      .scrollContentBackground(.hidden)
    }
    .frame(minWidth: 520, idealWidth: 620, minHeight: 440, idealHeight: 640)
    .background(.background)
  }

  private var sharedNote: String {
    String(localized: "Same for every move of a game")
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.s) {
      VStack(alignment: .leading, spacing: 2) {
        Label("What the model sees", systemImage: "eye")
          .font(.title3.weight(.semibold))
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
        copy()
      }
      .controlSize(.regular)
      Button("Done") { dismiss() }
        .keyboardShortcut(.defaultAction)
    }
    .padding(DesignTokens.Spacing.m)
  }

  private var metadata: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
      HStack(spacing: DesignTokens.Spacing.m) {
        MetaItem(title: "Prompt version", value: "v\(prompt.version)")
        MetaItem(title: "Variant", value: prompt.variantID)
      }
      HStack(spacing: DesignTokens.Spacing.s) {
        Text("Allowed columns")
          .font(.caption)
          .foregroundStyle(.secondary)
        ForEach(prompt.allowedColumns, id: \.self) { column in
          Text("\(column + 1)")
            .font(.caption.weight(.semibold).monospacedDigit())
            .frame(width: 22, height: 22)
            .background(Circle().fill(DesignTokens.Colors.ai.opacity(0.22)))
            .foregroundStyle(DesignTokens.Colors.aiText)
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(
        Text(
          "Allowed columns: \(prompt.allowedColumns.map { String($0 + 1) }.joined(separator: ", "))"
        )
      )
    }
  }

  private var legend: some View {
    HStack(spacing: DesignTokens.Spacing.xs) {
      RoundedRectangle(cornerRadius: 3)
        .fill(DesignTokens.Colors.factHighlight)
        .frame(width: 18, height: 12)
      Text("Highlighted text is a fact the app added to the prompt.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func promptText(_ text: AttributedString) -> some View {
    Text(text)
      .font(.system(.callout, design: .monospaced))
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(DesignTokens.Spacing.s + 2)
      .background(.background.secondary, in: .rect(cornerRadius: DesignTokens.Radius.small))
  }

  private func copy() {
    let text = "SYSTEM\n\(prompt.system)\n\nUSER\n\(prompt.user)\n"
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    copied = true
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      copied = false
    }
  }
}

private struct MetaItem: View {
  var title: LocalizedStringKey
  var value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.callout.monospaced()).textSelection(.enabled)
    }
    .accessibilityElement(children: .combine)
  }
}
