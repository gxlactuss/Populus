import SwiftUI

/// The first-run walkthrough: three short cards over the map.
struct TutorialView: View {
    let onDone: () -> Void
    @State private var step = 0

    private static let steps: [(symbol: String, title: String, text: String)] = [
        ("scribble.variable", "Draw around an area",
         "Enclose as close to the target number of people as you can. Pick a tool below: freehand (F), circle (C), ellipse (E), rectangle (R) or polygon (P). Hold Space to move the map."),
        ("return", "Press Return to guess",
         "Populus counts everyone inside your shape using real population data, down to 100 m squares in big cities."),
        ("flame", "See where people live",
         "After a guess, ⇧⌘D shows a population heatmap and ⌘D switches to the night map. Turn round types on or off in Settings (⌘,)."),
    ]

    var body: some View {
        let s = Self.steps[step]
        VStack(spacing: 16) {
            Image(systemName: s.symbol)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.orange)
                .frame(height: 40)
            Text(s.title)
                .font(.title2.weight(.bold))
            Text(s.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                HStack(spacing: 6) {
                    ForEach(Self.steps.indices, id: \.self) { i in
                        Circle()
                            .fill(i == step ? Color.primary : Color.secondary.opacity(0.4))
                            .frame(width: 6, height: 6)
                    }
                }
                Spacer()
                Button("Skip", action: onDone)
                    .buttonStyle(.glass)
                    .opacity(step < Self.steps.count - 1 ? 1 : 0)
                Button(step < Self.steps.count - 1 ? "Next" : "Start playing") {
                    if step < Self.steps.count - 1 {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { step += 1 }
                    } else {
                        onDone()
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .id(step)
        .padding(26)
        .frame(width: 400)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
}
