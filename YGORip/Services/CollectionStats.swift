import Foundation
import Observation
import SwiftData

/// Pre-aggregated view of the user's pull history.
///
/// Replaces the always-on `@Query<PullRecord>` observers that used to live in
/// HomeView, CollectionView, and StatsView. Those queries re-fetched the
/// entire `PullRecord` table on every save (synchronously on the main actor),
/// blocking it for ~1s on heavy collections — long enough to stall the
/// pack-opening flip animation and the foil idle motion.
///
/// This object computes the same aggregates **once**, off the main actor, and
/// publishes them via `@Observable` properties. Views that need owned counts /
/// rarity breakdowns / etc. now read these properties directly — when a pack
/// is saved, `recordPulls(...)` updates the aggregates incrementally in O(N)
/// where N is the size of the pack (10), not the size of the whole table.
///
/// Trade-off: this is a parallel cache of derived data. If anything else ever
/// mutates `PullRecord` (manual cleanup, future bulk operations), call
/// `refresh(container:)` to resync from the source of truth.
@Observable
@MainActor
final class CollectionStats {
    // MARK: - Published aggregates

    /// `CardModel.apiID → number of times pulled`. Cardinality bounded by the
    /// number of unique cards in the user's collection (not total pulls).
    private(set) var pullCountByCardID: [String: Int] = [:]

    /// `CardModel.apiID → (firstPulled, lastPulled)`. Mirrors the keys of
    /// `pullCountByCardID`.
    private(set) var pullDatesByCardID: [String: (first: Date, last: Date)] = [:]

    /// `PullRecord.rarity → total pulls of that rarity`. Used by StatsView's
    /// rarity breakdown chart.
    private(set) var rarityCounts: [String: Int] = [:]

    /// `SetModel.apiID → count of unique cards owned in that set`. Used by
    /// HomeView's per-set ownership badge and StatsView's set completion list.
    private(set) var ownedUniqueBySet: [String: Int] = [:]

    /// `SetModel.apiID → set of cardAPIIDs ever pulled in that set`. Used by
    /// SetDetailView's checklist + progress bar to flag owned cards without
    /// the per-set `@Query<PullRecord>` it used to keep alive (those queries
    /// fired on every save merge, blocking main right as foilMotion was
    /// trying to start its tick loop during pack reveal).
    private(set) var ownedCardIDsBySet: [String: Set<String>] = [:]

    /// Convenience: owned card IDs for a single set, with a sensible empty
    /// fallback. Saves callers from repeating the `?? []` at every site.
    func ownedCardIDs(forSet setID: String) -> Set<String> {
        ownedCardIDsBySet[setID] ?? []
    }

    /// `SetModel.apiID → count of unique pack sessions in that set`. Used by
    /// SetDetailView's pull-history "N packs opened" line. Incremented by 1
    /// on each `recordPulls` call (one pack = one session).
    private(set) var packsOpenedBySet: [String: Int] = [:]

    /// Monotonic counter bumped whenever live prices are written back to
    /// CardModels (post-pack-summary refresh + one-shot backfill). Pure
    /// signaling field — observers like StatsView watch this so their
    /// derived "Collection Value" cache rebuilds when the underlying
    /// `priceMarket` values change. SwiftData's @Query republishes on
    /// model mutations too, but the cache trigger in StatsView is keyed
    /// on `totalPulls` (which doesn't change for a price-only update),
    /// hence this separate signal.
    var priceRefreshTick: Int = 0

    /// Sum of every pull (not unique cards). Used by StatsView's "Total Pulls"
    /// stat and as the change-detection signal for views that re-cache derived
    /// data via `.onChange(of:)`.
    private(set) var totalPulls: Int = 0

    /// Set to `true` after the first `refresh(container:)` completes. Views
    /// can use this to distinguish "still loading from disk" from "empty
    /// collection" if needed.
    private(set) var hasLoadedInitial: Bool = false

    /// Most recent refresh time. Diagnostic.
    private(set) var lastRefreshed: Date?

    // MARK: - Internal

    private var refreshTask: Task<Void, Never>?

    // MARK: - Incremental update

