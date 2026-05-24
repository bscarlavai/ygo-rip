import SwiftUI

enum Theme {
    // MARK: - Core Palette
    //
    // Inherited from poke-rip / mtg-rip — the sibling apps share a unified
    // foil/holo aesthetic (dark navy base, silver/holo accent, gold for
    // premium moments). YGORip keeps the same look so the three apps feel
    // like a coherent family rather than three separate flavors.

    static let background = Color(hex: 0x0F1923)
    static let cardSurface = Color(hex: 0x1A2634)

    /// Silver/holo — primary UI accent (tabs, buttons where gradient can't be used).
    static let accent = Color(hex: 0xC0C8D4)

    /// Gold — reserved for rare moments (chase pulls, NEW badge, premium highlights).
    static let gold = Color(hex: 0xFFD700)

    /// Holo gradient — iridescent shimmer for chase tier and stats card border.
    static let holo = LinearGradient(
        colors: [
            Color(hex: 0xA8D8EA),  // ice blue
            Color(hex: 0xC4B7D5),  // lavender
            Color(hex: 0xE8C4D8),  // pink
            Color(hex: 0xC4D5B7),  // mint
            Color(hex: 0xA8D8EA),  // ice blue (wrap)
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// Holo colors for use in custom gradients
    static let holoColors: [Color] = [
        Color(hex: 0xA8D8EA),
        Color(hex: 0xC4B7D5),
        Color(hex: 0xE8C4D8),
        Color(hex: 0xC4D5B7),
        Color(hex: 0xA8D8EA),
    ]

    // MARK: - Text

    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.7)
    static let tertiaryText = Color.white.opacity(0.5)

    // MARK: - Rarity Colors (YGO ladder)
    //
    // Mapping aims at: (1) faithful to real-world card-foil identity where
    // possible, (2) readable contrast on near-black, (3) escalating brightness
    // up the chase ladder.

    static let rarityCommon          = Color(hex: 0x9AA0A6)   // muted silver — printed in black
    static let rarityRare            = Color(hex: 0xC0C8D4)   // bright silver — silver name lettering
    static let raritySuperRare       = Color(hex: 0x6EC1E4)   // bright cyan — holographic art tint
    static let rarityUltraRare       = Color(hex: 0xD4AF37)   // antique gold — gold name lettering
    static let rarityUltimateRare    = Color(hex: 0xB87333)   // copper/bronze — embossed surface
    static let raritySecretRare = LinearGradient(
        colors: [.red, .orange, .yellow, .green, .blue, .purple],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let rarityStarlightRare   = Color(hex: 0xE83E8C)   // hot magenta — twinkling foil
    static let rarityQuarterCentury  = Color(hex: 0xC9A227)   // deep gold — 25th-anniversary identity
    static let rarityCollectorsRare  = Color(hex: 0x2ECC71)   // emerald — collector foil
    static let rarityPrismaticSecret = Color(hex: 0x9D4EDD)   // bright violet — prismatic chase
    static let rarityGhostRare       = Color(hex: 0xE8E8FA)   // ghost white-lavender — refractor look
    static let rarityShortPrint      = Color(hex: 0xB0B5BB)   // dim silver — slightly bumped from Common

    // MARK: - Spacing

    static let spacingXS: CGFloat = 4
    static let spacingSM: CGFloat = 8
    static let spacingMD: CGFloat = 16
    static let spacingLG: CGFloat = 24
    static let spacingXL: CGFloat = 32

    // MARK: - Corner Radii

    static let radiusSM: CGFloat = 8
    static let radiusMD: CGFloat = 12
    static let radiusLG: CGFloat = 16

    // MARK: - Rarity Helpers

    /// Solid color for a YGO rarity string. Multi-color rarities (Secret and
    /// above with refractor look) collapse to a representative single color
    /// for badges/borders/shadows where a gradient won't fit; the gradient
    /// version is available as `Theme.raritySecretRare`.
    static func rarityColor(for rarity: String) -> Color {
        switch rarity.lowercased() {
        case "common":                                  rarityCommon
        case "short print":                             rarityShortPrint
        case "rare":                                    rarityRare
        case "super rare":                              raritySuperRare
        case "ultra rare":                              rarityUltraRare
        case "ultimate rare":                           rarityUltimateRare
        case "secret rare":                             rarityPrismaticSecret  // collapse rainbow
        case "ghost rare":                              rarityGhostRare
        case "starlight rare":                          rarityStarlightRare
        case "quarter century secret rare":             rarityQuarterCentury
        case "collector's rare", "collectors rare":     rarityCollectorsRare
        case "prismatic secret rare":                   rarityPrismaticSecret
        case "platinum secret rare":                    rarityPrismaticSecret
        case "gold rare", "gold secret rare",
             "premium gold rare":                       rarityUltraRare
        default:                                        rarityCommon
        }
    }
}

// MARK: - Color Hex Extension

extension Color {
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
