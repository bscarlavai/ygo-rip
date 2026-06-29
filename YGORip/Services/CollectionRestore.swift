import Foundation
import SwiftData

/// Fully reconstitutes the collection after a wipe, so a restore lands the user
/// *exactly where they were* — not a shell that fills in as they browse.
///
/// `CollectionBackup.restore` only brings back ownership (`PullRecord`s). The
/// cards themselves (`CardModel`, with prices) are cache that re-seeds from the
/// bundle per-set and lazily. This coordinator drives the rest:
///   1. restore pull history (+ favorites/wishlist) from the backup,
///   2. re-seed every owned set's cards from the bundle (instant), and
///   3. refresh live market prices for the owned cards.
@MainActor
enum CollectionRestore {
    /// Restores from backup and kicks off full reconstitution. Returns the number
    /// of pull records restored (0 if there was nothing to restore). The pull
    /// records + stats are available on return; card re-seeding and live price
    /// refresh continue in the background and surface reactively.
    @discardableResult
    static func perform(modelContext: ModelContext, collectionStats: CollectionStats) async -> Int {
        let count = CollectionBackup.restore(context: modelContext)
        guard count > 0 else { return 0 }
        collectionStats.refresh(container: modelContext.container)

        // Owned sets/cards, from the just-restored history.
        let records = (try? modelContext.fetch(FetchDescriptor<PullRecord>())) ?? []
        let ownedSetIDs = Set(records.map(\.setID))
        let ownedCardIDs = Set(records.map(\.cardAPIID))
        guard !ownedSetIDs.isEmpty else { return count }

        // Reconstitute in the background so the prompt dismisses immediately; the
        // grid fills in reactively as cards re-seed, prices as they refresh.
        Task { @MainActor in
            await reconstitute(
                ownedSetIDs: ownedSetIDs,
                ownedCardIDs: ownedCardIDs,
                modelContext: modelContext,
                collectionStats: collectionStats
            )
        }
        return count
    }

    private static func reconstitute(
        ownedSetIDs: Set<String>,
        ownedCardIDs: Set<String>,
        modelContext: ModelContext,
        collectionStats: CollectionStats
    ) async {
        // 1. Re-seed every owned set's cards from the bundle (instant per set).
        //    syncCards skips sets already cached, so this is cheap. Favorites/
        //    wishlist are re-applied here too (SetSyncService consults the backup).
        let container = modelContext.container
        for setID in ownedSetIDs {
            try? await SetSyncService.shared.syncCards(forSetID: setID, container: container)
        }
        collectionStats.refresh(container: container)

        // 2. Live prices. Re-seeded cards carry bundle prices stamped "now", which
        //    the backfill would treat as fresh and skip — so explicitly mark the
        //    owned cards stale, then run the backfill to pull current market data.
        let owned = (try? modelContext.fetch(FetchDescriptor<CardModel>(
            predicate: #Predicate { ownedCardIDs.contains($0.apiID) }
        ))) ?? []
        for card in owned { card.priceLastUpdated = nil }
        try? modelContext.save()

        PriceBackfillService.reset()
        await PriceBackfillService.runIfNeeded(
            modelContext: modelContext,
            collectionStats: collectionStats
        )
    }
}
