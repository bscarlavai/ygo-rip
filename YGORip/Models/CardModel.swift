import Foundation
import SwiftData

@Model
final class CardModel {
    /// Per-printing unique key: "<setCode>:<ygoID>" (e.g. "LOB:89631139").
    /// A single YGO card ID can appear in many sets — we model it per-printing
    /// because rarity is set-specific.
    @Attribute(.unique) var apiID: String

    /// Numeric YGOPRODeck card ID. Used to construct image URLs deterministically.
    var ygoID: Int

    var name: String
    /// Per-printing code, e.g. "LOB-EN001".
    var number: String
    /// Per-printing rarity: "Common", "Rare", "Super Rare", "Ultra Rare", "Secret Rare", ...
    var rarity: String
    var setID: String

    // YGO gameplay fields
    /// Full type string, e.g. "Effect Monster", "Spell Card", "Trap Card", "Fusion Monster".
    var cardType: String
    /// Frame variant, e.g. "normal", "effect", "fusion", "synchro", "xyz", "link", "spell", "trap".
    var frameType: String
    /// Card text / effect description.
    var desc: String

    var attribute: String?   // "LIGHT", "DARK", "WATER", "FIRE", "EARTH", "WIND", "DIVINE"
    var race: String?        // "Dragon", "Spellcaster", "Warrior", ... (or Spell/Trap subtype)
    var level: Int?          // Level / Rank / Link Rating depending on frame
    var atk: Int?
    var def: Int?            // Nil for Link Monsters
    var archetype: String?
    var scale: Int?          // Pendulum scale
    var linkval: Int?        // Link Rating
    /// CSV of link arrow positions, e.g. "Top,Bottom-Left,Right". Pendulum/Link only.
    var linkmarkersRaw: String?

    // TCGPlayer prices (cached, refreshed on inspect)
    var priceMarket: Double?
    var priceLow: Double?
    var priceLastUpdated: Date?
    var tcgPlayerURL: String?

    // User state
    var isFavorite: Bool = false
    var isWishlisted: Bool = false

    var linkmarkers: [String] {
        guard let raw = linkmarkersRaw, !raw.isEmpty else { return [] }
        return raw.split(separator: ",").map(String.init)
    }

    /// 0=common, 1=rare, 2=super, 3=ultra/ultimate, 4=secret/ghost/starlight/QC/collector/prismatic.
    /// Five tiers map cleanly to FoilTreatment's five buckets.
    var rarityTier: Int { Self.rarityRank(for: rarity) }
    var rarityRank: Int { Self.rarityRank(for: rarity) }

    static func rarityRank(for rarity: String) -> Int {
        switch rarity.lowercased() {
        // Tier 0: Common / Common-equivalent (flat, no foil).
        case "common", "short print", "super short print":
            return 0

        // Tier 1: Rare / Rare-equivalent foil variants (silver-name level).
        // Parallel Rares = foil-treatment variants of base-rarity cards in
        // their respective sets (DT arcade, Mattel promos, etc.). Mosaic /
        // Starfoil / Shatterfoil are Battle Pack / Star Pack mass-foil
        // variants applied to common-slot cards.
        case "rare",
             "normal parallel rare",
             "duel terminal normal parallel rare",
             "mosaic rare",
             "starfoil rare",
             "shatterfoil rare":
            return 1

        // Tier 2: Super Rare-equivalent.
        case "super rare",
             "duel terminal rare parallel rare",
             "duel terminal super parallel rare":
            return 2

        // Tier 3: Ultra / Ultimate Rare-equivalent.
        case "ultra rare",
             "ultimate rare",
             "platinum rare",
             "ultra parallel rare",
             "duel terminal ultra parallel rare",
             "ultra rare (pharaoh's rare)":
            return 3

        // Tier 4: Chase tier (Secret Rare and above).
        case "secret rare",
             "ghost rare",
             "starlight rare",
             "quarter century secret rare",
             "collector's rare", "collectors rare",
             "prismatic secret rare",
             "platinum secret rare",
             "gold rare",
             "gold secret rare",
             "premium gold rare",
             "ghost/gold rare",
             "grand master rare",
             "ultra secret rare",
             "extra secret rare",
             "extra secret",
             "10000 secret rare":
            return 4

        // Unknown / garbage rarity strings ("New", "2", "Cr", region notes,
        // etc.) — treat as Common-tier. They're displayed verbatim in inspect
        // so the rarity field still tells the truth about what YGOPRODeck
        // labeled the printing; this rank just makes them pullable.
        default:
            return 0
        }
    }

    /// Full-size image URL on YGOPRODeck's CDN. Deterministic from numeric ID.
    /// Hotlinking is forbidden — `ImageCacheService` must download once and
    /// cache to disk; never re-fetch the same URL twice.
    var imageLargeURL: String { "https://images.ygoprodeck.com/images/cards/\(ygoID).jpg" }
    var imageSmallURL: String { "https://images.ygoprodeck.com/images/cards_small/\(ygoID).jpg" }

    /// Whether this card should show holo shimmer effects.
    var isHolo: Bool { rarityTier >= 2 }
    /// Whether this card qualifies as "rare" (for shadows, badges, etc.).
    var isRare: Bool { rarityTier >= 1 }

    /// Whether this is a monster card (vs. Spell or Trap). Drives whether to
    /// render attribute / level / ATK / DEF in the inspect view.
    var isMonster: Bool {
        let f = frameType.lowercased()
        return !(f == "spell" || f == "trap")
    }

    init(
        apiID: String,
        ygoID: Int,
        name: String,
        number: String,
        rarity: String,
        setID: String,
        cardType: String,
        frameType: String,
        desc: String = "",
        attribute: String? = nil,
        race: String? = nil,
        level: Int? = nil,
        atk: Int? = nil,
        def: Int? = nil,
        archetype: String? = nil,
        scale: Int? = nil,
        linkval: Int? = nil,
        linkmarkersRaw: String? = nil
    ) {
        self.apiID = apiID
        self.ygoID = ygoID
        self.name = name
        self.number = number
        self.rarity = rarity
        self.setID = setID
        self.cardType = cardType
        self.frameType = frameType
        self.desc = desc
        self.attribute = attribute
        self.race = race
        self.level = level
        self.atk = atk
        self.def = def
        self.archetype = archetype
        self.scale = scale
        self.linkval = linkval
        self.linkmarkersRaw = linkmarkersRaw
    }
}
