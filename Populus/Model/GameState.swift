import Foundation
import Observation
import SwiftUI

enum MapStyle: String {
    case day, night
}

struct RoundResult: Codable, Hashable, Sendable {
    var population: PopulationResult
    var cities: [CityHit]
}

struct Attempt: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var target: Double
    var shape: [GeoPoint]
    var result: RoundResult
    var region: Region?

    var ratio: Double { result.population.total / target }
    /// 1 when spot on, 0.5 when off by 2x either way.
    var accuracy: Double { ratio > 0 ? min(ratio, 1 / ratio) : 0 }
}

struct FocusRequest: Equatable {
    enum Target: Equatable {
        case world
        case region(Region)
        case shape([GeoPoint])
    }

    let id = UUID()
    let target: Target
}

struct Verdict {
    let title: String
    let symbol: String
    let color: Color

    init(ratio: Double) {
        let e = ratio > 0 ? abs(log2(ratio)) : .infinity
        switch e {
        case ..<0.05: (title, symbol, color) = ("Bullseye!", "scope", .green)
        case ..<0.15: (title, symbol, color) = ("Excellent", "star.fill", .green)
        case ..<0.33: (title, symbol, color) = ("Close", "hand.thumbsup.fill", .mint)
        case ..<0.75: (title, symbol, color) = ("Not bad", "face.smiling", .yellow)
        case ..<1.6: (title, symbol, color) = ("Off the mark", "arrow.up.arrow.down", .orange)
        default: (title, symbol, color) = ("Way off", "tornado", .red)
        }
    }
}

@MainActor
@Observable
final class GameState {
    enum Phase { case drawing, revealing, revealed }

    static let worldRange: ClosedRange<Double> = 1e5...3e9
    /// Targets stay under this share of the region's real population.
    static let regionShare = 0.75
    static let highScoreCount = 10

    let grid = PopulationGrid.shared

    var target: Double = 10_000_000
    var phase: Phase = .drawing
    var tool: Tool = .freehand {
        didSet { if tool != oldValue { Audio.shared.play(.click) } }
    }
    var spaceHeld = false
    private(set) var shape: [GeoPoint]?
    private(set) var result: RoundResult?
    private(set) var resultID = UUID()
    private(set) var focus: FocusRequest?
    private(set) var pulseToken = 0
    /// What the current round is locked to.
    private(set) var region: Region = .world
    /// The next round's region, picked early so the map can load it while this round is played.
    private(set) var upcomingRegion: Region?
    private(set) var history: [Attempt] = [] {
        didSet { save(history, key: "history") }
    }
    /// The best guesses ever made on this Mac, best first. Kept apart from history so clearing it doesn't touch them.
    private(set) var highScores: [Attempt] = [] {
        didSet { save(highScores, key: "highScores") }
    }
    /// Every guess ever made on this Mac, as a count and a sum of accuracies.
    private(set) var lifetimeGuesses = 0 {
        didSet { UserDefaults.standard.set(lifetimeGuesses, forKey: "lifetimeGuesses") }
    }
    private(set) var lifetimeAccuracy = 0.0 {
        didSet { UserDefaults.standard.set(lifetimeAccuracy, forKey: "lifetimeAccuracy") }
    }
    /// Where the latest guess landed in `highScores`, 1 for a new high score; nil if it didn't make it.
    private(set) var highScoreRank: Int?
    /// Regions of recent rounds, oldest first, so countries and cities don't come back too soon.
    private var recentRegions: [Region] = [] {
        didSet { save(recentRegions, key: "recentRegions") }
    }

    var showDensity = false {
        didSet { if showDensity != oldValue { Audio.shared.play(.click) } }
    }
    var showHistory = false
    /// The start-up screen, shown once per launch until the map has drawn.
    private(set) var showsSplash = true
    private var mapRendered = false
    private var splashMinimumPassed = false

    var mapStyle: MapStyle {
        didSet {
            UserDefaults.standard.set(mapStyle.rawValue, forKey: "mapStyle")
            Audio.shared.play(.click)
        }
    }

    private var undoStack: [[GeoPoint]?] = []

    /// The heatmap stays hidden until the guess is in.
    var densityAllowed: Bool { phase == .revealed }
    var densityVisible: Bool { showDensity && densityAllowed }
    var canUndo: Bool { phase == .drawing && !undoStack.isEmpty }
    var canGuess: Bool { phase == .drawing && shape != nil && grid != nil }
    var drawingEnabled: Bool { phase == .drawing && tool != .pan && !spaceHeld }
    var averageAccuracy: Double? { lifetimeGuesses > 0 ? lifetimeAccuracy / Double(lifetimeGuesses) : nil }

    init() {
        let d = UserDefaults.standard
        mapStyle = MapStyle(rawValue: d.string(forKey: "mapStyle") ?? "") ?? .day
        if let data = d.data(forKey: "history"), let h = try? JSONDecoder().decode([Attempt].self, from: data) {
            history = h
        }
        if let data = d.data(forKey: "highScores"), let h = try? JSONDecoder().decode([Attempt].self, from: data) {
            highScores = h
            lifetimeGuesses = d.integer(forKey: "lifetimeGuesses")
            lifetimeAccuracy = d.double(forKey: "lifetimeAccuracy")
        } else {
            // First launch with high scores: start them from the history already played.
            highScores = Array(history.sorted { $0.accuracy > $1.accuracy }.prefix(Self.highScoreCount))
            lifetimeGuesses = history.count
            lifetimeAccuracy = history.map(\.accuracy).reduce(0, +)
        }
        if let data = d.data(forKey: "recentRegions"), let r = try? JSONDecoder().decode([Region].self, from: data) {
            recentRegions = r
        }
        startRound()
        Task { [weak self] in
            // Long enough to read a fun fact, and never stuck if the map can't load.
            try? await Task.sleep(for: .seconds(3))
            self?.splashMinimumPassed = true
            self?.hideSplashIfReady()
            try? await Task.sleep(for: .seconds(12))
            self?.showsSplash = false
        }
    }

