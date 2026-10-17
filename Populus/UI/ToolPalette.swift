import SwiftUI

struct ToolPalette: View {
    @Bindable var state: GameState
    @Namespace private var selection

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 14) {
                tools
                    .disabled(state.phase != .drawing)
                    .opacity(state.phase == .drawing ? 1 : 0.5)
                layers
                primaryButton
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: state.phase)
    }

    private var tools: some View {
        HStack(spacing: 2) {
            ForEach(Tool.allCases) { tool in
                let selected = state.tool == tool
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) { state.tool = tool }
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 38, height: 32)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Color.accentColor.gradient)
                                    .matchedGeometryEffect(id: "tool", in: selection)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(tool.title) (\(String(tool.key).uppercased()))")
            }
        }
        .padding(5)
        .glassEffect(.regular, in: .capsule)
    }

    private var layers: some View {
        HStack(spacing: 2) {
            IconToggle(symbol: "flame", on: state.densityVisible,
                       help: state.densityAllowed ? "Population density (⇧⌘D)" : "Heatmap unlocks after your guess") {
                state.toggleDensity()
            }
            .disabled(!state.densityAllowed)
            IconToggle(symbol: state.mapStyle == .day ? "sun.max.fill" : "moon.stars.fill",
                       on: false, help: "Day / night map (⌘D)") {
                state.mapStyle = state.mapStyle == .day ? .night : .day
            }
            IconToggle(symbol: "arrow.uturn.backward", on: false, help: "Undo (⌘Z)") { state.undo() }
                .disabled(!state.canUndo)
            IconToggle(symbol: "trash", on: false, help: "Clear shape (⌫)") { state.clearShape() }
                .disabled(state.phase != .drawing || state.shape == nil)
        }
        .padding(5)
        .glassEffect(.regular, in: .capsule)
    }

    @ViewBuilder
    private var primaryButton: some View {
        Button {
            state.primaryAction()
        } label: {
            HStack(spacing: 8) {
                switch state.phase {
                case .drawing:
                    Image(systemName: "scope")
                    Text("Guess")
                case .revealing:
                    ProgressView().controlSize(.small)
                    Text("Counting")
                case .revealed:
                    Text("Next round")
                    Image(systemName: "arrow.right")
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentTransition(.opacity)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(state.phase == .drawing ? !state.canGuess : state.phase == .revealing)
        .help(state.phase == .revealed ? "Next round (↩)" : "Lock in your guess and see the real population (↩)")
    }
}

private struct IconToggle: View {
    let symbol: String
    let on: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 38, height: 32)
                .foregroundStyle(on ? Color.orange : Color.primary)
                .background(on ? Color.orange.opacity(0.18) : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
