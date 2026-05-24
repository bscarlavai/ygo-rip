import Foundation

/// Generates simulated YGO pack contents from hand-authored per-era configs.
///
/// Konami doesn't publish pack-composition odds; community sources (Yugipedia
/// "Ultra Rare", Cardmarket Box Math articles, YGOPRODeck "Set Theory" posts)
/// give us approximations per era. We bucket sets by `SetModel.packType`
/// (driven by `data-pipeline/build_bundle.py` from `tcg_date` + name patterns)
/// and look up a static PackConfig for each.
///
/// Public surface (PackConfig, SlotResult, generatePack, debug overrides) is
/// preserved from the sibling apps so PackOpeningView's reveal flow works
/// unchanged. Unlike MTG / Pokémon, YGO has no separate per-pull "foil"
/// flag — foil treatment is intrinsic to rarity (every Rare+ printing is
/// foil in real life), so SlotResult only carries the rarity string.
struct PullRateEngine {

    /// A single slot result from a pack opening.
    struct SlotResult {
        /// YGO rarity string, e.g. "Common", "Super Rare", "Quarter Century Secret Rare".
        let rarity: String
    }

    /// Whether the last generated pack was a Hot Pack.
    nonisolated(unsafe) static var lastPackWasHotPack = false

    /// Debug: force the next pack to be a Hot Pack.
    nonisolated(unsafe) static var forceNextHotPack = false

    /// Debug: force every slot in the next pack to a specific YGO rarity string.
    /// Resets after one pack.
    nonisolated(unsafe) static var forceNextPackRarity: String?

    /// Generate a full pack of slot results for the given config.
    /// ~1 in 400 chance of a Hot Pack where every slot is the chase tier.
    static func generatePack(config: PackConfig) -> [SlotResult] {
        if let forced = forceNextPackRarity {
            forceNextPackRarity = nil
            lastPackWasHotPack = false
            return (0..<config.cardsPerPack).map { _ in
                SlotResult(rarity: forced)
            }
        }

        let isHotPack = forceNextHotPack || Int.random(in: 1...400) == 1
        forceNextHotPack = false
        lastPackWasHotPack = isHotPack

        if isHotPack {
            return generateHotPack(config: config)
        }

        var slots: [SlotResult] = []

        // Common-tier slots (may roll Common / Short Print per the weights).
        for _ in 0..<config.commonSlots {
            let r = weightedRandom(from: config.commonSlotWeights)
            slots.append(SlotResult(rarity: r))
        }
        // Always-Rare guaranteed slot (modern packs only).
        if config.hasReverseHoloSlot {
            let r = weightedRandom(from: config.reverseHoloWeights)
            slots.append(SlotResult(rarity: r))
        }
        // Chase slot(s) — rolls from the upper tier weights.
        for _ in 0..<config.rareSlots {
            let r = weightedRandom(from: config.rareSlotWeights)
            slots.append(SlotResult(rarity: r))
        }

        return slots
    }

    /// Hot Pack — every slot is Ultra Rare or better. The community concept
    /// is "premium pack collation where every card feels rare", so we filter
    /// chase weights to rarityRank ≥ 3 (Ultra / Ultimate / Secret / Ghost /
    /// Starlight / Quarter Century / Collector's / Prismatic). For sets whose
    /// chase weights top out below Ultra (e.g. structure decks: Rare/Super/
    /// Ultra), we fall back to the full chase weights so the pack still feels
    /// distinguishable.
    private static func generateHotPack(config: PackConfig) -> [SlotResult] {
        let total = config.cardsPerPack
        let highTier = config.rareSlotWeights.filter { CardRarityRank.rank(for: $0.0) >= 3 }
        let weights = highTier.isEmpty ? config.rareSlotWeights : highTier

        return (0..<total).map { _ in
            SlotResult(rarity: weightedRandom(from: weights))
        }
    }

    private static func weightedRandom(from weights: [(String, Double)]) -> String {
        guard !weights.isEmpty else { return "Common" }
        let total = weights.reduce(0) { $0 + $1.1 }
        var roll = Double.random(in: 0..<total)
        for (rarity, weight) in weights {
            roll -= weight
            if roll <= 0 { return rarity }
        }
        return weights.last?.0 ?? "Common"
    }
}

/// Small helper that mirrors `CardModel.rarityRank(for:)` without needing the
/// `CardModel` type — engine code is pure and shouldn't import SwiftData.
private enum CardRarityRank {
    static func rank(for rarity: String) -> Int {
        switch rarity.lowercased() {
        case "common", "short print": return 0
        case "rare": return 1
        case "super rare": return 2
        case "ultra rare", "ultimate rare": return 3
        case "secret rare", "ghost rare", "starlight rare",
             "quarter century secret rare", "collector's rare",
             "prismatic secret rare", "platinum secret rare": return 4
        default: return 0
        }
    }
}