    func mapDidRender() {
        mapRendered = true
        hideSplashIfReady()
    }

    private func hideSplashIfReady() {
        if mapRendered && splashMinimumPassed { showsSplash = false }
    }

    // MARK: Shape

    func commit(_ newShape: [GeoPoint]) {
        guard phase == .drawing else { return }
        undoStack.append(shape)
        shape = newShape
        Audio.shared.play(.draw)
    }

    func undo() {
        guard canUndo else { return }
        shape = undoStack.removeLast()
        Audio.shared.play(.undo)
    }

    func clearShape() {
        guard phase == .drawing, shape != nil else { return }
        undoStack.append(shape)
        shape = nil
        Audio.shared.play(.undo)
    }

    // MARK: Round flow

    func primaryAction() {
        switch phase {
        case .drawing: guess()
        case .revealing: break
        case .revealed: next()
        }
    }

    func guess() {
        guard canGuess, let shape, let grid else { return }
        phase = .revealing
        focus = FocusRequest(target: .shape(shape))
        Audio.shared.play(.guess)
        let target = target, region = region
        Task { [weak self] in
            async let minimumWait: Void = Task.sleep(for: .milliseconds(650))
            let result = await Task.detached(priority: .userInitiated) {
                RoundResult(population: grid.population(in: shape, region: region),
                            cities: Cities.largest(in: shape, region: region))
            }.value
            try? await minimumWait
            guard let self, self.phase == .revealing else { return }
            self.result = result
            self.resultID = UUID()
            self.pulseToken += 1
            self.phase = .revealed
            let attempt = Attempt(date: .now, target: target, shape: shape, result: result, region: region)
            self.history.insert(attempt, at: 0)
            if self.history.count > 200 { self.history.removeLast(self.history.count - 200) }
            self.record(attempt)
        }
    }

    private func record(_ attempt: Attempt) {
        lifetimeGuesses += 1
        lifetimeAccuracy += attempt.accuracy
        // Ties go to the older guess.
        let index = highScores.firstIndex { $0.accuracy < attempt.accuracy } ?? highScores.count
        if index < Self.highScoreCount {
            highScores.insert(attempt, at: index)
            highScores = Array(highScores.prefix(Self.highScoreCount))
            highScoreRank = index + 1
        }
        let effect: Audio.Effect
        if highScoreRank == 1 {
            effect = .highscore
        } else {
            let e = abs(log2(max(attempt.ratio, 1e-9)))
            effect = e < 0.15 ? .great : e < 0.75 ? .good : .bad
        }
        // Lands with the verdict badge in the reveal panel.
        let id = resultID
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            if self?.resultID == id { Audio.shared.play(effect) }
        }
    }

    func next() {
        resetRound()
        startRound()
        Audio.shared.play(.round)
    }

    func retry() {
        resetRound()
    }

    func show(_ attempt: Attempt) {
        target = attempt.target
        shape = attempt.shape
        result = attempt.result
        resultID = attempt.id
        region = attempt.region ?? .world
        highScoreRank = nil
        undoStack.removeAll()
        phase = .revealed
        focus = FocusRequest(target: .shape(attempt.shape))
    }

    func clearHistory() {
        history.removeAll()
    }

    func toggleDensity() {
        guard densityAllowed else { return }
        showDensity.toggle()
    }

    private var targetRange: ClosedRange<Double> {
        if region == .world { return Self.worldRange }
        let low: Double
        if case .city = region { low = 5e4 } else { low = Self.worldRange.lowerBound }
        return low...max(low * 2, region.population * Self.regionShare)
    }

    private func startRound() {
        if let next = upcomingRegion, next != region {
            region = next
        } else {
            region = Region.random(after: recentRegions + [region])
        }
        recentRegions = Array((recentRegions + [region]).suffix(Region.repeatGap))
        upcomingRegion = Region.random(after: recentRegions)
        focus = FocusRequest(target: region == .world ? .world : .region(region))
        target = Self.randomTarget(in: targetRange, avoiding: target)
    }

    private func resetRound() {
        phase = .drawing
        shape = nil
        result = nil
        highScoreRank = nil
        undoStack.removeAll()
        showDensity = false
    }

    // MARK: Helpers

    /// Log-uniform, so every order of magnitude in the range is equally likely.
    static func randomTarget(in range: ClosedRange<Double>, avoiding previous: Double?) -> Double {
        let lo = log10(range.lowerBound), hi = log10(range.upperBound)
        for _ in 0..<10 {
            let v = niceNumber(pow(10, Double.random(in: lo...hi)))
            if v != previous, range.contains(v) { return v }
        }
        return niceNumber(range.lowerBound)
    }

    static func niceNumber(_ x: Double) -> Double {
        let e = floor(log10(x))
        let m = x / pow(10, e)
        let steps: [Double] = [1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 7.5, 8, 10]
        let best = steps.min { abs(log($0 / m)) < abs(log($1 / m)) }!
        return best * pow(10, e)
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
