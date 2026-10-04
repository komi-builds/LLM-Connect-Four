import C4Core
import Foundation
import os

/// Resumable benchmark storage (§5.5).
///
/// Layout under the store directory (default
/// `~/Library/Application Support/LLMConnectFour/bench/`):
///
///     games/game-<16 hex of the game seed>.jsonl     one file per finished game
///     puzzles/<16 hex of hash(contestant id)>.jsonl  one file per contestant
///
/// A game file holds the whole `BenchGame` (traces included) as one compact JSON line, written
/// atomically (temp file then rename), so a file on disk is always a finished game and a
/// crash or Ctrl-C can never leave a half game that counts. The file name is the game
/// seed, which is a hash of (preset, colours, opening, game index), so a rerun can tell
/// which games are done without reading them. A puzzle file has one `PuzzleAttempt` JSON line
/// per answered puzzle, appended as each puzzle finishes; a torn last line is ignored.
public struct BenchStore: Sendable {
  static let log = Logger(subsystem: "com.komi.LLMConnectFour", category: "bench")

  public let directory: URL

  public init(directory: URL = BenchStore.defaultDirectory) {
    self.directory = directory
  }

  public static var defaultDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("LLMConnectFour", isDirectory: true)
      .appendingPathComponent("bench", isDirectory: true)
  }

  var gamesDirectory: URL { directory.appendingPathComponent("games", isDirectory: true) }
  var puzzlesDirectory: URL { directory.appendingPathComponent("puzzles", isDirectory: true) }

  // MARK: Coding

  static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  // MARK: Games

  public static func gameFileName(seed: UInt64) -> String { "game-\(StableHash.hex(seed)).jsonl" }

  public func hasGame(seed: UInt64) -> Bool {
    FileManager.default.fileExists(
      atPath: gamesDirectory.appendingPathComponent(Self.gameFileName(seed: seed)).path)
  }

  /// Seeds of every finished game on disk.
  public func finishedGameSeeds() -> Set<UInt64> {
    let names =
      (try? FileManager.default.contentsOfDirectory(atPath: gamesDirectory.path)) ?? []
    var seeds = Set<UInt64>()
    for name in names where name.hasPrefix("game-") && name.hasSuffix(".jsonl") {
      let hex = name.dropFirst(5).dropLast(6)
      if let seed = UInt64(hex, radix: 16) { seeds.insert(seed) }
    }
    return seeds
  }

  public func save(_ game: BenchGame) throws {
    try FileManager.default.createDirectory(at: gamesDirectory, withIntermediateDirectories: true)
    var line = try Self.encoder().encode(game)
    line.append(0x0A)
    let url = gamesDirectory.appendingPathComponent(Self.gameFileName(seed: game.gameSeed))
    try line.write(to: url, options: .atomic)
  }

  /// Every finished game, oldest first. Unreadable files are skipped and logged.
  public func loadGames() -> [BenchGame] {
    let decoder = Self.decoder()
    var games: [BenchGame] = []
    for url in files(in: gamesDirectory) {
      guard let data = try? Data(contentsOf: url),
        let line = data.split(separator: 0x0A).first,
        let game = try? decoder.decode(BenchGame.self, from: Data(line))
      else {
        Self.log.error("skipping unreadable game file \(url.lastPathComponent, privacy: .public)")
        continue
      }
      games.append(game)
    }
    return games.sorted { $0.finishedAt < $1.finishedAt }
  }

  // MARK: Puzzle attempts

  func puzzleFile(for contestant: Contestant) -> URL {
    puzzlesDirectory.appendingPathComponent(
      "\(StableHash.hex(StableHash.hash(contestant.id))).jsonl")
  }

  public func append(_ attempt: PuzzleAttempt) throws {
    try FileManager.default.createDirectory(at: puzzlesDirectory, withIntermediateDirectories: true)
    var line = try Self.encoder().encode(attempt)
    line.append(0x0A)
    let url = puzzleFile(for: attempt.contestant)
    if !FileManager.default.fileExists(atPath: url.path) {
      try line.write(to: url, options: .atomic)
      return
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line)
  }

  /// Puzzle ids this contestant has already answered.
  public func answeredPuzzleIDs(for contestant: Contestant) -> Set<String> {
    Set(
      attempts(in: puzzleFile(for: contestant)).filter { $0.contestant.id == contestant.id }.map(
        \.puzzleID))
  }

  public func loadPuzzleAttempts() -> [PuzzleAttempt] {
    files(in: puzzlesDirectory).flatMap { attempts(in: $0) }
  }

  private func attempts(in url: URL) -> [PuzzleAttempt] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    let decoder = Self.decoder()
    return data.split(separator: 0x0A).compactMap {
      try? decoder.decode(PuzzleAttempt.self, from: Data($0))
    }
  }

  private func files(in directory: URL) -> [URL] {
    let urls =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)) ?? []
    return urls.filter { $0.pathExtension == "jsonl" }.sorted {
      $0.lastPathComponent < $1.lastPathComponent
    }
  }
}

/// The puzzles shipped in `puzzles.json`.
public enum BenchPuzzles {
  public static func bundled() -> [Puzzle] {
    guard let url = Bundle.module.url(forResource: "puzzles", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let puzzles = try? JSONDecoder().decode([Puzzle].self, from: data)
    else { return [] }
    return puzzles
  }
}
