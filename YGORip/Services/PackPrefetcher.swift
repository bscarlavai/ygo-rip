import Foundation
import SwiftData

/// How hard a pack leans toward cards the user hasn't pulled yet (Settings →
/// Gameplay). Ported from poke-rip, where the old on/off read stronger than it
/// was: "up to 4×" is only approached in the last sliver of a set — at 70%
/// complete the real favour was 1.23×. `strong` mostly moves the ramp's
/// **start** (0.60 → 0.35), which is what makes it felt mid-set (~1.8× at 70%).
///
/// `normal` is byte-identical to the old enabled behaviour and `off` to the old
/// disabled one, so nobody's packs change under them. (poke-rip also leans the
/// rare slot away from finished rarity tiers; YGORip's bias never had that
/// half, so only the per-card weight is here.)
enum UnownedBias: String, CaseIterable, Sendable {
    case off
    case normal
    case strong

    /// Set completion at which the bias starts to ramp in. Below this, picks
    /// are uniform so early packs feel like authentic RNG.
    var startCompletion: Double {
        switch self {
        case .off:    1.0    // never reached; `isEnabled` short-circuits first
        case .normal: 0.60
        case .strong: 0.35
        }
    }

    /// Per-pick weight for an owned card at 100% completion — the floor of the
    /// ramp. 0.25 means an unowned card is up to 4× as likely.
    var ownedFloor: Double {
        switch self {
        case .off:    1.0
        case .normal: 0.25
        case .strong: 0.15
        }
    }

    var isEnabled: Bool { self != .off }

    /// Settings footer. States the threshold because the feature is invisible
    /// until a set crosses it — someone at 40% complete would otherwise call it broken.
    var settingsFooter: String {
        switch self {
        case .off:
            "Pure pack RNG. Every card has its normal odds, duplicates and all."
        case .normal:
            "Once a set passes 60% complete, packs lean toward cards you haven't pulled yet, scaling up to 4× by 100%."
        case .strong:
            "Leans toward missing cards from 35% complete, and harder than Normal, up to about 6×. Finishes sets faster, but pulls drift further from the real product."
        }
    }
}

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

    /// Per-pick weight for owned cards at a given set completion. Linear ramp
    /// from 1.0 at the level's `startCompletion` to its `ownedFloor` at 100%;
    /// flat 1.0 below the threshold. Clamped so callers don't have to worry
    /// about `ownedCount > totalCount` from stale data.
    static func ownedWeight(forCompletion completion: Double, bias: UnownedBias = .normal) -> Double {
        guard bias.isEnabled else { return 1.0 }
        let c = max(0, min(1.0, completion))
        guard c > bias.startCompletion else { return 1.0 }
        let progress = (c - bias.startCompletion) / (1.0 - bias.startCompletion)
        return 1.0 - progress * (1.0 - bias.ownedFloor)
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
    /// `bias` is the user-facing level (Settings → Gameplay):
    /// at `.off`, generation runs uniformly regardless of `ownedCardIDs`.
    func prefetch(
        set: SetModel,
        cards: [CardModel],
        modelContext: ModelContext,
        ownedCardIDs: Set<String> = [],
        bias: UnownedBias = .normal
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
            bias: bias
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
    /// The summary grid renders each card's SMALL image, a different cache
    /// key than the large reveal image. Those small URLs are warmed in the
    /// background `rest` task too — by the time the user finishes flipping
    /// through the reveal, they're in the memory cache, so the summary grid
    /// paints instantly instead of flashing skeletons for ~1s. Small images
    /// are tiny, so they don't meaningfully compete with the large reveal
    /// downloads for bandwidth.
    static func startImageFanOut(for pulled: [PulledCard]) -> (first: Task<Void, Never>, rest: Task<Void, Never>) {
        let firstURL = pulled[0].model.imageLargeURL
        let restURLs = pulled.dropFirst().map(\.model.imageLargeURL)
        let smallURLs = pulled.map(\.model.imageSmallURL)

        PackTiming.mark("fanOut: firstTask start (slot 0)")
        let firstTask = Task {
            _ = try? await ImageCacheService.shared.image(for: firstURL)
            PackTiming.mark("fanOut: firstTask done (slot 0 cached)")
        }
        let restTask = Task {
            await firstTask.value
            PackTiming.mark("fanOut: restTask fan-out (slots 1-\(restURLs.count) + \(smallURLs.count) summary thumbs)")
            await withTaskGroup(of: Void.self) { group in
                for url in restURLs {
                    group.addTask {
                        _ = try? await ImageCacheService.shared.image(for: url)
                    }
                }
                for url in smallURLs {
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
    /// Empty set = uniform sampling. `bias` is the user-facing level; at `.off`
    /// weighting is forced uniform regardless of `ownedCardIDs`.
    static func generate(
        set: SetModel,
        cards: [CardModel],
        modelContext: ModelContext,
        ownedCardIDs: Set<String> = [],
        bias: UnownedBias = .normal
    ) -> ([PulledCard], Bool) {
        guard !cards.isEmpty else { return ([], false) }

        let config = PackConfig.config(for: set)
        let slots = PullRateEngine.generatePack(config: config)
        let isHotPack = PullRateEngine.lastPackWasHotPack

        let cardsByRarity = Dictionary(grouping: cards) { $0.rarity }
        let completion = Double(ownedCardIDs.count) / Double(cards.count)
        let ownedWeight = Self.ownedWeight(forCompletion: completion, bias: bias)

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

        // Pre-bucket cards by `rarityTier` so per-slot tier-fallback lookups
        // are cheap. Built once per pack.
        let cardsByTier: [Int: [CardModel]] = Dictionary(grouping: cards) {
            CardModel.rarityRank(for: $0.rarity)
        }

        var picks: [Pick] = []
        var usedCardIDs = Set<String>()
        for (index, slot) in slots.enumerated() {
            let rarity = slot.rarity
            let requestedTier = CardModel.rarityRank(for: rarity)

            // Priority chain for picking a card. Each step filters to unused
            // cards; first non-empty result wins. **Never reuse a card within
            // the same pack** — if every step empties out, the slot drops.
            //
            //   1. Exact rarity-string match (preferred — "Super Rare" → only Super Rares).
            //   2. Same rarity tier (covers DT Parallels, Mosaic, Starfoil, etc.).
            //   3. Adjacent tier (within ±1) — defensive fallback for sets with
            //      sparse rarity coverage (e.g. JUSH has no Commons, so Common
            //      slots draw from tier-1 Rares).
            //   4. Anything left.
            //
            // This is what fixes the "JUSH gives 3× A Case for K9" bug: the
            // old fallback picked a random rarity bucket per slot, then reused
            // cards when small buckets ran dry. Tier-aware unused-only lookups
            // make every slot fill from distinct cards.
            func unused(_ pool: [CardModel]) -> [CardModel] {
                pool.filter { !usedCardIDs.contains($0.apiID) }
            }

            var candidates = unused(cardsByRarity[rarity] ?? [])
            if candidates.isEmpty {
                candidates = unused(cardsByTier[requestedTier] ?? [])
            }
            if candidates.isEmpty {
                let adjacent = cardsByTier.flatMap { tier, list in
                    abs(tier - requestedTier) <= 1 ? list : []
                }
                candidates = unused(adjacent)
            }
            if candidates.isEmpty {
                candidates = unused(cards)
            }

            guard let card = Self.weightedPick(
                from: candidates,
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
