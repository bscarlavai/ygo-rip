import Foundation

/// Foil intensity tier mapped from YGO rarity.
///
/// Unlike Pokemon (where Scryfall-style image sources are pre-printed foil),
/// YGOPRODeck images are mostly flat — the shader has to render the foil
/// treatment itself. Unlike MTG (where foil is a per-printing flag stored
/// separately), every YGO rarity above Common has its own intrinsic foil
/// treatment in real life:
///
/// - **Common / Short Print** — flat, no foil.
/// - **Rare** — silver name lettering, otherwise flat.
/// - **Super Rare** — full holographic art.
/// - **Ultra Rare / Ultimate Rare** — gold name + holographic art (Ultimate
///   adds embossed texture in real life that we approximate via shader noise).
/// - **Secret Rare / Ghost / Starlight / Quarter Century / Collector's /
///   Prismatic** — full chase treatment with rainbow shimmer.
///
/// So rarity tier alone drives the treatment. No separate "isFoil" flag is
/// needed — the rarity IS the foil status.
enum FoilTreatment: String, Codable, CaseIterable, Hashable, Identifiable {
    case none           // Common, Short Print
    case subtle         // Rare (silver name)
    case holo           // Super Rare
    case illustration   // Ultra Rare, Ultimate Rare
    case secret         // Secret Rare, Ghost, Starlight, Quarter Century, Collector's, Prismatic

    var id: String { rawValue }

    /// Map a YGO rarity tier (`CardModel.rarityRank`) to a foil treatment.
    static func forYGORarity(_ tier: Int) -> FoilTreatment {
        switch tier {
        case 0:  return .none
        case 1:  return .subtle
        case 2:  return .holo
        case 3:  return .illustration
        case 4:  return .secret
        default: return .none
        }
    }

    /// Hint for the sandbox placeholder when a representative pull isn't
    /// in the user's collection yet.
    var sandboxHint: String {
        switch self {
        case .none:         return "Common · Short Print"
        case .subtle:       return "Rare (silver name)"
        case .holo:         return "Super Rare"
        case .illustration: return "Ultra · Ultimate Rare"
        case .secret:       return "Secret · Starlight · 25th Anniversary"
        }
    }
}
