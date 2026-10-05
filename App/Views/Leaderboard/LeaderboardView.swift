import C4AI
import C4Bench
import C4Core
import SwiftUI
import UniformTypeIdentifiers

/// The Leaderboard window (§5.5, §6): a native sortable table on the standard window
/// background. Only the toolbar is glass, which the system does by itself.
struct LeaderboardView: View {
  @State private var model: LeaderboardModel
  @State private var run: BenchRunModel
  @State private var selection: String?
  @State private var showInspector = false
  @State private var showRunSheet = false
  @State private var showFolderPicker = false
  @State private var replay: ReplayItem?
  @State private var export = ExportRequest()

  init(model: LeaderboardModel = LeaderboardModel(), run: BenchRunModel = BenchRunModel()) {
    _model = State(initialValue: model)
    _run = State(initialValue: run)
  }

  var body: some View {
    @Bindable var model = model
    content
      .frame(minWidth: 760, minHeight: 440)
      .background(.background)
      .navigationTitle("Leaderboard")
      .navigationSubtitle(subtitle)
      .searchable(text: $model.searchText, placement: .toolbar, prompt: "Filter contestants")
      .toolbar { toolbar }
      .inspector(isPresented: $showInspector) { inspector }
      .inspectorColumnWidth(min: 300, ideal: 360, max: 480)
      .task { await model.reload() }
      .onChange(of: selection) { _, new in showInspector = new != nil }
      .onChange(of: showInspector) { _, shown in if !shown { selection = nil } }
      .sheet(isPresented: $showRunSheet) {
        RunBenchmarkSheet(model: run, store: model.store) {
          Task { await model.reload() }
        }
      }
      .sheet(item: $replay) { item in
        ReplayView(record: item.record, labels: item.labels, initialPly: item.initialPly)
      }
      .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
        if case .success(let url) = result { Task { await model.useFolder(url) } }
      }
      .fileExporter(
        isPresented: $export.isPresented, document: export.document,
        contentType: export.contentType, defaultFilename: export.filename
      ) { _ in }
      #if DEBUG
        .task { await DemoLeaderboard.run(model: model, run: run, show: demoHooks) }
      #endif
  }

  #if DEBUG
    private var demoHooks: DemoLeaderboard.Hooks {
      DemoLeaderboard.Hooks(
        select: { selection = $0 },
        showRunSheet: { showRunSheet = true },
        openGame: { replay = ReplayItem(game: $0, ply: nil) })
    }
  #endif

  private var subtitle: String {
    guard model.hasLoaded else { return "" }
    let contestants = model.allRows.filter { !$0.isAnchor }.count
    return String(localized: "\(contestants) models · \(model.games.count) games")
  }

  // MARK: Content

  @ViewBuilder
  private var content: some View {
    if !model.hasLoaded {
      ProgressView("Computing ratings…")
        .controlSize(.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if model.allRows.isEmpty {
      emptyState
    } else {
      table
        .overlay(alignment: .bottom) { footer }
    }
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label("No benchmark results yet", systemImage: "chart.bar.xaxis")
    } description: {
      Text(
        "The benchmark plays each model against fixed Random and Minimax opponents and rates it on one scale. Runs started here save into \(model.folderDescription). Results from the c4bench command line tool are in your real Application Support folder, outside this app's sandbox: choose that bench folder to see them."
      )
    } actions: {
      Button("Run benchmark…") { showRunSheet = true }
        .buttonStyle(.borderedProminent)
      Button("Open bench folder…") { showFolderPicker = true }
    }
  }

  private var footer: some View {
    HStack(spacing: DesignTokens.Spacing.s) {
      if model.isLoading {
        ProgressView().controlSize(.small)
        Text("Recomputing…")
      } else {
        Text(footerText)
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, DesignTokens.Spacing.m)
    .padding(.vertical, DesignTokens.Spacing.xs)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.bar)
  }

  private var footerText: String {
    let machine = model.selectedMachine?.label ?? String(localized: "all machines")
    return String(localized: "Speed columns: \(machine). Ratings use all games, Minimax d2 = 1000.")
      + " " + String(localized: "= marks a tie with the row above.")
  }

  // MARK: Table

  private var table: some View {
    @Bindable var model = model
    return Table(model.visibleRows, selection: $selection, sortOrder: $model.sortOrder) {
      Group {
        TableColumn(
          String(localized: LeaderboardColumn.rank.title),
          sortUsing: LeaderboardComparator(column: .rank)
        ) { row in
          cell(.rank, row)
        }
        .width(min: 48, ideal: 52, max: 64)
        .alignment(.numeric)

        TableColumn(
          String(localized: LeaderboardColumn.contestant.title),
          sortUsing: LeaderboardComparator(column: .contestant)
        ) { row in
          contestantCell(row)
        }
        .width(min: 190, ideal: 225)

        numericColumn(.rating, width: 90)
        numericColumn(.puzzles, width: 66)
        numericColumn(.winVsD4, width: 78)
        numericColumn(.blunders, width: 94)
      }
      Group {
        numericColumn(.illegal, width: 112)
        numericColumn(.medianMove, width: 78)
        numericColumn(.tokensPerSecond, width: 52)
        numericColumn(.loadTime, width: 68)
        numericColumn(.peakRAM, width: 68)
        numericColumn(.size, width: 58)
      }
    }
    .tableStyle(.inset(alternatesRowBackgrounds: true))
    .safeAreaPadding(.bottom, 24)
    .contextMenu(forSelectionType: String.self) { _ in
    } primaryAction: { ids in
      selection = ids.first
    }
  }

  private func numericColumn(_ column: LeaderboardColumn, width: CGFloat)
    -> some TableColumnContent<
      LeaderboardRow, LeaderboardComparator
    >
  {
    TableColumn(String(localized: column.title), sortUsing: LeaderboardComparator(column: column)) {
      row in
      cell(column, row)
    }
    .width(min: width * 0.8, ideal: width)
    .alignment(.numeric)
  }

  @ViewBuilder
  private func cell(_ column: LeaderboardColumn, _ row: LeaderboardRow) -> some View {
    if let text = column.text(row) {
      Text(text)
        .monospacedDigit()
        .foregroundStyle(row.isAnchor ? .secondary : .primary)
        .help(tooltip(column, row))
    } else {
      Text("n/a")
        .foregroundStyle(.tertiary)
    }
  }

  private func tooltip(_ column: LeaderboardColumn, _ row: LeaderboardRow) -> String {
    let r = row.row
    switch column {
    case .puzzles:
      let parts = PuzzleCategory.allCases.compactMap { category -> String? in
        r.puzzleAccuracy[category.rawValue].map {
          "\(category.title): \(Int(($0 * 100).rounded()))%"
        }
      }
      return parts.joined(separator: "\n")
    case .rating:
      return String(
        localized:
          "\(Int(r.rating.rounded())), 95% interval \(Int(r.ciLow.rounded())) to \(Int(r.ciHigh.rounded()))"
      )
    case .rank:
      return String(
        localized: "\(r.games) games: \(r.wins) won, \(r.draws) drawn, \(r.losses) lost")
    default:
      return ""
    }
  }

  private func contestantCell(_ row: LeaderboardRow) -> some View {
    HStack(spacing: DesignTokens.Spacing.s) {
      Text(row.name)
        .foregroundStyle(row.isAnchor ? .secondary : .primary)
        .lineLimit(1)
        .truncationMode(.tail)
      if row.isAnchor {
        Text("anchor")
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 1)
          .background(.quaternary, in: Capsule())
      }
    }
  }

  // MARK: Inspector

  @ViewBuilder
  private var inspector: some View {
    if let id = selection, let row = model.allRows.first(where: { $0.id == id }) {
      ContestantDetailView(
        row: row, detail: model.detail(for: id),
        onOpenGame: { replay = ReplayItem(game: $0, ply: $1) }
      )
      .id(id)
    } else {
      ContentUnavailableView("Select a contestant", systemImage: "sidebar.right")
    }
  }

  // MARK: Toolbar

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    @Bindable var model = model
    ToolbarItemGroup(placement: .primaryAction) {
      Button {
        showRunSheet = true
      } label: {
        if run.isRunning {
          Label("Benchmark running", systemImage: "hourglass")
        } else {
          Label("Run benchmark", systemImage: "play.fill")
        }
      }
      .help(run.isRunning ? "Show the running benchmark" : "Choose models and run the benchmark")
      Button("Refresh", systemImage: "arrow.clockwise") {
        Task { await model.reload() }
      }
      .keyboardShortcut("r")
      .disabled(model.isLoading)
      .help("Reload results from disk and recompute ratings")
    }
    ToolbarItemGroup {
      Picker("Machine", selection: $model.machineKey) {
        Text("All machines").tag(String?.none)
        if !model.machines.isEmpty { Divider() }
        ForEach(model.machines, id: \.speedKey) { machine in
          Text(machine.label).tag(Optional(machine.speedKey))
        }
      }
      .pickerStyle(.menu)
      .help("Speed columns use only games played on this machine")
      Toggle("Show anchors", systemImage: "scope", isOn: $model.showAnchors)
        .help("Show or hide the Random and Minimax anchors")
    }
    ToolbarItemGroup {
      Menu("Export", systemImage: "square.and.arrow.up") {
        ForEach(ReportFormat.allCases, id: \.self) { format in
          Button(format.menuTitle) { prepareExport(format) }
        }
      }
      .disabled(model.allRows.isEmpty)
      .help("Export the leaderboard")
      Menu("Data folder", systemImage: "folder") {
        Text(model.folderDescription)
        Divider()
        Button("Open bench folder…") { showFolderPicker = true }
        Button("Use default folder") { Task { await model.useDefaultFolder() } }
          .disabled(model.customFolder == nil)
      }
      .help("Choose where benchmark results are read from")
    }
  }

  private func prepareExport(_ format: ReportFormat) {
    let rows = model.allRows.map(\.row)
    let text = ReportWriter.render(rows, format: format, machine: model.selectedMachine)
    export.document = ReportDocument(text: text, format: format)
    export.contentType = format.contentType
    export.isPresented = true
  }
}