// MARK: - Pack Configuration

struct PackConfig {
    let packType: String
    let commonSlots: Int
    /// Kept for sibling-app API parity — always 0 for YGO (no Uncommon tier).
    let uncommonSlots: Int
    /// Whether this pack has a guaranteed silver-name Rare slot (modern packs).
    let hasReverseHoloSlot: Bool
    /// Number of "chase" slots (almost always 1 for YGO).
    let rareSlots: Int
    /// Weights for the Common-tier slots — usually `[("Common", 1.0)]`, but
    /// LOB-era packs sprinkle in Short Prints.
    let commonSlotWeights: [(String, Double)]
    /// Weights for the chase slot.
    let rareSlotWeights: [(String, Double)]
    /// Weights for the guaranteed Rare slot (modern packs). Usually
    /// `[("Rare", 1.0)]` since this slot is fixed-rarity.
    let reverseHoloWeights: [(String, Double)]

    var cardsPerPack: Int {
        commonSlots + uncommonSlots + (hasReverseHoloSlot ? 1 : 0) + rareSlots
    }
}

// MARK: - Hand-authored per-packType configs

extension PackConfig {

    /// Look up the config for a given set. Dispatch is by `SetModel.packType`
    /// (set at build-bundle time from `tcg_date` + name patterns).
    static func config(for set: SetModel) -> PackConfig {
        config(forPackType: set.packType)
    }

    /// Legacy entry point used by code paths that still pass a set code.
    /// Resolves the SetModel from a thread-local registry would be cleaner,
    /// but since every call site has a SetModel in scope, prefer `config(for:)`.
    static func config(forPackType packType: String) -> PackConfig {
        if let cached = ConfigCache.shared.get(packType) {
            return cached
        }
        let config = build(packType: packType)
        ConfigCache.shared.put(packType, config: config)
        return config
    }

    private static func build(packType: String) -> PackConfig {
        switch packType {
        case "lob_era":         return lobEra
        case "classic":         return classicEra
        case "modern":          return modernEra
        case "premium":         return premium
        case "tin":             return premium       // tins simulate one premium pack
        case "speed_duel":      return speedDuel
        case "battle_pack":     return battlePack
        case "world_premiere":  return worldPremiere
        case "structure":       return structureDeck
        default:                return modernEra     // safe default for unknown set types
        }
    }

    // -----------------------------------------------------------------------------
    // LOB era (2002–2004) — Original Duel Monsters.
    //
    // Real packs: 9 cards. 8 Commons (with occasional Short Print) + 1 chase slot.
    // Short Prints were ~1:3 packs in this era — common but distinctly rarer.
    // Secret Rare was the chase at roughly 1:24. No Starlight, Ultimate, Ghost, etc.
    static let lobEra = PackConfig(
        packType: "lob_era",
        commonSlots: 8,
        uncommonSlots: 0,
        hasReverseHoloSlot: false,
        rareSlots: 1,
        commonSlotWeights: [
            ("Common", 0.85),
            ("Short Print", 0.15),
        ],
        rareSlotWeights: [
            ("Rare", 0.62),
            ("Super Rare", 0.20),
            ("Ultra Rare", 0.13),
            ("Secret Rare", 0.05),
        ],
        reverseHoloWeights: []
    )

    // -----------------------------------------------------------------------------
    // Classic era (2004–2014) — GX / 5D's / Zexal.
    //
    // 9 cards. 8 Commons + 1 chase. Ultimate Rare introduced in Cybernetic
    // Revolution (2005), Ghost Rare in Phantom Darkness (2008). Slightly lower
    // Rare-slot ceiling than LOB since the rare distribution stretches further up.
    static let classicEra = PackConfig(
        packType: "classic",
        commonSlots: 8,
        uncommonSlots: 0,
        hasReverseHoloSlot: false,
        rareSlots: 1,
        commonSlotWeights: [("Common", 1.0)],
        rareSlotWeights: [
            ("Rare", 0.60),
            ("Super Rare", 0.20),
            ("Ultra Rare", 0.12),
            ("Secret Rare", 0.06),
            ("Ultimate Rare", 0.015),
            ("Ghost Rare", 0.005),
        ],
        reverseHoloWeights: []
    )

