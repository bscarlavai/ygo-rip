import Foundation
import SwiftData

/// JSON backup of the user's irreplaceable data: their pull history (the whole
/// collection is derived from `PullRecord`) plus favorites/wishlist (user flags
/// on `CardModel`). `CardModel`/`SetModel` themselves re-seed from the bundle, so
/// only the user-authored bits need backing up.
///
/// The backup exists so a future schema migration that wipes the store doesn't
/// take the user's collection with it — we offer to restore it on next launch.
///
/// Safeguards (the things that keep restore from misbehaving):
/// - On-disk format is a **version-tagged, model-decoupled DTO**, so a future
///   model change can't make old backups unreadable.
/// - Writes are **atomic** (`.atomic`), so a crash mid-write never truncates it.
/// - The file always mirrors *desired* state (rewritten after each pack and on
///   backgrounding; emptied on intentional reset), so "store empty + backup
///   non-empty" only ever means an *unintended* wipe.
/// - Restore is non-destructive and idempotent: gated on the store having zero
///   pulls, so it never duplicates and never touches a healthy store. Surfaced
///   as a user prompt (see ContentView) rather than applied silently.
enum CollectionBackup {
    static let currentVersion = 1

    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "collection-backup.json")
    }

    struct RestoreInfo {
        let recordCount: Int
        let savedAt: Date
    }

    // MARK: - DTO (decoupled from the @Models on purpose)

    private struct Snapshot: Codable {
        var cardAPIID: String
        var setID: String
        var rarity: String
        var pulledAt: Date
        var packSessionID: UUID
        var isNew: Bool
        var slotIndex: Int
    }

    private struct BackupFile: Codable {
        var version: Int
        var savedAt: Date
        var records: [Snapshot]
        // Optional so a backup missing these keys still decodes.
        var favoriteCardIDs: [String]?
        var wishlistCardIDs: [String]?
    }

    // MARK: - Write

    /// Snapshot the full user state (pulls + favorites + wishlist) and write it
    /// atomically. Call off the main actor after a pack save and on backgrounding.
    static func write(from context: ModelContext, savedAt: Date = .now) {
        let records = (try? context.fetch(FetchDescriptor<PullRecord>())) ?? []

        // Safety: never let an automatic write downgrade a backup that has pull
        // history to an empty one. This happens if the app is backgrounded (or
        // relaunched) while the store is wiped and a restore is still pending —
        // without this guard that write would destroy the recovery data. The
        // only intentional paths to an empty backup are clear() and delete().
        if records.isEmpty, let existing = loadFile(), !existing.records.isEmpty {
            return
        }

        let snapshots = records.map {
            Snapshot(cardAPIID: $0.cardAPIID, setID: $0.setID, rarity: $0.rarity,
                     pulledAt: $0.pulledAt, packSessionID: $0.packSessionID,
                     isNew: $0.isNew, slotIndex: $0.slotIndex)
        }
        // Predicate fetch returns only the handful of flagged cards, not the
        // entire (potentially thousands of rows) card table.
        let flagged = (try? context.fetch(FetchDescriptor<CardModel>(
            predicate: #Predicate { $0.isFavorite || $0.isWishlisted }
        ))) ?? []
        let favorites = flagged.filter(\.isFavorite).map(\.apiID)
        let wishlist = flagged.filter(\.isWishlisted).map(\.apiID)

        writeFile(BackupFile(version: currentVersion, savedAt: savedAt,
                             records: snapshots,
                             favoriteCardIDs: favorites, wishlistCardIDs: wishlist))
    }

    /// Overwrite the backup with an empty snapshot. Called on an intentional
    /// reset so restore never resurrects deliberately-deleted data.
    static func clear(savedAt: Date = .now) {
        writeFile(BackupFile(version: currentVersion, savedAt: savedAt,
                             records: [], favoriteCardIDs: [], wishlistCardIDs: []))
    }

    /// Permanently remove the backup file. Used when the user is offered a
    /// restore and chooses to start fresh instead. A backup can't coexist with a
    /// deliberately-empty store — the next pack would overwrite it anyway — so we
    /// delete it outright (after an explicit in-app confirmation) rather than
    /// leaving a stale file that would offer to restore again next launch.
    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func writeFile(_ file: BackupFile) {
        do {
            let data = try JSONEncoder().encode(file)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort insurance — a write failure must never affect the
            // user's real save. Swallow; the next write will retry.
            print("[CollectionBackup] write failed: \(error)")
        }
    }

    // MARK: - Lazy user-flag lookup (for re-seeding cards after a wipe)

    /// Favorited card IDs from the backup. `SetSyncService` consults this when
    /// inserting freshly-seeded `CardModel` rows so favorites survive a wipe even
    /// though the cards themselves get rebuilt from the bundle. Reads the file
    /// each call (cards sync rarely); returns empty on any failure.
    static func favoriteIDs() -> Set<String> { Set(loadFile()?.favoriteCardIDs ?? []) }
    static func wishlistIDs() -> Set<String> { Set(loadFile()?.wishlistCardIDs ?? []) }

    // MARK: - Restore

    /// Returns restore info **only** when the store has zero pulls and the backup
    /// has some — i.e. an unintended wipe. Drives the launch prompt; nil means
    /// "nothing to offer". Pure read, safe to call anytime.
    static func availableRestore(context: ModelContext) -> RestoreInfo? {
        var probe = FetchDescriptor<PullRecord>()
        probe.fetchLimit = 1
        let existing = (try? context.fetch(probe)) ?? []
        guard existing.isEmpty,
              let file = loadFile(), !file.records.isEmpty
        else { return nil }
        return RestoreInfo(recordCount: file.records.count, savedAt: file.savedAt)
    }

    /// The backup's contents regardless of store state — for showing status in
    /// Settings (vs `availableRestore`, which only returns non-nil on a wipe).
    static func lastBackup() -> RestoreInfo? {
        guard let file = loadFile(), !file.records.isEmpty else { return nil }
        return RestoreInfo(recordCount: file.records.count, savedAt: file.savedAt)
    }

    /// Re-insert backed-up pulls and re-apply favorites/wishlist. Idempotent and
    /// non-destructive: bails if the store already has pulls (never duplicates),
    /// and on any decode failure. Returns the number of pulls restored.
    @discardableResult
    static func restore(context: ModelContext) -> Int {
        var probe = FetchDescriptor<PullRecord>()
        probe.fetchLimit = 1
        let existing = (try? context.fetch(probe)) ?? []
        guard existing.isEmpty else { return 0 }

        guard let file = loadFile(), !file.records.isEmpty else { return 0 }

        for s in file.records {
            context.insert(PullRecord(
                cardAPIID: s.cardAPIID, setID: s.setID, rarity: s.rarity,
                pulledAt: s.pulledAt, packSessionID: s.packSessionID,
                isNew: s.isNew, slotIndex: s.slotIndex
            ))
        }

        // Re-apply favorites/wishlist to any cards already re-seeded. Cards that
        // sync in later get flagged by SetSyncService via favoriteIDs()/wishlistIDs().
        let favorites = Set(file.favoriteCardIDs ?? [])
        let wishlist = Set(file.wishlistCardIDs ?? [])
        if !favorites.isEmpty || !wishlist.isEmpty {
            let cards = (try? context.fetch(FetchDescriptor<CardModel>())) ?? []
            for card in cards {
                if favorites.contains(card.apiID) { card.isFavorite = true }
                if wishlist.contains(card.apiID) { card.isWishlisted = true }
            }
        }

        do {
            try context.save()
        } catch {
            print("[CollectionBackup] restore save failed: \(error)")
            return 0
        }
        print("[CollectionBackup] restored \(file.records.count) pulls, \(favorites.count) favorites, \(wishlist.count) wishlist")
        return file.records.count
    }

    private static func loadFile() -> BackupFile? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(BackupFile.self, from: data)
    }
}