extension ReportFormat {
  var contentType: UTType {
    switch self {
    case .md: ReportDocument.markdown
    case .csv: .commaSeparatedText
    case .json: .json
    }
  }

  fileprivate var menuTitle: LocalizedStringKey {
    switch self {
    case .md: "Markdown (.md)"
    case .csv: "CSV (.csv)"
    case .json: "JSON (.json)"
    }
  }
}

extension PuzzleCategory {
  /// "Win in 1", "Block in 1", "Avoid the blunder", "Win in 3".
  var title: String {
    switch self {
    case .winIn1: String(localized: "Win in 1")
    case .blockIn1: String(localized: "Block in 1")
    case .avoidBlunder: String(localized: "Avoid the blunder")
    case .winIn3: String(localized: "Win in 3")
    }
  }

  var shortTitle: String {
    switch self {
    case .winIn1: "W1"
    case .blockIn1: "B1"
    case .avoidBlunder: "AV"
    case .winIn3: "W3"
    }
  }
}

/// A benchmark game queued for the replay sheet.
struct ReplayItem: Identifiable {
  var record: GameRecord
  var labels: ReplayLabels
  var initialPly: Int
  var id: UUID { record.id }

  init(game: BenchGame, ply: Int? = nil) {
    initialPly = ply ?? 0
    let converted = game.replayRecord()
    record = converted.record
    labels = converted.labels
  }
}

struct ExportRequest {
  var isPresented = false
  var document: ReportDocument?
  var filename = "leaderboard"
  var contentType = UTType.plainText
}

/// The leaderboard as a text file, in the format `ReportWriter` renders.
struct ReportDocument: FileDocument {
  static let markdown = UTType("net.daringfireball.markdown") ?? .plainText
  static var readableContentTypes: [UTType] { [.plainText] }
  static var writableContentTypes: [UTType] { [markdown, .commaSeparatedText, .json] }

  var text: String
  var format: ReportFormat

  init(text: String, format: ReportFormat) {
    self.text = text
    self.format = format
  }

  init(configuration: ReadConfiguration) throws {
    text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    format = .md
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: Data(text.utf8))
  }
}
