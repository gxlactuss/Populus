import SwiftUI

struct HistorySidebar: View {
    let state: GameState
    @State private var confirmClear = false

    private var medianError: Double? {
        let errors = state.history.map { abs($0.ratio - 1) }.sorted()
        return errors.isEmpty ? nil : errors[errors.count / 2]
    }

    var body: some View {
        Group {
            if state.history.isEmpty && state.highScores.isEmpty {
                ContentUnavailableView("No attempts yet", systemImage: "circle.dashed",
                                       description: Text("Your reveals will show up here."))
            } else {
                List {
                    Section("High scores") {
                        HStack {
                            Summary(title: "All-time guesses", value: state.lifetimeGuesses.formatted())
                            Summary(title: "Avg accuracy", value: state.averageAccuracy.map(Format.accuracy) ?? "–")
                        }
                        ForEach(Array(state.highScores.enumerated()), id: \.element.id) { i, attempt in
                            Button { state.show(attempt) } label: { AttemptRow(attempt: attempt, rank: i + 1) }
                                .buttonStyle(.plain)
                                .disabled(state.phase == .revealing)
                        }
                    }
                    if !state.history.isEmpty {
                        Section {
                            HStack {
                                Summary(title: "Attempts", value: state.history.count.formatted())
                                Summary(title: "Median miss", value: medianError.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
                                Summary(title: "Bullseyes", value: state.history.filter { abs(log2($0.ratio)) < 0.05 }.count.formatted())
                            }
                        }
                        Section("Recent") {
                            ForEach(state.history) { attempt in
                                Button { state.show(attempt) } label: { AttemptRow(attempt: attempt) }
                                    .buttonStyle(.plain)
                                    // Opening an old attempt mid-count would drop the guess being counted.
                                    .disabled(state.phase == .revealing)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .safeAreaInset(edge: .bottom) {
                    if !state.history.isEmpty {
                        clearButton
                    }
                }
            }
        }
        .animation(.default, value: state.history.count)
    }

    private var clearButton: some View {
        Button("Clear History", role: .destructive) { confirmClear = true }
            .buttonStyle(.glass)
            .padding()
            .confirmationDialog("Clear all \(state.history.count) attempts?", isPresented: $confirmClear) {
                Button("Clear History", role: .destructive) { state.clearHistory() }
            } message: {
                Text("This can't be undone. High scores are kept.")
            }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private struct Summary: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AttemptRow: View {
    let attempt: Attempt
    /// Set for high score rows, which show the rank and accuracy instead of the verdict and miss.
    var rank: Int?

    var body: some View {
        let verdict = Verdict(ratio: attempt.ratio)
        HStack(spacing: 10) {
            Group {
                if let rank {
                    Text("\(rank)").font(.callout.weight(.bold).monospacedDigit())
                } else {
                    Image(systemName: verdict.symbol)
                }
            }
            .foregroundStyle(verdict.color)
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Format.compact(attempt.result.population.total)) of \(Format.compact(attempt.target))")
                    .fontWeight(.medium)
                Text([attempt.region.map { $0 == .world ? "World" : $0.name },
                      rank == nil ? attempt.result.cities.first.map { "near \($0.name)" }
                                  : attempt.date.formatted(date: .abbreviated, time: .omitted)]
                    .compactMap { $0 }.joined(separator: " · ")
                    .nilIfEmpty ?? attempt.date.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(rank == nil ? Format.percentOff(attempt.ratio) : Format.accuracy(attempt.accuracy))
                .font(.callout.monospacedDigit())
                .foregroundStyle(verdict.color)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}