    /// Apply a freshly opened pack to the aggregates. Called from
    /// `PackOpeningView.savePackIfNeeded()` on the main actor at the same
    /// time we kick off the background SwiftData save — that way views see
    /// the new counts immediately, without waiting for SwiftData's auto-merge
    /// notification (which is the cascade we're working around).
    ///
    /// `now` is parameterized for testability; defaults to the current time.
    func recordPulls(_ snapshots: [PullSnapshot], setID: String, now: Date = .now) {
        for s in snapshots {
            pullCountByCardID[s.cardAPIID, default: 0] += 1

            if let existing = pullDatesByCardID[s.cardAPIID] {
                pullDatesByCardID[s.cardAPIID] = (first: existing.first, last: now)
            } else {
                pullDatesByCardID[s.cardAPIID] = (first: now, last: now)
            }

            rarityCounts[s.rarity, default: 0] += 1

            // `isNew` was computed by PackPrefetcher.generate against the live
            // PullRecord table at pack-generation time. It's the right signal
            // for "this card wasn't owned before; bump the set's unique count
            // by 1." PackPrefetcher.generate dedupes within a pack, so we
            // won't double-count when two slots roll the same card.
            if s.isNew {
                ownedUniqueBySet[setID, default: 0] += 1
            }
            ownedCardIDsBySet[setID, default: []].insert(s.cardAPIID)
        }
        totalPulls += snapshots.count
        // One recordPulls call = one pack session.
        packsOpenedBySet[setID, default: 0] += 1
    }

    // MARK: - Full refresh (initial load)

    /// Rebuild every aggregate from the source PullRecord table. Runs off the
    /// main actor via a background `ModelContext`; the published properties
    /// are written back on `@MainActor` once aggregation is done.
    ///
    /// Cheap to call multiple times — concurrent calls coalesce onto one
    /// in-flight task.
    func refresh(container: ModelContainer) {
        if let existing = refreshTask, !existing.isCancelled { return }

        // Snapshot the optimistic totalPulls so the write-back can detect
        // whether `recordPulls` ran on main while we were fetching. See the
        // race-guard comment in the MainActor.run block below.
        let startTotalPulls = totalPulls

        refreshTask = Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.refreshTask = nil } }

            // Fetch + aggregate off the main actor.
            let result = await Task.detached(priority: .utility) { () -> Aggregated in
                let bgContext = ModelContext(container)
                let descriptor = FetchDescriptor<PullRecord>()
                let records = (try? bgContext.fetch(descriptor)) ?? []

                var pullCount: [String: Int] = [:]
                var pullDates: [String: (first: Date, last: Date)] = [:]
                var rarityCounts: [String: Int] = [:]
                var ownedBySet: [String: Set<String>] = [:]
                var sessionsBySet: [String: Set<UUID>] = [:]

                for record in records {
                    let cid = record.cardAPIID
                    pullCount[cid, default: 0] += 1

                    let pulledAt = record.pulledAt
                    if let existing = pullDates[cid] {
                        pullDates[cid] = (
                            first: min(existing.first, pulledAt),
                            last: max(existing.last, pulledAt)
                        )
                    } else {
                        pullDates[cid] = (first: pulledAt, last: pulledAt)
                    }

                    rarityCounts[record.rarity, default: 0] += 1
                    ownedBySet[record.setID, default: []].insert(cid)
                    sessionsBySet[record.setID, default: []].insert(record.packSessionID)
                }

                return Aggregated(
                    pullCount: pullCount,
                    pullDates: pullDates,
                    rarityCounts: rarityCounts,
                    ownedUniqueBySet: ownedBySet.mapValues { $0.count },
                    ownedCardIDsBySet: ownedBySet,
                    packsOpenedBySet: sessionsBySet.mapValues { $0.count },
                    totalPulls: records.count
                )
            }.value

            await MainActor.run { [weak self, result, startTotalPulls] in
                guard let self else { return }
                // Race guard: if `recordPulls` ran on main while we were
                // fetching, our in-memory aggregator is optimistically ahead
                // of what's persisted. The bg fetch may or may not have seen
                // the corresponding save (the detached save Task runs in
                // parallel) — conservatively, drop this result whenever the
                // in-memory state grew during the window. The optimistic
                // values are correct for the records the user just opened,
                // and the next launch's refresh will resync.
                if self.totalPulls > startTotalPulls {
                    self.hasLoadedInitial = true
                    self.lastRefreshed = .now
                    return
                }
                self.pullCountByCardID = result.pullCount
                self.pullDatesByCardID = result.pullDates
                self.rarityCounts = result.rarityCounts
                self.ownedUniqueBySet = result.ownedUniqueBySet
                self.ownedCardIDsBySet = result.ownedCardIDsBySet
                self.packsOpenedBySet = result.packsOpenedBySet
                self.totalPulls = result.totalPulls
                self.hasLoadedInitial = true
                self.lastRefreshed = .now
            }
        }
    }

    /// Sendable bag used to ship aggregation results back to the main actor.
    private struct Aggregated: Sendable {
        let pullCount: [String: Int]
        let pullDates: [String: (first: Date, last: Date)]
        let rarityCounts: [String: Int]
        let ownedUniqueBySet: [String: Int]
        let ownedCardIDsBySet: [String: Set<String>]
        let packsOpenedBySet: [String: Int]
        let totalPulls: Int
    }
}
