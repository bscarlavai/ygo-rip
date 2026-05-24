import Foundation
import SwiftData

/// Pre-generates a pack and starts downloading its card images so the
/// reveal phase can begin as soon as the user finishes the rip gesture.
///
/// Lives outside any view so the work survives view transitions:
/// "Rip a Pack" can prefetch before the fullScreenCover finishes animating,
/// and "Open Another" can be made instant by prefetching during the summary
/// phase of the previous pack.
@MainActor
final class PackPrefetcher {
    static let shared = PackPrefetcher()

    /// Set-completion percentage at which the unowned-card bias starts to
    /// ramp in. Below this, picks are uniform — early packs feel like
    /// authentic RNG. Above it, the per-pick weight for owned cards
    /// scales linearly down to `lateGameOwnedWeight` at 100% completion.
    static let biasStartCompletion: Double = 0.60

    /// Per-pick weight for owned cards once the set is 100% complete
    /// (i.e., the floor of the scaling curve; in practice never applied
    /// because at 100% there are no unowned cards). At 0.25 the late-
    /// game ratio is 4× — an unowned card is up to 4× as likely as an
    /// equivalent owned card per slot, scaling smoothly from 1× at the
    /// bias threshold.
    static let lateGameOwnedWeight: Double = 0.25

    /// Computes the per-pick weight for owned cards given a set's
    /// completion percentage. Linear ramp from 1.0 at `biasStartCompletion`
    /// to `lateGameOwnedWeight` at 100%; flat 1.0 (no bias) below the
    /// threshold. Clamped so callers don't have to worry about invariant
    /// breakage if `ownedCount > totalCount` due to stale data.
    static func ownedWeight(forCompletion completion: Double) -> Double {
        let c = max(0, min(1.0, completion))
        guard c > biasStartCompletion else { return 1.0 }
        let progress = (c - biasStartCompletion) / (1.0 - biasStartCompletion)
        return 1.0 - progress * (1.0 - lateGameOwnedWeight)
    }

    struct Prefetched {
        let setID: String
        let pulled: [PulledCard]
        let isHotPack: Bool
        /// Completes when the FIRST card's large image is loaded. Awaiting
        /// this gates the reveal phase — once the first card image is ready,
        /// reveal can start, and the remaining images keep downloading in
        /// the background while the user flips through.
        let firstCardReady: Task<Void, Never>
        /// Completes when ALL large card images are loaded. Not awaited by
        /// the reveal gate — used for cleanup / cancellation only.
        let allLargeImagesReady: Task<Void, Never>
    }

    private(set) var pending: Prefetched?

    private init() {}

    /// Start pre-generating a pack for this set and downloading its images.
    /// No-op if a prefetch for this set is already in progress. Cancels any
    /// pending prefetch for a different set.
    ///
    /// `ownedCardIDs` enables per-pick weighting toward cards the user
    /// hasn't pulled yet (see `ownedCardSelectionWeight`). Pass an empty
    /// set to disable the bias — generation falls back to uniform sampling.
    /// `biasUnownedCards` is the user-facing toggle (Settings → Gameplay):
    /// when false, generation runs uniformly regardless of `ownedCardIDs`.
    func prefetch(
        set: SetModel,
        cards: [CardModel],
        modelContext: ModelContext,
        ownedCardIDs: Set<String> = [],
        biasUnownedCards: Bool = true
    ) {
        if let pending, pending.setID == set.apiID {
            PackTiming.mark("prefetch: already pending for \(set.apiID)")
            return
        }
        cancelPending()
        PackTiming.mark("prefetch: generate start")

        let (pulled, isHotPack) = Self.generate(
            set: set,
            cards: cards,
            modelContext: modelContext,
            ownedCardIDs: ownedCardIDs,
            biasUnownedCards: biasUnownedCards
        )
        PackTiming.mark("prefetch: generate done (\(pulled.count) cards)")
        guard !pulled.isEmpty else { return }

        let (firstTask, restTask) = Self.startImageFanOut(for: pulled)

        pending = Prefetched(
            setID: set.apiID,
            pulled: pulled,
            isHotPack: isHotPack,
            firstCardReady: firstTask,
            allLargeImagesReady: restTask
        )
    }

