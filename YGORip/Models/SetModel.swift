import Foundation
import SwiftData

@Model
final class SetModel {
    /// Set code (e.g., "LOB", "PHHY"). Unique key.
    @Attribute(.unique) var apiID: String
    var name: String
    /// TCG release date, ISO `yyyy-MM-dd`. May be empty for sets with no recorded date.
    var releaseDate: String
    var totalCards: Int
    /// Anime-era bucket: "lob", "gx", "5ds", "zexal", "arcv", "vrains", "sevens", "gorush", or nil.
    /// nil for sets that aren't dated or fall outside the main TCG timeline (collab/promo).
    var era: String?
    /// Home-screen shelf, e.g. "era_lob", "premium", "structure", "tin", "speed_duel".
    /// Drives the Home grouping only; pack opening is driven by `era`.
    var shelf: String
    /// Numeric YGOPRODeck ID of the "boss / cover" card for this set, picked
    /// by `data-pipeline/build_bundle.py` via an era-aware heuristic. Used
    /// as the per-set visual identity in the Home grid — the tile background
    /// is the card's cropped art (no frame, no text). May be nil for sets
    /// where the pipeline couldn't pick one (sparse promo sets).
    var featuredCardID: Int?

    init(
        apiID: String,
        name: String,
        releaseDate: String,
        totalCards: Int,
        era: String? = nil,
        shelf: String = "other",
        featuredCardID: Int? = nil
    ) {
        self.apiID = apiID
        self.name = name
        self.releaseDate = releaseDate
        self.totalCards = totalCards
        self.era = era
        self.shelf = shelf
        self.featuredCardID = featuredCardID
    }

    /// Cropped-art URL for the featured card — the painted illustration
    /// only, no card frame / name / stats. Used as the Home tile background.
    /// YGOPRODeck serves these at a stable URL pattern.
    var featuredCardCroppedURL: String? {
        guard let id = featuredCardID else { return nil }
        return "https://images.ygoprodeck.com/images/cards_cropped/\(id).jpg"
    }

    /// Human-readable era label for UI grouping pills.
    /// Falls back to `shelf` for non-era sets (premium, structure, etc.).
    var series: String { Self.seriesLabel(era: era, shelf: shelf) }

    static func seriesLabel(era: String?, shelf: String) -> String {
        if let era {
            switch era {
            case "lob":    return "Original Era"
            case "gx":     return "GX Era"
            case "5ds":    return "5D's Era"
            case "zexal":  return "Zexal Era"
            case "arcv":   return "Arc-V Era"
            case "vrains": return "VRAINS Era"
            case "sevens": return "Sevens Era"
            case "gorush": return "Modern"
            default:       break
            }
        }
        switch shelf {
        case "premium":         return "Premium"
        case "structure":       return "Structure Decks"
        case "tin":             return "Collector Tins"
        case "speed_duel":      return "Speed Duel"
        case "battle_pack":     return "Battle Pack"
        case "world_premiere":  return "World Premiere"
        default:                return "Other"
        }
    }

    /// Formatted release date (e.g., "Mar 2002").
    var formattedReleaseDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: releaseDate) else { return releaseDate }
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date)
    }
}
