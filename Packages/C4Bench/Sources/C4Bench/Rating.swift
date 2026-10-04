import C4AI
import C4Core
import Foundation

/// One game's result between two contestant ids. `scoreA` is 1, 0.5 or 0.
public struct PairResult: Sendable, Hashable, Codable {
    public var a: String
    public var b: String
    public var scoreA: Double

    public init(a: String, b: String, scoreA: Double) {
        self.a = a
        self.b = b
        self.scoreA = scoreA
    }
}

/// Bradley–Terry maximum-likelihood ratings over all games (§5.3), fitted with the MM
/// algorithm. Draws count as half a win. A weak prior (`priorDraws` virtual draws for each
/// contestant against the reference) keeps players who won or lost every game finite.
/// Reported on an Elo-like scale (400 · log10) with the reference fixed at 1000.
public enum BradleyTerry {
    public static func fit(
        _ results: [PairResult], reference: String = Contestant.reference.id, priorDraws: Double = 1,
        iterations: Int = 10_000, tolerance: Double = 1e-10
    ) -> [String: Double] {
        fatalError("TODO: agent E")
    }

    /// 95% confidence interval per contestant from `resamples` bootstrap resamples of the
    /// games (seeded, so reproducible).
    public static func bootstrap(
        _ results: [PairResult], reference: String = Contestant.reference.id, priorDraws: Double = 1,
        resamples: Int = 1000, seed: UInt64 = 0
    ) -> [String: ClosedRange<Double>] {
        fatalError("TODO: agent E")
    }
}

/// One leaderboard row (§5.4). Optional columns are nil when not measured (anchors have no
/// tok/s, puzzles may not have been run, …).
public struct RatingRow: Sendable, Hashable, Codable, Identifiable {
    public var contestant: Contestant
    public var rank: Int
    public var rating: Double
    public var ciLow: Double
    public var ciHigh: Double
    /// True if this row's interval overlaps the row above it.
    public var tiedWithPrevious: Bool
    public var games: Int
    public var wins: Int
    public var draws: Int
    public var losses: Int
    /// Accuracy per puzzle category (keyed by `PuzzleCategory.rawValue`), 0...1.
    public var puzzleAccuracy: [String: Double]
    public var puzzleOverall: Double?
    public var winRateVsD4: Double?
    public var blundersPerGame: Double?
    public var wouldBeIllegalRate: Double?
    public var medianMoveMs: Double?
    public var tokensPerSecond: Double?
    public var loadTimeMs: Double?
    public var peakRAMGB: Double?
    public var sizeGB: Double?

    public var id: String { contestant.id }

    public init(
        contestant: Contestant, rank: Int, rating: Double, ciLow: Double, ciHigh: Double,
        tiedWithPrevious: Bool = false, games: Int, wins: Int, draws: Int, losses: Int,
        puzzleAccuracy: [String: Double] = [:], puzzleOverall: Double? = nil, winRateVsD4: Double? = nil,
        blundersPerGame: Double? = nil, wouldBeIllegalRate: Double? = nil, medianMoveMs: Double? = nil,
        tokensPerSecond: Double? = nil, loadTimeMs: Double? = nil, peakRAMGB: Double? = nil, sizeGB: Double? = nil
    ) {
        self.contestant = contestant
        self.rank = rank
        self.rating = rating
        self.ciLow = ciLow
        self.ciHigh = ciHigh
        self.tiedWithPrevious = tiedWithPrevious
        self.games = games
        self.wins = wins
        self.draws = draws
        self.losses = losses
        self.puzzleAccuracy = puzzleAccuracy
        self.puzzleOverall = puzzleOverall
        self.winRateVsD4 = winRateVsD4
        self.blundersPerGame = blundersPerGame
        self.wouldBeIllegalRate = wouldBeIllegalRate
        self.medianMoveMs = medianMoveMs
        self.tokensPerSecond = tokensPerSecond
        self.loadTimeMs = loadTimeMs
        self.peakRAMGB = peakRAMGB
        self.sizeGB = sizeGB
    }
}

public enum Leaderboard {
    /// Recomputes every row from saved games and puzzle attempts. Speed columns use only
    /// data from `machine` when given.
    public static func compute(
        games: [BenchGame], puzzles: [PuzzleAttempt], models: [ModelSpec] = ModelRegistry.bundled(),
        machine: MachineInfo? = nil
    ) -> [RatingRow] {
        fatalError("TODO: agent E")
    }
}

public enum ReportFormat: String, Sendable, Hashable, Codable, CaseIterable {
    case md, csv, json
}

public enum ReportWriter {
    /// Renders the leaderboard. Markdown is used for `LEADERBOARD.md` and the README table.
    public static func render(_ rows: [RatingRow], format: ReportFormat, machine: MachineInfo? = nil) -> String {
        fatalError("TODO: agent E")
    }
}
