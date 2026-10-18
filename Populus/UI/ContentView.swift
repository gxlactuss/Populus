import SwiftUI

struct ContentView: View {
    @Bindable var state: GameState

    var body: some View {
        ZStack {
            MapView(
                style: state.mapStyle,
                densityVisible: state.densityVisible,
                shape: state.shape,
                interactive: state.drawingEnabled,
                tool: state.tool,
                focus: state.focus,
                pulseToken: state.pulseToken,
                region: state.region == .world ? nil : state.region,
                upcoming: state.upcomingRegion,
                onCommit: { state.commit($0) },
                onSpace: { state.spaceHeld = $0 },
                onEscape: { state.clearShape() },
                onFirstRender: { state.mapDidRender() }
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                TargetCard(state: state)
                    .padding(.top, 14)
                Spacer()
                HintLabel(state: state)
                    .padding(.bottom, 10)
                ToolPalette(state: state)
                    .padding(.bottom, 22)
            }

            HStack {
                Spacer()
                if state.phase == .revealed, let result = state.result, let shape = state.shape {
                    RevealPanel(target: state.target, result: result, highScoreRank: state.highScoreRank,
                                shape: shape, region: state.region, style: state.mapStyle,
                                onNext: state.next, onRetry: state.retry)
                        .id(state.resultID)
                        .padding(.trailing, 20)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .opacity.combined(with: .scale(scale: 0.95))))
                }
            }

            if DensityLegend.isVisible(state) {
                VStack {
                    Spacer()
                    HStack {
                        DensityLegend()
                            .padding(.leading, 20)
                            .padding(.bottom, 22)
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                        Spacer()
                    }
                }
            }

            if state.grid == nil {
                ContentUnavailableView("Population data missing", systemImage: "exclamationmark.triangle",
                                       description: Text("Run Scripts/fetch_data.sh, then rebuild the app."))
                    .padding(30)
                    .glassEffect(.regular, in: .rect(cornerRadius: 24))
                    .frame(maxWidth: 420)
            }

            if state.showTutorial && !state.showsSplash {
                TutorialView { state.showTutorial = false }
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .zIndex(1)
            }

            if state.showsSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.7), value: state.showsSplash)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: state.showTutorial)
        .task { UpdateChecker.shared.checkOnLaunch() }
        .animation(.spring(response: 0.55, dampingFraction: 0.85), value: state.phase)
        .animation(.easeInOut(duration: 0.35), value: state.densityVisible)
        .preferredColorScheme(state.mapStyle == .night ? .dark : nil)
        .inspector(isPresented: $state.showHistory) {
            HistorySidebar(state: state)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let release = UpdateChecker.shared.available {
                    Button {
                        NSWorkspace.shared.open(release.htmlURL)
                    } label: {
                        Label("Update Available", systemImage: "arrow.down.circle.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .help("Download Populus \(release.version ?? "")")
                }
                Button {
                    Audio.shared.musicOn.toggle()
                } label: {
                    Label("Music", systemImage: Audio.shared.musicOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                }
                .help(Audio.shared.musicOn ? "Turn music off" : "Turn music on")
                Button {
                    state.showHistory.toggle()
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .help("History (⌘Y)")
            }
        }
    }
}

private struct HintLabel: View {
    let state: GameState

    private var text: String? {
        switch state.phase {
        case .revealing: return nil
        case .revealed: return "Drag to look around · ↩ for the next round"
        case .drawing:
            if state.spaceHeld { return Tool.pan.hint }
            if state.shape != nil { return "Drag inside the shape to move it · draw again to replace · ↩ to guess" }
            return state.tool == .pan ? state.tool.hint : state.tool.hint + " · scroll or pinch to move the map"
        }
    }

    var body: some View {
        Group {
            if let text {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                    .id(text)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(.easeOut(duration: 0.25), value: text)
    }
}
