import C4AI
import C4Bench
import C4Core
import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.komi.LLMConnectFour", category: "bench")

/// Where the leaderboard reads benchmark data from. The app is sandboxed, so the default
/// folder is inside the app container; a folder chosen by the user (for example the one the
/// `c4bench` CLI writes to) is remembered as a security-scoped bookmark.
enum BenchFolder {
  static let defaultsKey = "benchFolderBookmark"

  /// The folder to use if the user picked its parent (`LLMConnectFour`) instead of `bench`.
  static func normalized(_ url: URL) -> URL {
    let fm = FileManager.default
    func hasData(_ folder: URL) -> Bool {
      fm.fileExists(atPath: folder.appendingPathComponent("games").path)
        || fm.fileExists(atPath: folder.appendingPathComponent("puzzles").path)
    }
    if hasData(url) { return url }
    let nested = url.appendingPathComponent("bench", isDirectory: true)
    return hasData(nested) ? nested : url
  }

  static func save(_ url: URL, defaults: UserDefaults = .standard) {
    do {
      let data = try url.bookmarkData(
        options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
      defaults.set(data, forKey: defaultsKey)
    } catch {
      log.error("could not bookmark bench folder: \(error.localizedDescription, privacy: .public)")
    }
  }

  static func clear(defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: defaultsKey)
  }

  /// The remembered folder, with security-scoped access started (kept for the app's life).
  static func resolve(defaults: UserDefaults = .standard) -> URL? {
    guard let data = defaults.data(forKey: defaultsKey) else { return nil }
    var stale = false
    guard
      let url = try? URL(
        resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
        bookmarkDataIsStale: &stale)
    else { return nil }
    _ = url.startAccessingSecurityScopedResource()
    if stale { save(url, defaults: defaults) }
    return url
  }
}

/// Loads benchmark data off the main actor and keeps the table's state: filters, sorting and
/// the selected row.
@MainActor
@Observable
final class LeaderboardModel {
  private(set) var store: BenchStore
  private(set) var games: [BenchGame] = []
  private(set) var puzzles: [PuzzleAttempt] = []
  /// Every contestant in rating order, anchors included.
  private(set) var allRows: [LeaderboardRow] = []
  private(set) var machines: [MachineInfo] = []
  private(set) var isLoading = false
  private(set) var hasLoaded = false

  /// Speed columns use only games from this machine (`speedKey`); nil means all machines.
  var machineKey: String? {
    didSet { if oldValue != machineKey { Task { await recompute() } } }
  }
  var showAnchors = true
  var searchText = ""
  var sortOrder = [LeaderboardComparator(column: .rank)]

  @ObservationIgnored private var generation = 0
  @ObservationIgnored private let defaults: UserDefaults

  /// Folder shown in the UI when it is not the default.
  private(set) var customFolder: URL?

  init(store: BenchStore? = nil, defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let store {
      self.store = store
    } else if let folder = BenchFolder.resolve(defaults: defaults) {
      let normalized = BenchFolder.normalized(folder)
      customFolder = normalized
      self.store = BenchStore(directory: normalized)
    } else {
      self.store = BenchStore()
    }
  }

  var folderDescription: String {
    customFolder?.abbreviatedPath ?? String(localized: "App container (default)")
  }

  /// Rows after the anchor toggle, the search field and the sort order.
  var visibleRows: [LeaderboardRow] {
    var rows = allRows
    if !showAnchors { rows = rows.filter { !$0.isAnchor } }
    let query = searchText.trimmingCharacters(in: .whitespaces)
    if !query.isEmpty { rows = rows.filter { $0.name.localizedCaseInsensitiveContains(query) } }
    return rows.sorted(using: sortOrder)
  }

  var selectedMachine: MachineInfo? {
    machineKey.flatMap { key in machines.first { $0.speedKey == key } }
  }

  func detail(for rowID: String) -> ContestantDetail {
    ContestantDetail.make(contestantID: rowID, games: games, puzzles: puzzles)
  }

  // MARK: Loading

  /// Reads games and puzzle attempts from disk and recomputes every row.
  func reload() async {
    generation += 1
    let mine = generation
    isLoading = true
    let store = store
    let machine = selectedMachine
    let loaded = await Task.detached(priority: .userInitiated) { () -> Loaded in
      let games = store.loadGames()
      let puzzles = store.loadPuzzleAttempts()
      let rows = Leaderboard.compute(games: games, puzzles: puzzles, machine: machine)
      return Loaded(games: games, puzzles: puzzles, rows: rows)
    }.value
    guard mine == generation else { return }
    apply(loaded)
    isLoading = false
    hasLoaded = true
  }

  /// Recomputes from the games already in memory (a machine filter change).
  func recompute() async {
    guard hasLoaded else { return }
    generation += 1
    let mine = generation
    isLoading = true
    let games = games
    let puzzles = puzzles
    let machine = selectedMachine
    let rows = await Task.detached(priority: .userInitiated) {
      Leaderboard.compute(games: games, puzzles: puzzles, machine: machine)
    }.value
    guard mine == generation else { return }
    allRows = LeaderboardRanks.rows(rows)
    isLoading = false
  }

  private struct Loaded: Sendable {
    var games: [BenchGame]
    var puzzles: [PuzzleAttempt]
    var rows: [RatingRow]
  }

  private func apply(_ loaded: Loaded) {
    games = loaded.games
    puzzles = loaded.puzzles
    machines = MachineInfo.distinct(in: loaded.games)
    if let key = machineKey, !machines.contains(where: { $0.speedKey == key }) {
      machineKey = nil
    }
    allRows = LeaderboardRanks.rows(loaded.rows)
  }

  // MARK: Folder

  func useFolder(_ picked: URL) async {
    _ = picked.startAccessingSecurityScopedResource()
    let folder = BenchFolder.normalized(picked)
    BenchFolder.save(picked, defaults: defaults)
    customFolder = folder
    store = BenchStore(directory: folder)
    machineKey = nil
    await reload()
  }

  func useDefaultFolder() async {
    BenchFolder.clear(defaults: defaults)
    customFolder = nil
    store = BenchStore()
    machineKey = nil
    await reload()
  }

  /// Replaces the store (tests and demo data).
  func use(store: BenchStore) async {
    self.store = store
    await reload()
  }
}

extension URL {
  fileprivate var abbreviatedPath: String {
    (path as NSString).abbreviatingWithTildeInPath
  }
}
