import AVFoundation

/// Plays short fire-and-forget UI sound effects. Designed to coexist
/// with whatever the user is already listening to (podcasts, music,
/// etc.) rather than interrupt it.
///
/// - Audio session category: `.ambient`. iOS mixes our sound with
///   other apps' audio rather than ducking or pausing them, and the
///   ringer switch silences us.
/// - Pre-loads each effect's `AVAudioPlayer` once at first play, then
///   reuses it. Replaying mid-flight rewinds via `currentTime = 0`
///   rather than allocating a new player or queueing — matches how iOS
///   UI sounds feel (cut-off-and-restart is fine for sub-second effects).
/// - Gated by `AppState.soundEffectsEnabled`; the AppState toggle is
///   the single source of truth and views just call `play(_:)`.
@MainActor
final class SoundEffectService {
    static let shared = SoundEffectService()

    /// Catalog of known effects. Add a case + matching `.mp3` in
    /// Resources/Audio/ to ship a new one.
    enum Effect: String {
        case swipe   // Card swipe in pack reveal phase.
        case tear    // Wrapper rip, fired on the .sealed -> .ripping transition.
    }

    private var players: [Effect: AVAudioPlayer] = [:]
    weak var appState: AppState?

    private init() {}

    /// Play the given effect at the user's chosen volume. Volume of 0
    /// short-circuits before touching AVAudioSession or AVAudioPlayer —
    /// "off" by way of "play at zero" matches BackgroundMusicService's
    /// pattern and keeps the slider's "0 = off" UX honest.
    /// Cheap to call repeatedly — pre-loads on first play, rewinds on
    /// subsequent calls.
    func play(_ effect: Effect) {
        let volume = appState?.soundEffectsVolume ?? 1.0
        guard volume > 0 else { return }
        AudioSession.activate()

        let player: AVAudioPlayer
        if let cached = players[effect] {
            player = cached
        } else {
            guard let url = Bundle.main.url(forResource: effect.rawValue, withExtension: "mp3"),
                  let p = try? AVAudioPlayer(contentsOf: url) else {
                return
            }
            p.prepareToPlay()
            players[effect] = p
            player = p
        }

        // Perceptual volume curve + max-amplitude cap. `AVAudioPlayer.volume`
        // is linear amplitude, but human hearing is logarithmic — squaring
        // gives the slider a perceptually-linear feel. We also cap the
        // ceiling at 0.25 amplitude (~-12 dB from full): the raw mp3
        // recorded loud and full-output was jarring against ambient app
        // sound. The cap shifts the whole curve down — slider 1.0 sounds
        // like the old slider 0.5; slider 0.5 sounds like the old 0.25.
        player.volume = (volume * volume) * 0.25
        player.currentTime = 0
        player.play()
    }
}