    // -----------------------------------------------------------------------------
    // Modern era (Arc-V onward, 2014–present) — current TCG booster layout.
    //
    // 9 cards: 7 Commons + 1 always-Rare (silver name) + 1 chase foil slot.
    // The chase slot rolls Super through Prismatic Secret Rare. Special tiers
    // (Starlight, Quarter Century Secret, Collector's, Prismatic) are roughly
    // 1:24 boxes combined — ~2-3% per pack.
    static let modernEra = PackConfig(
        packType: "modern",
        commonSlots: 7,
        uncommonSlots: 0,
        hasReverseHoloSlot: true,
        rareSlots: 1,
        commonSlotWeights: [("Common", 1.0)],
        rareSlotWeights: [
            ("Super Rare", 0.55),
            ("Ultra Rare", 0.25),
            ("Secret Rare", 0.16),
            ("Starlight Rare", 0.015),
            ("Quarter Century Secret Rare", 0.015),
            ("Collector's Rare", 0.005),
            ("Prismatic Secret Rare", 0.005),
        ],
        reverseHoloWeights: [("Rare", 1.0)]
    )

    // -----------------------------------------------------------------------------
    // Premium products (Legendary Collection, 25th Anniversary, Rarity Collection,
    // Maximum Gold, Gold Series, Premium Pack, Duelist Pack, etc.).
    //
    // 5-card pack, every slot foil. Real composition varies wildly per product;
    // this is an averaged distribution that lets every pull feel chase-worthy.
    static let premium = PackConfig(
        packType: "premium",
        commonSlots: 0,
        uncommonSlots: 0,
        hasReverseHoloSlot: false,
        rareSlots: 5,
        commonSlotWeights: [],
        rareSlotWeights: [
            ("Super Rare", 0.35),
            ("Ultra Rare", 0.30),
            ("Secret Rare", 0.20),
            ("Quarter Century Secret Rare", 0.07),
            ("Starlight Rare", 0.04),
            ("Collector's Rare", 0.02),
            ("Prismatic Secret Rare", 0.02),
        ],
        reverseHoloWeights: []
    )

    // -----------------------------------------------------------------------------
    // Speed Duel — a separate format with shorter packs. 4 cards: 3 Common + 1 chase.
    static let speedDuel = PackConfig(
        packType: "speed_duel",
        commonSlots: 3,
        uncommonSlots: 0,
        hasReverseHoloSlot: false,
        rareSlots: 1,
        commonSlotWeights: [("Common", 1.0)],
        rareSlotWeights: [
            ("Super Rare", 0.55),
            ("Ultra Rare", 0.30),
            ("Secret Rare", 0.15),
        ],
        reverseHoloWeights: []
    )

    // -----------------------------------------------------------------------------
    // Battle Pack — 15-card sealed-format packs from 2012–2014. Mostly commons
    // with one rare-or-better.
    static let battlePack = PackConfig(
        packType: "battle_pack",
        commonSlots: 14,
        uncommonSlots: 0,
        hasReverseHoloSlot: false,
        rareSlots: 1,
        commonSlotWeights: [("Common", 1.0)],
        rareSlotWeights: [
            ("Rare", 0.60),
            ("Super Rare", 0.25),
            ("Ultra Rare", 0.15),
        ],
        reverseHoloWeights: []
    )

    // -----------------------------------------------------------------------------
    // World Premiere — TCG-exclusive tournament/promo packs. Small + foil-heavy.
    static let worldPremiere = PackConfig(
        packType: "world_premiere",
        commonSlots: 0,
        uncommonSlots: 0,
        hasReverseHoloSlot: false,
        rareSlots: 3,
        commonSlotWeights: [],
        rareSlotWeights: [
            ("Super Rare", 0.50),
            ("Ultra Rare", 0.30),
            ("Secret Rare", 0.20),
        ],
        reverseHoloWeights: []
    )

    // -----------------------------------------------------------------------------
    // Structure Deck — pre-built decks aren't really pack-openable, but we still
    // give "rip a pack" something to do: simulate a 9-card sampler from the set.
    // Mostly Commons with one upgrade slot, matching what a sampler from a
    // Structure Deck's reprint pool would look like.
    static let structureDeck = PackConfig(
        packType: "structure",
        commonSlots: 8,
        uncommonSlots: 0,
        hasReverseHoloSlot: false,
        rareSlots: 1,
        commonSlotWeights: [("Common", 1.0)],
        rareSlotWeights: [
            ("Rare", 0.70),
            ("Super Rare", 0.20),
            ("Ultra Rare", 0.10),
        ],
        reverseHoloWeights: []
    )
}

// MARK: - Process-wide config cache

private final class ConfigCache: @unchecked Sendable {
    static let shared = ConfigCache()
    private var cache: [String: PackConfig] = [:]
    private let lock = NSLock()

    func get(_ key: String) -> PackConfig? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }
    func put(_ key: String, config: PackConfig) {
        lock.lock(); defer { lock.unlock() }
        cache[key] = config
    }
}
