import AVFoundation

/// Single owner of the shared `AVAudioSession` configuration.
///
/// `SoundEffectService` and `BackgroundMusicService` used to configure the
/// session independently, each behind its own private `sessionConfigured`
/// flag. Because `SoundEffectService` configures lazily — on the first sound
/// effect played, not at launch — the sequence in a normal session was:
///
///   1. launch → music service calls `setCategory` + `setActive(true)`,
///      starts its looping player
///   2. first pack rip → sound effect service calls `setCategory` +
///      `setActive(true)` *again*, underneath the running music player
///   3. the music player stops, and nothing ever restarts it
///
/// Neither service observed `interruptionNotification`, so there was no
/// recovery path: the music stayed dead until the app was relaunched. It
/// presented as "background music stops after I open a pack" (found in
/// poke-rip, where this was ported from).
///
/// Configuring in exactly one place makes step 2 impossible.
@MainActor
enum AudioSession {
    private static var configured = false

    /// Activate the shared session as `.ambient` — we never interrupt the
    /// user's own audio, and the ringer switch silences us.
    ///
    /// Idempotent by design: call it from anywhere, as many times as you
    /// like. Only the first call touches `AVAudioSession`.
    static func activate() {
        guard !configured else { return }
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        try? AVAudioSession.sharedInstance().setActive(true)
        configured = true
    }

    /// Re-activate after a system interruption (phone call, Siri, alarm)
    /// has ended. Distinct from `activate()`: the session was deactivated
    /// out from under us, so the `configured` guard must not short-circuit.
    static func reactivateAfterInterruption() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}
