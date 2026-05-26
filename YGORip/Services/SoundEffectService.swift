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
    }

    private var players: [Effect: AVAudioPlayer] = [:]
    private var sessionConfigured = false
    weak var appState: AppState?

    private init() {}

    /// Play the given effect at the user's chosen volume. Volume of 0
    /// short-circuits before touching AVAudioSession or AVAudioPlayer —
    /// "off" by way of "play at zero" matches the BackgroundMusicService
    /// pattern and keeps the slider's "0 = off" UX honest.
    /// Cheap to call repeatedly — pre-loads on first play, rewinds on
    /// subsequent calls.
    func play(_ effect: Effect) {
        let volume = appState?.soundEffectsVolume ?? 1.0
        guard volume > 0 else { return }
        configureSession()

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

        player.volume = volume
        player.currentTime = 0
        player.play()
    }

    /// Configure the shared audio session for `.ambient` playback. Safe
    /// to call repeatedly — short-circuits after the first call. If a
    /// `BackgroundMusicService` (or anything else) has already set the
    /// session category, this is a no-op since both want `.ambient`.
    private func configureSession() {
        guard !sessionConfigured else { return }
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        try? AVAudioSession.sharedInstance().setActive(true)
        sessionConfigured = true
    }
}
