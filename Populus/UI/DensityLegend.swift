import SwiftUI

struct DensityLegend: View {
    static func isVisible(_ state: GameState) -> Bool { state.densityVisible }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PEOPLE PER KM²")
                .font(.caption2.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            Capsule()
                .fill(LinearGradient(colors: [
                    Color(red: 40 / 255, green: 11 / 255, blue: 84 / 255),
                    Color(red: 120 / 255, green: 28 / 255, blue: 109 / 255),
                    Color(red: 212 / 255, green: 72 / 255, blue: 66 / 255),
                    Color(red: 250 / 255, green: 150 / 255, blue: 30 / 255),
                    Color(red: 252 / 255, green: 255 / 255, blue: 164 / 255),
                ], startPoint: .leading, endPoint: .trailing))
                .frame(width: 180, height: 8)
            HStack {
                Text("1")
                Spacer()
                Text("100")
                Spacer()
                Text("20K+")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 180)
            Text("GHS-POP 2025 · 1 km grid, 100 m in cities")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}
