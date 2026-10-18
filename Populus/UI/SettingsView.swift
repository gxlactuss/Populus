import SwiftUI

struct SettingsView: View {
    @Bindable var state: GameState
    @Bindable var audio = Audio.shared
    @Bindable var updates = UpdateChecker.shared

    var body: some View {
        Form {
            Section {
                ForEach(RoundType.allCases, id: \.self) { type in
                    Toggle(type.title, isOn: Binding(
                        get: { state.allowedTypes.contains(type) },
                        set: { on in
                            if on { state.allowedTypes.insert(type) } else { state.allowedTypes.remove(type) }
                        }))
                        // At least one type has to stay on.
                        .disabled(state.allowedTypes == [type])
                }
            } header: {
                Text("Rounds")
            } footer: {
                Text("Changes apply from the next round.")
                    .foregroundStyle(.secondary)
            }

            Section("Sound") {
                Toggle("Music", isOn: $audio.musicOn)
                Slider(value: $audio.musicVolume, in: 0...1) {
                    Text("Music volume")
                } minimumValueLabel: {
                    Image(systemName: "speaker.fill")
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3.fill")
                }
                .disabled(!audio.musicOn)
                Toggle("Sound Effects", isOn: $audio.effectsOn)
            }

            Section("Updates") {
                Toggle("Check for updates on launch", isOn: $updates.checksOnLaunch)
                LabeledContent("Version \(UpdateChecker.currentVersion)") {
                    Button("Check Now") { updates.checkNow() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
