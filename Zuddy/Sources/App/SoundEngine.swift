import AVFoundation
import AppKit

/// Preloaded WAV players with near-zero latency.
/// Volume default 0.12 (matches prototype: gain ×6 then vol=0.12).
@MainActor
final class SoundEngine {
    static let shared = SoundEngine()

    var enabled: Bool = true
    var volume: Float = 0.12 {
        didSet { players.values.forEach { $0.forEach { $0.volume = volume } } }
    }

    // Pool per sound to allow overlapping playback.
    // Pool size 2: enough for rapid double-blips while halving held audio buffers.
    private var players: [String: [AVAudioPlayer]] = [:]

    /// Sounds loaded eagerly at launch (fired during greetings/expansion).
    /// The rest are lazily loaded on first use — same latency after warmup,
    /// far fewer decoded WAV buffers held at startup.
    private static let eagerSounds = ["peek", "open", "close", "hover", "blip", "tick", "greeting"]

    private init() {
        preload()
    }

    private func preload() {
        for name in Self.eagerSounds {
            ensurePool(name)
        }
    }

    /// Lazily build (or extend) a sound's player pool on first use.
    private func ensurePool(_ name: String) {
        if players[name] != nil { return }
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "sounds") else { return }
        var pool: [AVAudioPlayer] = []
        for _ in 0..<2 {
            if let p = try? AVAudioPlayer(contentsOf: url) {
                p.volume = volume
                p.prepareToPlay()
                pool.append(p)
            }
        }
        if !pool.isEmpty { players[name] = pool }
    }

    /// Fade out all currently-playing instances of `name` over `duration` seconds,
    /// then stop and reset them so they can be reused.
    func fadeOut(_ name: String, duration: TimeInterval) {
        ensurePool(name)
        guard let pool = players[name] else { return }
        for player in pool where player.isPlaying {
            player.setVolume(0, fadeDuration: duration)
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak player] in
                guard let p = player else { return }
                p.stop()
                p.currentTime = 0
                p.volume = self.volume
            }
        }
    }

    func play(_ name: String) {
        guard enabled && AppState.shared.soundEnabled else { return }
        ensurePool(name)
        guard let pool = players[name] else { return }
        // Find a player that is not currently playing
        let player = pool.first { !$0.isPlaying } ?? pool[0]
        player.currentTime = 0
        player.volume = volume
        player.play()
    }
}
