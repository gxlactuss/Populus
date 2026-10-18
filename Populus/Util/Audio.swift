import AVFoundation
import Observation

/// Background music (the bundled .m4a tracks, see README credits) and sound effects (made by `Scripts/make_audio.py`).
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

    var musicVolume: Float {
        didSet {
            UserDefaults.standard.set(musicVolume, forKey: "musicVolume")
            music.volume = musicVolume
        }
    }

    @ObservationIgnored private let music = AVQueuePlayer()
    @ObservationIgnored private var effects: [Effect: AVAudioPlayer] = [:]

    private init() {
        let d = UserDefaults.standard
        musicOn = d.object(forKey: "musicOn") as? Bool ?? true
        effectsOn = d.object(forKey: "effectsOn") as? Bool ?? true
        musicVolume = d.object(forKey: "musicVolume") as? Float ?? 0.3
        for url in (Bundle.main.urls(forResourcesWithExtension: "m4a", subdirectory: nil) ?? []).shuffled() {
            music.insert(AVPlayerItem(url: url), after: nil)
        }
        music.volume = musicVolume
        // Put each finished track back at the end of the queue so the playlist repeats.
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [music] note in
            guard let url = ((note.object as? AVPlayerItem)?.asset as? AVURLAsset)?.url else { return }
            music.insert(AVPlayerItem(url: url), after: nil)
        }
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
        if musicOn { music.play() } else { music.pause() }
    }

    private static func player(_ name: String) -> AVAudioPlayer? {
        Bundle.main.url(forResource: name, withExtension: "caf").flatMap { try? AVAudioPlayer(contentsOf: $0) }
    }
}