    // MARK: - Image preload

    /// Kick off the large-image download for a pulled pack. Returns two tasks:
    ///
    /// - `first` completes when slot 0's image is in the cache. Caller awaits
    ///   this to gate the reveal phase.
    /// - `rest` completes when all remaining slots' images are cached. Held
    ///   for cancellation only; reveal doesn't wait on it.
    ///
    /// Slot 0 is kicked off first and the rest are gated behind its completion —
    /// URLSession allows ~6 concurrent connections per host and HTTP/2
    /// multiplexing serializes bandwidth across streams, so N parallel image
    /// requests would leave slot 0 with ~1/N of the pipe. Serializing means
    /// slot 0 lands ~2-3× faster on slow connections; by the time the user
    /// has finished reading it, the rest have a head start of several seconds.
    ///
    /// Small images aren't preloaded — they aren't needed until the summary
    /// screen, where lazy loading is fine.
    static func startImageFanOut(for pulled: [PulledCard]) -> (first: Task<Void, Never>, rest: Task<Void, Never>) {
        let firstURL = pulled[0].model.imageLargeURL
        let restURLs = pulled.dropFirst().map(\.model.imageLargeURL)

        PackTiming.mark("fanOut: firstTask start (slot 0)")
        let firstTask = Task {
            _ = try? await ImageCacheService.shared.image(for: firstURL)
            PackTiming.mark("fanOut: firstTask done (slot 0 cached)")
        }
        let restTask = Task {
            await firstTask.value
            PackTiming.mark("fanOut: restTask fan-out (slots 1-\(restURLs.count))")
            await withTaskGroup(of: Void.self) { group in
                for url in restURLs {
                    group.addTask {
                        _ = try? await ImageCacheService.shared.image(for: url)
                    }
                }
            }
            PackTiming.mark("fanOut: restTask done")
        }
        return (firstTask, restTask)
    }

    /// Hand off the prefetched pack to a caller that's about to open it.
    /// Clears internal state so a subsequent prefetch can stage the next pack.
    /// Returns nil if there's no pending prefetch for this set.
    func consume(forSetID setID: String) -> Prefetched? {
        guard let p = pending, p.setID == setID else { return nil }
        pending = nil
        return p
    }

    /// Cancel and discard any pending prefetch. Safe to call when a prefetch
    /// is no longer relevant (e.g., user navigated away).
    func cancelPending() {
        pending?.firstCardReady.cancel()
        pending?.allLargeImagesReady.cancel()
        pending = nil
    }

    // MARK: - Generation

