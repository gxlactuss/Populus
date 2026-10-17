import AVFoundation
import Observation

/// Background music and sound effects, all made by `Scripts/make_audio.py`.
@MainActor
@Observable
final class Audio {
    enum Effect: String, CaseIterable {
        case click, draw, undo, guess, round, great, good, bad, highscore
    }

    static let shared = Audio()

    var musicOn: Bool {
        didSet {
            UserDefaults.standard.set(musicOn, forKey: "musicOn")
            updateMusic()
        }
    }

    var effectsOn: Bool {
        didSet { UserDefaults.standard.set(effectsOn, forKey: "effectsOn") }
    }

    @ObservationIgnored private let music: AVAudioPlayer?
    @ObservationIgnored private var effects: [Effect: AVAudioPlayer] = [:]

    private init() {
        let d = UserDefaults.standard
        musicOn = d.object(forKey: "musicOn") as? Bool ?? true
        effectsOn = d.object(forKey: "effectsOn") as? Bool ?? true
        music = Self.player("lobby")
        music?.numberOfLoops = -1
        music?.volume = 0.3
        for effect in Effect.allCases {
            let player = Self.player(effect.rawValue)
            player?.volume = effect == .click ? 0.35 : 0.6
            player?.prepareToPlay()
            effects[effect] = player
        }
        updateMusic()
    }

    func play(_ effect: Effect) {
        guard effectsOn, let player = effects[effect] else { return }
        player.currentTime = 0
        player.play()
    }

    private func updateMusic() {
        if musicOn { music?.play() } else { music?.pause() }
    }

    private static func player(_ name: String) -> AVAudioPlayer? {
        Bundle.main.url(forResource: name, withExtension: "caf").flatMap { try? AVAudioPlayer(contentsOf: $0) }
    }
}
