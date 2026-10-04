import C4AI
import C4Core
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Saves played games as JSON files and keeps the most recent ones (§4, §12).
///
/// One file per game, `<id>.json`, in `Application Support/LLMConnectFour/games/`. The app is
/// sandboxed, so that folder lives inside the container. Files are small, so the store is
/// synchronous and simple; callers on the main actor write one file at the end of a game.
struct GameStore: Sendable {
  static let defaultLimit = 200

  var directory: URL
  var limit: Int

  init(directory: URL, limit: Int = GameStore.defaultLimit) {
    self.directory = directory
    self.limit = limit
  }

  /// The app's own store in Application Support.
  static var `default`: GameStore {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return GameStore(
      directory: base.appendingPathComponent("LLMConnectFour", isDirectory: true)
        .appendingPathComponent("games", isDirectory: true))
  }

  // MARK: Coding

  static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  /// The JSON for one game, as saved and as exported.
  static func data(for record: GameRecord) throws -> Data {
    try makeEncoder().encode(record)
  }

  static func record(from data: Data) throws -> GameRecord {
    try makeDecoder().decode(GameRecord.self, from: data)
  }

  // MARK: Save, load, prune

  private func url(for id: UUID) -> URL {
    directory.appendingPathComponent("\(id.uuidString).json")
  }

  /// Writes (or overwrites) the game, then prunes to the newest `limit` games.
  func save(_ record: GameRecord) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Self.data(for: record).write(to: url(for: record.id), options: .atomic)
    try prune()
  }

  /// All saved games, newest first. Unreadable files are skipped.
  func list() -> [GameRecord] {
    let decoder = Self.makeDecoder()
    return files().compactMap { file in
      (try? Data(contentsOf: file)).flatMap { try? decoder.decode(GameRecord.self, from: $0) }
    }
    .sorted(by: Self.newerFirst)
  }

  func load(id: UUID) -> GameRecord? {
    (try? Data(contentsOf: url(for: id))).flatMap { try? Self.record(from: $0) }
  }

  func delete(id: UUID) throws {
    try FileManager.default.removeItem(at: url(for: id))
  }

  /// Removes the oldest games beyond `limit`.
  func prune() throws {
    struct Header: Decodable { var startedAt: Date }
    let decoder = Self.makeDecoder()
    let dated: [(URL, Date)] = files().map { file in
      let date =
        (try? Data(contentsOf: file)).flatMap { try? decoder.decode(Header.self, from: $0) }?
        .startedAt ?? .distantPast
      return (file, date)
    }
    guard dated.count > limit else { return }
    for (file, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(limit) {
      try FileManager.default.removeItem(at: file)
    }
  }

  private func files() -> [URL] {
    let contents =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)) ?? []
    return contents.filter { $0.pathExtension == "json" }
  }

  private static func newerFirst(_ a: GameRecord, _ b: GameRecord) -> Bool {
    a.startedAt != b.startedAt ? a.startedAt > b.startedAt : a.id.uuidString < b.id.uuidString
  }

  // MARK: Export

  /// Copies the saved JSON (or a fresh encoding) to a user-chosen location.
  func export(_ record: GameRecord, to destination: URL) throws {
    try Self.data(for: record).write(to: destination, options: .atomic)
  }
}

/// A game as a `.json` document, for `fileExporter`.
struct GameDocument: FileDocument {
  static let readableContentTypes: [UTType] = [.json]
  var data: Data

  init(record: GameRecord) throws { data = try GameStore.data(for: record) }
  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

extension GameRecord {
  /// "connect-four-2026-10-04-1530.json"
  var exportFilename: String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd-HHmm"
    return "connect-four-\(f.string(from: startedAt))"
  }
}