    /// Pure pack generation (no image preload). Picks cards from the set's
    /// rarity pools per the booster config and stamps the `isNew` flag based
    /// on the user's pull history.
    ///
    /// `ownedCardIDs` weights selection toward unowned cards on a curve
    /// that scales with set completion — see `ownedWeight(forCompletion:)`.
    /// Empty set = uniform sampling. `biasUnownedCards` is the user-facing
    /// toggle: when false, weighting is forced uniform regardless of
    /// `ownedCardIDs`.
    static func generate(
        set: SetModel,
        cards: [CardModel],
        modelContext: ModelContext,
        ownedCardIDs: Set<String> = [],
        biasUnownedCards: Bool = true
    ) -> ([PulledCard], Bool) {
        guard !cards.isEmpty else { return ([], false) }

        let config = PackConfig.config(for: set)
        let slots = PullRateEngine.generatePack(config: config)
        let isHotPack = PullRateEngine.lastPackWasHotPack

        let cardsByRarity = Dictionary(grouping: cards) { $0.rarity }
        let completion = Double(ownedCardIDs.count) / Double(cards.count)
        let ownedWeight = biasUnownedCards ? Self.ownedWeight(forCompletion: completion) : 1.0

        // Two-pass to keep `isNew` computation off the main-thread hot path:
        // Pass 1 picks the cards purely from in-memory rarity pools (no
        // SwiftData queries). Pass 2 runs ONE bulk fetch limited to the picked
        // IDs to flag which were already pulled before.
        //
        // The previous implementation ran a separate `fetchCount` per slot,
        // each scanning the full PullRecord table (cardAPIID isn't indexed).
        // With N total pull records across all sets, that was O(N × pack size)
        // per pack and dominated the "Rip a Pack" tap cost on collections with
        // a few hundred packs opened.

        struct Pick {
            let slotIndex: Int
            let card: CardModel
        }

        var picks: [Pick] = []
        var usedCardIDs = Set<String>()
        for (index, slot) in slots.enumerated() {
            let rarity = slot.rarity
            let fullPool: [CardModel]
            if let exact = cardsByRarity[rarity], !exact.isEmpty {
                fullPool = exact
            } else {
                // Slot rolled a rarity with no matching cards in this set.
                // Fall back to any other rare-tier rarity (rank ≥ 2) so the
                // user doesn't silently get a Common in their rare slot.
                #if DEBUG
                print("⚠️ Slot rarity '\(rarity)' has no cards in set \(set.apiID); re-rolling from rare-tier pool")
                #endif
                let rareTierPools = cardsByRarity
                    .filter { CardModel.rarityRank(for: $0.key) >= 2 }
                    .values
                fullPool = rareTierPools.randomElement() ?? cardsByRarity["Common"] ?? cards
            }
            let pool = fullPool.filter { !usedCardIDs.contains($0.apiID) }
            let usablePool = pool.isEmpty ? fullPool : pool
            guard let card = Self.weightedPick(
                from: usablePool,
                ownedCardIDs: ownedCardIDs,
                ownedWeight: ownedWeight
            ) else { continue }
            usedCardIDs.insert(card.apiID)
            picks.append(Pick(slotIndex: index, card: card))
        }

        // Bulk query: one round-trip to SQLite asking "which of these cards
        // have ANY prior pull record?" Result set is bounded by the number of
        // already-owned cards in this pack, not by total pull history.
        let pickedIDs = Set(picks.map(\.card.apiID))
        let priorPullDescriptor = FetchDescriptor<PullRecord>(
            predicate: #Predicate<PullRecord> { pickedIDs.contains($0.cardAPIID) }
        )
        let priorPullIDs: Set<String> = Set(
            (try? modelContext.fetch(priorPullDescriptor))?.map(\.cardAPIID) ?? []
        )

        let pulled: [PulledCard] = picks.map { pick in
            PulledCard(
                id: UUID(),
                model: pick.card,
                slotIndex: pick.slotIndex,
                isNew: !priorPullIDs.contains(pick.card.apiID)
            )
        }

        return (pulled, isHotPack)
    }

    /// Pick a card from `pool` using weighted random sampling. Cards present
    /// in `ownedCardIDs` get weight `ownedWeight`; others get weight 1.0.
    /// `ownedWeight` is computed once per pack via `ownedWeight(forCompletion:)`
    /// and passed in — no per-pick recomputation.
    ///
    /// Fast paths return uniform sampling when there's no ownership data or
    /// when the weight is at the no-bias floor (1.0).
    ///
    /// Implementation note: builds a weight array and linear-scans the
    /// cumulative sum. Pool sizes here are bounded by per-rarity counts
    /// (typically <50), so a linear walk is fine — the loop only runs once
    /// per slot (~10 times per pack) and is dwarfed by the SwiftData fetch
    /// for `isNew`.
    private static func weightedPick(
        from pool: [CardModel],
        ownedCardIDs: Set<String>,
        ownedWeight: Double
    ) -> CardModel? {
        guard !pool.isEmpty else { return nil }
        // Fast path: no ownership data or no bias at this completion level.
        if ownedCardIDs.isEmpty || ownedWeight >= 1.0 { return pool.randomElement() }

        let weights = pool.map { card -> Double in
            ownedCardIDs.contains(card.apiID) ? ownedWeight : 1.0
        }
        let total = weights.reduce(0, +)
        guard total > 0 else { return pool.randomElement() }

        let pick = Double.random(in: 0..<total)
        var running = 0.0
        for (idx, w) in weights.enumerated() {
            running += w
            if pick < running { return pool[idx] }
        }
        return pool.last
    }
}
