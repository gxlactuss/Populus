import SwiftUI

@main
struct PopulusApp: App {
    @State private var state = GameState()

    var body: some Scene {
        Window("Populus", id: "main") {
            ContentView(state: state)
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1400, height: 880)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands { GameCommands(state: state) }

        Settings {
            SettingsView(state: state)
        }
    }
}

struct GameCommands: Commands {
    @Bindable var state: GameState

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Populus") { showAbout() }
            Button("Check for Updates…") { UpdateChecker.shared.checkNow() }
        }
        CommandGroup(replacing: .help) {
            Button("Show Tutorial") { state.showTutorial = true }
            Button("Report an Issue…") { NSWorkspace.shared.open(Links.newIssue) }
            Button("Populus on GitHub") { NSWorkspace.shared.open(Links.repo) }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Round") { state.next() }
                .keyboardShortcut("n")
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo Shape") { state.undo() }
                .keyboardShortcut("z")
                .disabled(!state.canUndo)
        }
        CommandMenu("Game") {
            Button(state.phase == .revealed ? "Next Round" : "Guess") { state.primaryAction() }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(state.phase == .drawing ? !state.canGuess : state.phase == .revealing)
            Button("Try Again") { state.retry() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(state.phase != .revealed)
            Button("Clear Shape") { state.clearShape() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(state.phase != .drawing || state.shape == nil)
        }
        CommandMenu("Tools") {
            ForEach(Tool.allCases) { tool in
                Button(tool.title) { state.tool = tool }
                    .keyboardShortcut(KeyEquivalent(tool.key), modifiers: [])
            }
        }
        CommandGroup(before: .toolbar) {
            Button(state.mapStyle == .day ? "Switch to Night" : "Switch to Day") {
                state.mapStyle = state.mapStyle == .day ? .night : .day
            }
            .keyboardShortcut("d")
            Button(state.densityVisible ? "Hide Population Density" : "Show Population Density") {
                state.toggleDensity()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!state.densityAllowed)
            Button(state.showHistory ? "Hide History" : "Show History") { state.showHistory.toggle() }
                .keyboardShortcut("y")
            Divider()
            Toggle("Music", isOn: Binding(get: { Audio.shared.musicOn }, set: { Audio.shared.musicOn = $0 }))
            Toggle("Sound Effects", isOn: Binding(get: { Audio.shared.effectsOn }, set: { Audio.shared.effectsOn = $0 }))
            Divider()
        }
    }

    private func showAbout() {
        let credits = """
        Map imagery: Apple Maps
        Population: GHS-POP 2025, European Commission JRC (1 km world grid, 100 m city grids)
        Night lights: NASA VIIRS Black Marble via GIBS
        Borders and places: Natural Earth
        Inspired by Headcount from FlightQ
        """
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: credits, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: style,
            ]),
        ])
    }
}

enum Links {
    static let repo = URL(string: "https://github.com/gxlactuss/Populus")!
    static let releasesAPI = URL(string: "https://api.github.com/repos/gxlactuss/Populus/releases")!

    /// A new GitHub issue with the app and macOS versions already filled in.
    static var newIssue: URL {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))"
        var c = URLComponents(url: repo.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "template", value: "bug_report.yml"),
            URLQueryItem(name: "version", value: version),
            URLQueryItem(name: "macos", value: ProcessInfo.processInfo.operatingSystemVersionString),
        ]
        return c.url!
    }
}
