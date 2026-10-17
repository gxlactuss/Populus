import SwiftUI

struct RevealPanel: View {
    let target: Double
    let result: RoundResult
    /// Place in the all-time best guesses, if it made the list.
    let highScoreRank: Int?
    let onNext: () -> Void
    let onRetry: () -> Void

    @State private var counted: Double = 0
    @State private var needle: Double = 0
    @State private var showVerdict = false
    @State private var showDetails = false

    private var total: Double { result.population.total }
    private var ratio: Double { total / target }
    private var verdict: Verdict { Verdict(ratio: ratio) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ACTUALLY INSIDE")
                    .font(.caption.weight(.semibold))
                    .tracking(2)
                    .foregroundStyle(.secondary)
                CountUpText(value: counted)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("people · target \(Format.people(target))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Label(verdict.title, systemImage: verdict.symbol)
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(verdict.color.opacity(0.22), in: Capsule())
                    .foregroundStyle(verdict.color)
                Text(Format.percentOff(ratio))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .scaleEffect(showVerdict ? 1 : 0.6, anchor: .leading)
            .opacity(showVerdict ? 1 : 0)

            if let highScoreRank {
                Label(highScoreRank == 1 ? "New high score!" : "#\(highScoreRank) best guess ever",
                      systemImage: highScoreRank == 1 ? "trophy.fill" : "medal.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(highScoreRank == 1 ? .yellow : .secondary)
                    .scaleEffect(showVerdict ? 1 : 0.6, anchor: .leading)
                    .opacity(showVerdict ? 1 : 0)
            }

            AccuracyBar(logRatio: needle)

            if showDetails {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    StatRow(label: "Area", value: Format.area(result.population.areaKm2))
                    StatRow(label: "Average density", value: Format.density(result.population.averageDensity))
                    StatRow(label: "Peak density", value: Format.density(result.population.peakDensity))
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))

                if !result.cities.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("LARGEST PLACES INSIDE")
                            .font(.caption.weight(.semibold))
                            .tracking(1.5)
                            .foregroundStyle(.secondary)
                        ForEach(Array(result.cities.enumerated()), id: \.offset) { i, city in
                            HStack {
                                Text(city.name).fontWeight(.medium)
                                Text(city.country).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                Text(Format.compact(Double(city.population)))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            .transition(.opacity.combined(with: .offset(x: 20)))
                            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(Double(i) * 0.08), value: showDetails)
                        }
                        Text("Metro populations, can extend past your shape")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .transition(.opacity)
                }
            }

            HStack {
                Button("Try again", systemImage: "arrow.counterclockwise", action: onRetry)
                    .buttonStyle(.glass)
                Spacer()
                Button(action: onNext) {
                    Label("Next round", systemImage: "arrow.right")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.glassProminent)
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(width: 340)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .onAppear(perform: animateIn)
    }

    private func animateIn() {
        withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 1.8)) { counted = total }
        withAnimation(.spring(response: 1.0, dampingFraction: 0.55).delay(0.5)) { needle = log10(max(ratio, 1e-6)) }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.6).delay(1.2)) { showVerdict = true }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85).delay(1.5)) { showDetails = true }
    }
}

/// Text that animates through every intermediate integer.
private struct CountUpText: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(Format.integer(value))
    }
}

private struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().fontWeight(.medium)
        }
        .font(.callout)
    }
}

/// Log scale from 0.1× to 10× the target, with a needle for the player's result.
private struct AccuracyBar: View {
    let logRatio: Double

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                let x = (min(1, max(-1, logRatio)) + 1) / 2 * w
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: [.red, .orange, .yellow, .green, .yellow, .orange, .red],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(height: 8)
                        .opacity(0.85)
                    Rectangle()
                        .fill(.primary.opacity(0.6))
                        .frame(width: 2, height: 16)
                        .offset(x: w / 2 - 1)
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .frame(width: 18, height: 18)
                        .offset(x: x - 9)
                }
                .frame(height: 18)
            }
            .frame(height: 18)
            HStack {
                Text("0.1×")
                Spacer()
                Text("on target")
                Spacer()
                Text("10×")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}
