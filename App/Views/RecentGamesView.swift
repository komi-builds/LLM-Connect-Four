import C4AI
import C4Core
import SwiftUI

/// "Recent Games": the saved games on the left, the selected one in the replay on the right.
struct RecentGamesView: View {
  var store: GameStore

  @State private var records: [GameRecord] = []
  @State private var selection: UUID?
  @State private var isLoaded = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    HStack(spacing: 0) {
      Group {
        if records.isEmpty {
          emptyState
        } else {
          list
        }
      }
      .frame(width: 280)
      Divider()
      if let record = records.first(where: { $0.id == selection }) {
        ReplayView(record: record)
      } else {
        VStack {
          HStack {
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
          }
          .padding(DesignTokens.Spacing.m)
          Spacer()
          Text("Select a game to replay it.")
            .foregroundStyle(.secondary)
          Spacer()
        }
        .frame(maxWidth: .infinity)
      }
    }
    .frame(minWidth: 1140, minHeight: 640)
    .task {
      let store = store
      records = await Task.detached { store.list() }.value
      selection = records.first?.id
      isLoaded = true
    }
  }

  private var list: some View {
    List(selection: $selection) {
      ForEach(records) { record in
        RecentGameRow(record: record)
          .tag(record.id)
          .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) { delete(record) }
          }
      }
    }
    .listStyle(.sidebar)
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label(isLoaded ? "No games yet" : "Loading…", systemImage: "clock.arrow.circlepath")
    } description: {
      if isLoaded { Text("Finished games are saved here, so you can replay them.") }
    }
  }

  private func delete(_ record: GameRecord) {
    try? store.delete(id: record.id)
    records.removeAll { $0.id == record.id }
    if selection == record.id { selection = records.first?.id }
  }
}

private struct RecentGameRow: View {
  var record: GameRecord

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.s) {
      resultMark
        .frame(width: 30)
      VStack(alignment: .leading, spacing: 2) {
        Text(record.resultTitle).font(.callout.weight(.medium)).lineLimit(1)
        Text(
          "\(record.style.displayName) · \(record.difficulty.displayName) · \(record.moves.count) moves"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        Text(record.startedAt, format: .dateTime.month().day().hour().minute())
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var resultMark: some View {
    switch record.outcome {
    case .win(let disc): DiscView(side: disc == record.humanDisc ? .human : .ai, diameter: 22)
    case .draw:
      HStack(spacing: -8) {
        DiscView(side: .human, diameter: 16)
        DiscView(side: .ai, diameter: 16)
      }
    case nil:
      Image(systemName: "flag.slash").foregroundStyle(.secondary)
    }
  }
}
