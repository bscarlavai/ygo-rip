import SwiftUI

/// Per-era foil color palette for the pack wrapper.
///
/// Yu-Gi-Oh packs are mostly dark and busy with logo art; for our generated
/// pack wrapper we keep the same dark-dominant convention as the sibling
/// apps. Each era has its own foil identity color reserved for `mid`,
/// `highlight`, and `foil` so the iridescent shimmer reads as that era's
/// signature against a uniformly dark base:
///
/// - **Original / LOB era** — classic gold-on-brown (Yu-Gi-Oh's original card-back vibe).
/// - **GX era** — red + yellow (Jaden's Slifer Red dorm).
/// - **5D's era** — electric blue + chrome (Synchro / signer dragon).
/// - **Zexal era** — gold + violet (Astral / Number cards).
/// - **Arc-V era** — red + green (Yuya's pendulum split).
/// - **VRAINS era** — cyan + magenta (LINK VRAINS network aesthetic).
/// - **Sevens / Go Rush era** — hot pink + gold (Rush Duel).
/// - **Modern (2023+)** — deep purple + gold (25th Anniversary).
///
/// Non-era shelves get their own treatments — Premium leans full-gold, Tin
/// leans chrome, Speed Duel goes neon, etc.
struct PackPalette: Equatable {
    /// Deepest tint — corners, ambient shadow, inner foil tone.
    let deep: Color
    /// Body color — the dominant pack hue.
    let body: Color
    /// Mid-tone — lighter band in the iridescent gradient.
    let mid: Color
    /// Brightest shimmer color in the gradient and specular sweep.
    let highlight: Color
    /// Iridescent foil rim accent.
    let foil: Color

