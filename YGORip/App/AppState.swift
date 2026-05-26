import SwiftUI
import UserNotifications

@Observable
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

    /// Playback volume for in-app sound effects (card-swipe sound, etc.).
    /// 0 = effectively off (service short-circuits before playing).
    /// Independent of the iOS Silent switch — those interactions are
    /// handled by the `.ambient` audio session category. Read by
    /// `SoundEffectService.play(_:)` via its weak `appState` reference.
    var soundEffectsVolume: Float {
        didSet { UserDefaults.standard.set(soundEffectsVolume, forKey: "soundEffectsVolume") }
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
        // Default to full volume. If a TestFlight build of the previous
        // "soundEffectsEnabled" bool has been seen, treat false as 0.
        if let stored = UserDefaults.standard.object(forKey: "soundEffectsVolume") as? Float {
            self.soundEffectsVolume = stored
        } else if UserDefaults.standard.object(forKey: "soundEffectsEnabled") as? Bool == false {
            self.soundEffectsVolume = 0
        } else {
            self.soundEffectsVolume = 1.0
        }
        self.hasOpenedFirstPack = UserDefaults.standard.bool(forKey: "hasOpenedFirstPack")
        self.crossPromoSeenApps = Set(UserDefaults.standard.stringArray(forKey: "crossPromoSeenApps") ?? [])

        // Calculate packs earned while away
        regenPacks()
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
        }
        totalPacksOpened += 1

        // Prompt for review at pack milestones
        let milestones = [10, 50, 150]
        if milestones.contains(totalPacksOpened) {
            shouldRequestReview = true
        }
    }

    /// Called on app foreground — calculate packs earned while away
    func regenPacks() {
        guard currentPacks < Self.maxPacks else { return }

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
