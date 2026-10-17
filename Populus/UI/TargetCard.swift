import SwiftUI

struct TargetCard: View {
    let state: GameState

    var body: some View {
        VStack(spacing: 2) {
            Text(state.phase == .revealed ? "TARGET WAS" : "ENCLOSE")
                .font(.caption.weight(.semibold))
                .tracking(2)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Format.people(state.target))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: state.target))
                Text("people")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            RegionChip(region: state.region)
                .id(state.region)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            if state.phase == .revealing {
                HStack(spacing: 6) {
                    LassoSpinner(lineWidth: 2.5)
                        .frame(width: 14, height: 14)
                    Text("Counting people…").font(.callout).foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: state.target)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: state.region)
    }
}

private struct RegionChip: View {
    let region: Region

    var body: some View {
        HStack(spacing: 6) {
            if let flag = region.flag {
                Text(flag)
            } else {
                Image(systemName: region.symbol)
            }
            Text(region.label)
            Text(region.kind.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.orange.opacity(0.2), in: Capsule())
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(.orange)
    }
}
