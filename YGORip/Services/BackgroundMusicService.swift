import AVFoundation

/// Loops a background track that respects whatever else is playing on the device.
///
/// Behavior:
/// - `.ambient` audio session: never interrupts other audio, silenced by the
///   ringer switch.
/// - Won't start if the user already has music/podcasts playing
///   (`isOtherAudioPlaying`); checked on every start attempt.
/// - Pauses if other audio starts mid-session (via
///   `silenceSecondaryAudioHintNotification`), resumes when it stops.
/// - Volume of 0 is treated as off — playback is paused rather than just muted,
///   so the audio session can be released and the loop stops costing power.
@MainActor
final class BackgroundMusicService {
    static let shared = BackgroundMusicService()

    private var player: AVAudioPlayer?
    private var currentVolume: Float = 0

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSecondaryAudioHint(_:)),
            name: AVAudioSession.silenceSecondaryAudioHintNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    /// Apply a new volume. >0 starts (or resumes) playback; 0 pauses it.
    func setVolume(_ volume: Float) {
        currentVolume = max(0, min(1, volume))
        if currentVolume > 0 {
            start()
            player?.volume = currentVolume
        } else {
            pause()
        }
    }

    /// Resume playback at the current volume (e.g., on app foreground).
    func resumeIfNeeded() {
        guard currentVolume > 0 else { return }
        start()
    }

    func pause() {
        player?.pause()
    }

    private func start() {
        AudioSession.activate()

        // Don't talk over the user's podcast/music.
        guard !AVAudioSession.sharedInstance().isOtherAudioPlaying else { return }

        if player == nil {
            guard let url = Bundle.main.url(forResource: "cardboard-cosmos", withExtension: "mp3") else {
                return
            }
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.numberOfLoops = -1
                p.volume = currentVolume
                p.prepareToPlay()
                player = p
            } catch {
                return
            }
        }
        player?.play()
    }

    // MARK: - Interruption

    /// Phone call, Siri, alarm. iOS deactivates our session and stops the
    /// player; without this the music never comes back for the rest of the
    /// process. Distinct from the secondary-audio hint below, which is about
    /// *another app* starting audio rather than the system taking the session.
    @objc private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        Task { @MainActor in
            switch type {
            case .began:
                player?.pause()
            case .ended:
                // Deliberately ignoring `.shouldResume`: it's advisory, and
                // an ambient background loop the user opted into is exactly
                // the case where resuming is right regardless.
                guard currentVolume > 0 else { return }
                AudioSession.reactivateAfterInterruption()
                player?.play()
            @unknown default:
                break
            }
        }
    }

    // MARK: - Secondary audio hint

    @objc private func handleSecondaryAudioHint(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt,
              let type = AVAudioSession.SilenceSecondaryAudioHintType(rawValue: raw) else { return }
        Task { @MainActor in
            switch type {
            case .begin:
                // Other audio started — step aside.
                player?.pause()
            case .end:
                // Other audio stopped — resume if user still wants music.
                if currentVolume > 0 { player?.play() }
            @unknown default:
                break
            }
        }
    }
}