    var bodyGradient: LinearGradient {
        LinearGradient(
            colors: [deep, body, mid, highlight, mid, body, deep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var rimGradient: LinearGradient {
        LinearGradient(
            colors: [highlight, foil, mid, foil, highlight],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Apply a hue rotation (degrees) to every color in the palette. Used
    /// for per-set variation on top of the era base palette.
    func hueShifted(by degrees: Double) -> PackPalette {
        PackPalette(
            deep:      deep.hueShifted(by: degrees),
            body:      body.hueShifted(by: degrees),
            mid:       mid.hueShifted(by: degrees),
            highlight: highlight.hueShifted(by: degrees),
            foil:      foil.hueShifted(by: degrees)
        )
    }

    /// Look up the palette for a given set. Combines an era / shelf base
    /// palette with a deterministic per-set hue shift so every set gets a
    /// visually distinct foil pack even within the same era.
    static func palette(for set: SetModel) -> PackPalette {
        let base = palette(forSeries: set.series, shelf: set.shelf)
        let shift = hueShift(for: set.apiID)
        return base.hueShifted(by: shift)
    }

    /// Deterministic hue offset (-22°...+22°) from a set's apiID. Stable
    /// across launches (uses byte sum, not Swift's randomized hashValue).
    /// Range is tight so the era's identity stays recognizable.
    private static func hueShift(for setID: String) -> Double {
        let sum = setID.utf8.reduce(0) { $0 &+ Int($1) }
        return Double(sum % 45) - 22  // -22 ... +22
    }

    /// Look up a palette by series label (from `SetModel.series`) and shelf.
    /// Series labels match the strings produced by `SetModel.seriesLabel(era:shelf:)`.
    static func palette(forSeries series: String, shelf: String = "") -> PackPalette {
        // Era-based palettes (driven by SetModel.series).
        switch series {
        case "Original Era":    return .lobEra
        case "GX Era":          return .gxEra
        case "5D's Era":        return .fivedsEra
        case "Zexal Era":       return .zexalEra
        case "Arc-V Era":       return .arcvEra
        case "VRAINS Era":      return .vrainsEra
        case "Sevens Era":      return .sevensEra
        case "Modern":          return .modernEra
        case "Premium":         return .premium
        case "Structure Decks": return .structureDeck
        case "Collector Tins":  return .tin
        case "Speed Duel":      return .speedDuel
        case "Battle Pack":     return .battlePack
        case "World Premiere":  return .worldPremiere
        default:                break
        }

        // Shelf-based fallback for anything that slipped through.
        switch shelf {
        case "premium":         return .premium
        case "structure":       return .structureDeck
        case "tin":             return .tin
        case "speed_duel":      return .speedDuel
        case "battle_pack":     return .battlePack
        case "world_premiere":  return .worldPremiere
        default:                return .modernEra
        }
    }

    // MARK: - Era Palettes

    /// LOB era — classic gold-on-brown. The original Yu-Gi-Oh look: brown
    /// card-back, gold trade-mark accents, sepia warmth.
    static let lobEra = PackPalette(
        deep:      Color(hex: 0x1A0F08),  // deep brown
        body:      Color(hex: 0x2A1810),  // card-back brown
        mid:       Color(hex: 0x6B4823),  // warm bronze
        highlight: Color(hex: 0xD4AF37),  // antique gold
        foil:      Color(hex: 0xE8C77A)   // pale gold
    )

    /// GX era — red + yellow, Jaden Yuki's Slifer Red dorm energy.
    static let gxEra = PackPalette(
        deep:      Color(hex: 0x150505),
        body:      Color(hex: 0x2A0808),
        mid:       Color(hex: 0xA32020),  // Slifer red
        highlight: Color(hex: 0xF2C20A),  // bright yellow
        foil:      Color(hex: 0xE8421C)   // flame orange
    )

    /// 5D's era — electric blue + chrome, motorcycle / Synchro tone.
    static let fivedsEra = PackPalette(
        deep:      Color(hex: 0x050A14),
        body:      Color(hex: 0x0A1428),
        mid:       Color(hex: 0x2563A8),  // signal blue
        highlight: Color(hex: 0x6EC1E4),  // chrome cyan
        foil:      Color(hex: 0xB8D8E8)   // chrome highlight
    )

    /// Zexal era — gold + violet, Astral / Number card aesthetic.
    static let zexalEra = PackPalette(
        deep:      Color(hex: 0x0A0518),
        body:      Color(hex: 0x180A28),
        mid:       Color(hex: 0x5A2EA8),  // astral violet
        highlight: Color(hex: 0xE8C24A),  // bright gold
        foil:      Color(hex: 0xC9A0FF)   // violet shimmer
    )

    /// Arc-V era — red + green, Yuya's pendulum split-color identity.
    static let arcvEra = PackPalette(
        deep:      Color(hex: 0x0A0808),
        body:      Color(hex: 0x1A0F0F),
        mid:       Color(hex: 0xA82020),  // pendulum red
        highlight: Color(hex: 0x2EA868),  // pendulum green
        foil:      Color(hex: 0xE85050)   // bright red shimmer
    )

    /// VRAINS era — cyan + magenta, LINK VRAINS network/glitch aesthetic.
    static let vrainsEra = PackPalette(
        deep:      Color(hex: 0x050A0E),
        body:      Color(hex: 0x0A1418),
        mid:       Color(hex: 0x00A8C8),  // network cyan
        highlight: Color(hex: 0xE83E8C),  // magenta glitch
        foil:      Color(hex: 0x6EE8F0)   // bright cyan
    )

    /// Sevens / Rush Duel era — hot pink + gold. Rush Duels lean younger,
    /// brighter, more vivid than the OCG mainline.
    static let sevensEra = PackPalette(
        deep:      Color(hex: 0x180510),
        body:      Color(hex: 0x280A18),
        mid:       Color(hex: 0xC83E78),  // hot pink
        highlight: Color(hex: 0xF2C20A),  // gold accent
        foil:      Color(hex: 0xFF6BA8)   // bright pink shimmer
    )

    /// Modern era — deep purple + gold. 25th Anniversary / Go Rush.
    static let modernEra = PackPalette(
        deep:      Color(hex: 0x080510),
        body:      Color(hex: 0x180A28),
        mid:       Color(hex: 0x5A2EC8),  // royal purple
        highlight: Color(hex: 0xD4AF37),  // antique gold
        foil:      Color(hex: 0x9D4EDD)   // bright violet
    )

    // MARK: - Non-era shelf palettes

    /// Premium products — full gold treatment. Legendary Collection vibe.
    static let premium = PackPalette(
        deep:      Color(hex: 0x150F00),
        body:      Color(hex: 0x281F00),
        mid:       Color(hex: 0x8B6914),  // dark gold
        highlight: Color(hex: 0xFFD700),  // pure gold
        foil:      Color(hex: 0xFFE891)
    )

    /// Structure Decks — deep blue, "boxed product" feel.
    static let structureDeck = PackPalette(
        deep:      Color(hex: 0x05080F),
        body:      Color(hex: 0x0A1428),
        mid:       Color(hex: 0x2848A0),  // box-blue
        highlight: Color(hex: 0xA8B8E8),
        foil:      Color(hex: 0x6E8ED8)
    )

    /// Collector Tins — chrome / silver. Mega Tins are iconic for their
    /// metallic finish.
    static let tin = PackPalette(
        deep:      Color(hex: 0x0A0A0A),
        body:      Color(hex: 0x1A1A1A),
        mid:       Color(hex: 0x6E6E72),  // graphite
        highlight: Color(hex: 0xE0E0E5),  // bright chrome
        foil:      Color(hex: 0xC0C8D4)   // soft silver
    )

    /// Speed Duel — neon electric blue. Speed branding leans bright + cyber.
    static let speedDuel = PackPalette(
        deep:      Color(hex: 0x00050E),
        body:      Color(hex: 0x031428),
        mid:       Color(hex: 0x0080C8),  // speed cyan
        highlight: Color(hex: 0x6EE8FF),  // electric highlight
        foil:      Color(hex: 0x00C8FF)
    )

    /// Battle Pack — deep red. The BP01-03 sealed-format packs leaned crimson.
    static let battlePack = PackPalette(
        deep:      Color(hex: 0x100303),
        body:      Color(hex: 0x280808),
        mid:       Color(hex: 0xA82020),  // battle red
        highlight: Color(hex: 0xE85050),
        foil:      Color(hex: 0xC83838)
    )

    /// World Premiere — tournament-gold prize feel.
    static let worldPremiere = PackPalette(
        deep:      Color(hex: 0x180F00),
        body:      Color(hex: 0x281A00),
        mid:       Color(hex: 0xB8941A),  // tournament gold
        highlight: Color(hex: 0xFFD700),
        foil:      Color(hex: 0xFFE891)
    )
}

// MARK: - Color hue manipulation

private extension Color {
    /// Returns a new color with its hue rotated by the given amount (in degrees).
    /// Saturation and brightness are preserved. Useful for deterministically
    /// shifting a palette per-set while keeping the era's identity recognizable.
    func hueShifted(by degrees: Double) -> Color {
        let uic = UIColor(self)
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard uic.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else {
            return self
        }
        let shifted = CGFloat(degrees / 360.0)
        var newHue = h + shifted
        newHue = newHue - floor(newHue)  // wrap into [0, 1)
        return Color(hue: Double(newHue), saturation: Double(s), brightness: Double(b), opacity: Double(a))
    }
}
