import SwiftUI
import UserNotifications

/// Main-actor isolated: every property here is read by SwiftUI views during
/// layout, and `regenClock` hops back to the main actor to mutate pack state.
@Observable
@MainActor
final class AppState {
    // MARK: - Premium Status

    var isUnlimitedRips: Bool = false

    // MARK: - Preferences

    var hapticsEnabled: Bool {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: "hapticsEnabled") }
    }

    var gyroEnabled: Bool {
        didSet { UserDefaults.standard.set(gyroEnabled, forKey: "gyroEnabled") }
    }

    var idleHoloShimmerEnabled: Bool {
        didSet { UserDefaults.standard.set(idleHoloShimmerEnabled, forKey: "idleHoloShimmerEnabled") }
    }

    var hasOpenedFirstPack: Bool {
        didSet { UserDefaults.standard.set(hasOpenedFirstPack, forKey: "hasOpenedFirstPack") }
    }

    /// Set of sibling-app `key`s whose cross-promo modal we've already
    /// shown this user. Replaces a single `crossPromoSeen: Bool` so that
    /// adding a new sibling to `SiblingApp.crossPromoTargets` after
    /// release surfaces it for existing installs (the new key isn't in
    /// the set yet) without re-showing already-seen targets.
    var crossPromoSeenApps: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(crossPromoSeenApps), forKey: "crossPromoSeenApps")
        }
    }

    func markCrossPromoSeen(_ key: String) { crossPromoSeenApps.insert(key) }
    func isCrossPromoSeen(_ key: String) -> Bool { crossPromoSeenApps.contains(key) }

    var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }

    var unownedCardBiasEnabled: Bool {
        didSet { UserDefaults.standard.set(unownedCardBiasEnabled, forKey: "unownedCardBiasEnabled") }
    }

    var unownedCardBiasStrong: Bool {
        didSet { UserDefaults.standard.set(unownedCardBiasStrong, forKey: "unownedCardBiasStrong") }
    }

    /// The Gameplay picker (Off / Normal / Strong), bridged over the two
    /// booleans above rather than stored as its own key — same trick as Card
    /// Motion. `unownedCardBiasEnabled` already exists on every install, so
    /// every current user stays on exactly the setting they chose.
    var unownedBias: UnownedBias {
        get {
            guard unownedCardBiasEnabled else { return .off }
            return unownedCardBiasStrong ? .strong : .normal
        }
        set {
            unownedCardBiasEnabled = newValue.isEnabled
            // Not cleared when switching to .off, so toggling back on returns
            // the user to the level they picked.
            if newValue.isEnabled { unownedCardBiasStrong = (newValue == .strong) }
        }
    }

    /// Classic (swipe-to-split) or Dynamic (PackTear drag-to-tear). Stored as
    /// the raw string so a third mode wouldn't need another bridge.
    var ripMode: RipMode {
        didSet { UserDefaults.standard.set(ripMode.rawValue, forKey: "ripMode") }
    }

    /// Whether the one-time "Prefer a simpler rip?" pointer has been shown.
    var hasSeenRipStyleHint: Bool {
        didSet { UserDefaults.standard.set(hasSeenRipStyleHint, forKey: "hasSeenRipStyleHint") }
    }

    /// Playback volume for in-app sound effects (card-swipe sound, etc.).
    /// 0 = effectively off (service short-circuits before playing).
    /// Independent of the iOS Silent switch — those interactions are
    /// handled by the `.ambient` audio session category. Read by
    /// `SoundEffectService.play(_:)` via its weak `appState` reference.
    var soundEffectsVolume: Float {
        didSet { UserDefaults.standard.set(soundEffectsVolume, forKey: "soundEffectsVolume") }
    }

    /// Background loop volume, separate from `soundEffectsVolume` so either
    /// can be muted alone. 0 pauses playback rather than just muting it.
    var backgroundMusicVolume: Float {
        didSet {
            UserDefaults.standard.set(backgroundMusicVolume, forKey: "backgroundMusicVolume")
            BackgroundMusicService.shared.setVolume(backgroundMusicVolume)
        }
    }

    // MARK: - Pack Regen System

    static let maxPacks = 5
    static let regenIntervalSeconds: TimeInterval = 2 * 60 * 60  // 2 hours

    private(set) var currentPacks: Int {
        didSet { UserDefaults.standard.set(currentPacks, forKey: "currentPacks") }
    }

    private var lastRegenDate: Date {
        didSet { UserDefaults.standard.set(lastRegenDate.timeIntervalSince1970, forKey: "lastRegenDate") }
    }

    // MARK: - Lifetime Stats

    private(set) var totalPacksOpened: Int {
        didSet { UserDefaults.standard.set(totalPacksOpened, forKey: "totalPacksOpened") }
    }

    var canOpenPack: Bool {
        isUnlimitedRips || currentPacks > 0
    }

    /// Time until next pack regenerates (nil if full or unlimited)
    var timeUntilNextPack: TimeInterval? {
        guard !isUnlimitedRips, currentPacks < Self.maxPacks else { return nil }
        let elapsed = Date.now.timeIntervalSince(lastRegenDate)
        let remaining = Self.regenIntervalSeconds - elapsed
        return max(0, remaining)
    }

    /// Formatted countdown string (e.g., "1h 23m")
    var nextPackCountdown: String? {
        guard let remaining = timeUntilNextPack, remaining > 0 else { return nil }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    /// Whether the app should prompt for a rating (triggered after milestones)
    var shouldRequestReview: Bool = false

    // MARK: - Init

    init() {
        let storedPacks = UserDefaults.standard.object(forKey: "currentPacks") as? Int
        let regenTimestamp = UserDefaults.standard.double(forKey: "lastRegenDate")

        // First launch: start with max packs
        if storedPacks == nil {
            self.currentPacks = Self.maxPacks
            self.lastRegenDate = .now
        } else {
            self.currentPacks = storedPacks ?? 0
            self.lastRegenDate = regenTimestamp > 0 ? Date(timeIntervalSince1970: regenTimestamp) : .now
        }

        self.totalPacksOpened = UserDefaults.standard.integer(forKey: "totalPacksOpened")
        self.hapticsEnabled = UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true
        self.gyroEnabled = UserDefaults.standard.object(forKey: "gyroEnabled") as? Bool ?? false
        self.idleHoloShimmerEnabled = UserDefaults.standard.object(forKey: "idleHoloShimmerEnabled") as? Bool ?? true
        self.notificationsEnabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        self.unownedCardBiasEnabled = UserDefaults.standard.object(forKey: "unownedCardBiasEnabled") as? Bool ?? true
        // Shipped in 1.0.8 (was 0 with a DEBUG-only slider, so release users
        // never heard anything). Only applies to users who never set the
        // slider; anyone who did keeps their stored value.
        self.soundEffectsVolume = UserDefaults.standard.object(forKey: "soundEffectsVolume") as? Float ?? 0.25
        self.backgroundMusicVolume = UserDefaults.standard.object(forKey: "backgroundMusicVolume") as? Float ?? 0.25
        let hasOpenedFirstPack = UserDefaults.standard.bool(forKey: "hasOpenedFirstPack")
        self.hasOpenedFirstPack = hasOpenedFirstPack
        // Absent for every install predating the picker, so existing users land
        // on Normal — the exact behaviour they already had.
        self.unownedCardBiasStrong = UserDefaults.standard.object(forKey: "unownedCardBiasStrong") as? Bool ?? false
        self.ripMode = Self.resolveRipMode(hasOpenedFirstPack: hasOpenedFirstPack)
        self.hasSeenRipStyleHint = UserDefaults.standard.bool(forKey: "hasSeenRipStyleHint")
        self.crossPromoSeenApps = Set(UserDefaults.standard.stringArray(forKey: "crossPromoSeenApps") ?? [])

        // Calculate packs earned while away
        regenPacks()
    }

    /// Dynamic for new players; Classic for anyone who opened a pack before
    /// the setting existed (1.0.8), since swipe-to-split is the only rip
    /// they've known. Deliberately unlike poke-rip, which moved everyone.
    ///
    /// Written back the first time it's resolved: otherwise a new player's
    /// first pack would flip `hasOpenedFirstPack` and re-resolve them to
    /// Classic on the next launch.
    private static func resolveRipMode(hasOpenedFirstPack: Bool) -> RipMode {
        if let stored = UserDefaults.standard.string(forKey: "ripMode").flatMap(RipMode.init(rawValue:)) {
            return stored
        }
        let mode: RipMode = hasOpenedFirstPack ? .classic : .dynamic
        UserDefaults.standard.set(mode.rawValue, forKey: "ripMode")
        // Existing players get no "Prefer a simpler rip?" pointer: they're on
        // Classic, and one who switches to Dynamic on purpose shouldn't be
        // pointed straight back. (Read in init right after this, so it applies.)
        if hasOpenedFirstPack {
            UserDefaults.standard.set(true, forKey: "hasSeenRipStyleHint")
        }
        return mode
    }

    // MARK: - Collection Reset

    /// Zero out the pack-tracking state. Called from Settings → Reset
    /// Collection alongside the SwiftData and CollectionStats wipes.
    /// Uses the `private(set)` property setters so their `didSet`
    /// blocks update both the @Observable surface (so views re-render)
    /// AND UserDefaults — poking UserDefaults directly from outside
    /// (like the old reset path) leaves the in-memory @Observable
    /// values stale until the next app launch.
    ///
    /// Intentionally does NOT touch:
    /// - User preferences (haptics, sound, gyro, notifications)
    /// - Premium / `isUnlimitedRips` (the IAP unlock survives a reset)
    /// - `hasOpenedFirstPack` (avoids re-triggering the onboarding-
    ///   adjacent cross-promo flow on the user's "fresh start" first
    ///   pack — they've used the app before)
    /// - `crossPromoSeenApps` (same rationale)
    func resetCollectionCounters() {
        totalPacksOpened = 0
        currentPacks = Self.maxPacks
        lastRegenDate = .now
    }

    // MARK: - Pack Tracking

    func recordPackOpened() {
        if !hasOpenedFirstPack {
            hasOpenedFirstPack = true
        }
        if !isUnlimitedRips {
            currentPacks = max(0, currentPacks - 1)

            // If we just went below max, reset regen timer
            if currentPacks == Self.maxPacks - 1 {
                lastRegenDate = .now
            }

            // Schedule notification when packs are low
            if currentPacks == 0 {
                schedulePackNotification()
            }

            // Dropping below max starts the countdown, so the clock has to
            // (re)start here as well as on foreground — otherwise the first
            // pack spent in a session never regenerates until the app is
            // backgrounded.
            startRegenClock()
        }
        totalPacksOpened += 1

        // Prompt for review at pack milestones
        let milestones = [10, 50, 150]
        if milestones.contains(totalPacksOpened) {
            shouldRequestReview = true
        }
    }

    // MARK: - Regen clock

    /// Wakes when the next pack is due and grants it, while the app is open.
    ///
    /// Without this, `regenPacks()` ran only at launch and on
    /// `willEnterForeground`, so someone watching the countdown tick to "0m"
    /// was never granted the pack until they backgrounded the app. Sleeps
    /// until the due moment rather than polling, so an idle app does no work.
    @ObservationIgnored private var regenClock: Task<Void, Never>?

    func startRegenClock() {
        regenClock?.cancel()
        regenClock = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self,
                      !self.isUnlimitedRips,
                      self.currentPacks < Self.maxPacks
                else { return }

                // Floor of 0.5s: an already-due pack reports 0 here, and
                // sleeping zero would spin this loop.
                let wait = max(0.5, self.timeUntilNextPack ?? 0)
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                self.regenPacks()
            }
        }
    }

    func stopRegenClock() {
        regenClock?.cancel()
        regenClock = nil
    }

    /// Grant any packs earned since `lastRegenDate`. A no-op unless a full
    /// interval has elapsed. Driven from launch (`init`), foreground, and
    /// `regenClock` while the app is open.
    func regenPacks() {
        guard currentPacks < Self.maxPacks else { return }

        // A future timestamp can never be reached, so `packsEarned` stays
        // negative and packs stop regenerating permanently (only a reinstall
        // escapes). Happens when the device clock jumps forward and is later
        // corrected.
        if lastRegenDate > .now {
            lastRegenDate = .now
        }

        let elapsed = Date.now.timeIntervalSince(lastRegenDate)
        let packsEarned = Int(elapsed / Self.regenIntervalSeconds)

        if packsEarned > 0 {
            let newTotal = min(currentPacks + packsEarned, Self.maxPacks)
            currentPacks = newTotal
            // Advance regen date by the packs earned (keep remainder for next regen)
            lastRegenDate = lastRegenDate.addingTimeInterval(Double(packsEarned) * Self.regenIntervalSeconds)

            // Clear notifications if we have packs now
            if currentPacks > 0 {
                UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            }
        }
    }

    // MARK: - Notifications

    nonisolated func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func schedulePackNotification() {
        guard notificationsEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "Pack Ready!"
        content.body = "You have a pack waiting to be ripped."
        content.sound = .default

        // Fire when first pack regenerates (2 hours)
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: Self.regenIntervalSeconds,
            repeats: false
        )

        let request = UNNotificationRequest(
            identifier: "pack_ready",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().add(request)
    }
}
