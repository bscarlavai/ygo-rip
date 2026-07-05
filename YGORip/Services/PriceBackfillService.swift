import Foundation
import SwiftData

/// One-shot backfill of market prices for the user's owned cards, via the
/// per-set batch price API (`PriceRefresh`). Set-open / card-inspect / pack
/// paths keep freshly-touched sets current, but a user can own cards from sets
/// they haven't revisited since this shipped; without this, Stats' "Collection
/// Value" would keep showing pre-migration prices for those until a revisit.
///
/// Runs once per install, gated by a UserDefaults flag. Iterates the **distinct
/// sets** among owned cards (`CollectionStats.pullCountByCardID` → each card's
/// `setID`) and refreshes each set with one request — far fewer calls than the
/// old per-card YGOPRODeck backfill. Leaves the gate open if the API was
/// unreachable so the next launch retries.
@MainActor
struct PriceBackfillService {
    /// Bump the suffix when scheduling another backfill in the future (e.g. if we
    /// change the freshness threshold semantics or want to re-fetch for everyone).
    /// `_v4` = switched from per-card YGOPRODeck to the per-set price API (also
    /// the first pass that fills the restored `priceLow` from real market data).
    private static let completedFlagKey = "priceBackfillCompleted_v4"
    /// Gentle spacing between set requests. Well under the API's 200/60s limit.
    private static let interSetDelayNanos: UInt64 = 250_000_000  // 0.25s

    static var hasRun: Bool {
        UserDefaults.standard.bool(forKey: completedFlagKey)
    }

    static func markRun() {
        UserDefaults.standard.set(true, forKey: completedFlagKey)
    }

    /// Reset the gate. Wired up to Settings → Reset Collection so a
    /// fresh start re-runs the backfill if/when the user re-pulls.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: completedFlagKey)
    }

    /// In-flight guard. `.task` on HomeView fires on each appear; without
    /// this, navigating away and back during a backfill would spawn a
    /// second concurrent run. @MainActor scope means no atomicity concern.
    private static var isRunning = false

    /// Run the backfill if it hasn't been run before. Safe to call from every app
    /// launch — short-circuits on the flag, on network absence, and on a
    /// concurrent run. Marks complete only if every owned set was reachable; if
    /// any set couldn't reach the API, the gate stays open for the next launch.
    static func runIfNeeded(modelContext: ModelContext, collectionStats: CollectionStats) async {
        guard !hasRun else { return }
        guard !isRunning else { return }
        guard NetworkMonitor.shared.isConnected else { return }
        isRunning = true
        defer { isRunning = false }

        let ownedAPIIDs = Set(collectionStats.pullCountByCardID.keys)
        guard !ownedAPIIDs.isEmpty else {
            // No owned cards yet — nothing to refresh. Still mark complete so we
            // don't re-evaluate on every launch.
            markRun()
            return
        }

        let ownedCards: [CardModel]
        do {
            ownedCards = try modelContext.fetch(FetchDescriptor<CardModel>(
                predicate: #Predicate { ownedAPIIDs.contains($0.apiID) }
            ))
        } catch {
            return  // SwiftData error; will retry next launch
        }

        let ownedSetIDs = Set(ownedCards.map(\.setID)).sorted()
        var allReachable = true

        for (index, setID) in ownedSetIDs.enumerated() {
            // PriceRefresh applies to the whole set on disk and bumps
            // priceRefreshTick, so an open Stats view picks up the new total.
            let reached = await PriceRefresh.refresh(
                setID: setID,
                modelContext: modelContext,
                collectionStats: collectionStats
            )
            if !reached { allReachable = false }

            if index < ownedSetIDs.count - 1 {
                try? await Task.sleep(nanoseconds: interSetDelayNanos)
            }
        }

        // Only commit "completed" if nothing was left unreachable; otherwise let
        // the next launch retry the sets that failed (fresh ones no-op instantly).
        if allReachable {
            markRun()
        }
    }
}
