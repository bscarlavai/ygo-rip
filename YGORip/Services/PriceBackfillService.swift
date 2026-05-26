import Foundation
import SwiftData

/// One-shot backfill of YGOPRODeck market prices for cards the user
/// already owns. The pack-time refresh in `PackOpeningView` keeps
/// newly-pulled cards fresh on the `.summary` phase, but cards pulled
/// before that path shipped still hold whatever price `SetSyncService`
/// set during initial bundle sync (which can be months stale, or nil
/// for printings YGOPRODeck didn't ship a price for). Without this,
/// Stats' "Collection Value" would understate forever for those users.
///
/// Runs once per install, gated by a UserDefaults flag. Scopes only to
/// **owned** cards (keys of `CollectionStats.pullCountByCardID`) and
/// only those whose price is nil or older than the freshness threshold.
/// Chunks API calls (10 in parallel, 1s gap) to stay well under
/// YGOPRODeck's 20 req/sec rate limit. Saves and bumps
/// `CollectionStats.priceRefreshTick` after each chunk so any open
/// Stats view picks up the new total mid-run.
@MainActor
struct PriceBackfillService {
    /// Bump the suffix when scheduling another backfill in the future
    /// (e.g. if we change the freshness threshold semantics or want to
    /// re-fetch for everyone).
    private static let completedFlagKey = "priceBackfillCompleted_v1"
    private static let chunkSize = 10
    private static let interChunkDelayNanos: UInt64 = 1_000_000_000  // 1s
    /// Older-than threshold for "stale enough to refresh." Matches the
    /// pack-time refresh in PackOpeningView so a card that was just
    /// pulled-and-refreshed isn't redone.
    private static let stalenessSeconds: TimeInterval = 24 * 60 * 60

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
    /// second concurrent run hammering the API. @MainActor scope means
    /// no atomicity concern.
    private static var isRunning = false

    /// Run the backfill if it hasn't been run before. Safe to call from
    /// every app launch — short-circuits on the flag, on network absence,
    /// and on a concurrent run. Catastrophic API failure (no successful
    /// fetches across all chunks) leaves the gate open so next launch
    /// retries; partial success is treated as success.
    static func runIfNeeded(modelContext: ModelContext, collectionStats: CollectionStats) async {
        guard !hasRun else { return }
        guard !isRunning else { return }
        guard NetworkMonitor.shared.isConnected else { return }
        isRunning = true
        defer { isRunning = false }

        let ownedAPIIDs = Set(collectionStats.pullCountByCardID.keys)
        guard !ownedAPIIDs.isEmpty else {
            // No owned cards yet — nothing to refresh. Still mark complete
            // so we don't re-evaluate on every launch.
            markRun()
            return
        }

        // Fetch all owned CardModels, then filter to those needing refresh.
        let allCards: [CardModel]
        do {
            allCards = try modelContext.fetch(FetchDescriptor<CardModel>(
                predicate: #Predicate { ownedAPIIDs.contains($0.apiID) }
            ))
        } catch {
            return  // SwiftData error; will retry next launch
        }

        let now = Date()
        let stale = allCards.filter { card in
            if card.priceMarket == nil { return true }
            guard let last = card.priceLastUpdated else { return true }
            return now.timeIntervalSince(last) > stalenessSeconds
        }
        guard !stale.isEmpty else {
            markRun()
            return
        }

        let api = YGOPRODeckService()
        let chunks = stride(from: 0, to: stale.count, by: chunkSize).map {
            Array(stale[$0..<min($0 + chunkSize, stale.count)])
        }
        // Track total successful price writes across the run. If we
        // finish with zero, that means YGOPRODeck was effectively
        // unreachable the whole time — don't mark complete or we'd
        // permanently skip the backfill on the next launch.
        var totalPriced = 0

        for (index, chunk) in chunks.enumerated() {
            var priced: [Int: Double] = [:]
            await withTaskGroup(of: (Int, Double)?.self) { group in
                for card in chunk {
                    let ygoID = card.ygoID
                    group.addTask {
                        guard let fetched = try? await api.fetchCard(id: ygoID),
                              let price = fetched.priceUSD else { return nil }
                        return (ygoID, price)
                    }
                }
                for await item in group {
                    if let (id, price) = item { priced[id] = price }
                }
            }

            // Write back this chunk's results. Only stamp cards that
            // actually got data; leaving the timestamp untouched on
            // unfetched cards keeps them eligible for the next backfill
            // attempt if YGOPRODeck was temporarily flaky.
            let stamp = Date()
            for card in chunk {
                guard let market = priced[card.ygoID] else { continue }
                card.priceMarket = market
                // YGOPRODeck doesn't expose a separate "low" — reuse market.
                card.priceLow = market
                card.priceLastUpdated = stamp
                totalPriced += 1
            }
            try? modelContext.save()
            collectionStats.priceRefreshTick &+= 1

            // Pause between chunks. YGOPRODeck's hard rate limit is
            // 20 req/sec — at 10 parallel in ~200ms followed by a 1s
            // gap we sit at ~10 req/sec average, well within bounds.
            if index < chunks.count - 1 {
                try? await Task.sleep(nanoseconds: interChunkDelayNanos)
            }
        }

        // Only commit the "completed" flag if we got at least one
        // successful fetch. A zero-success run almost certainly means
        // the API was unreachable — let the next launch retry.
        if totalPriced > 0 {
            markRun()
        }
    }
}
