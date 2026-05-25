import Foundation
import SwiftData

/// Persists sets and cards into SwiftData from bundled JSON.
///
/// All metadata ships in-bundle, so there's no API path. The data pipeline
/// (see `data-pipeline/build_bundle.py`) emits:
///   - `sets.json`               — array of set records
///   - `cards.json`              — deduped card definitions, keyed by numeric YGO ID
///   - `set-cards-<code>.json`   — per-set printings: {id, rarity, code, price}
///
/// Card definitions are loaded once and cached in memory — the per-set sync
/// joins printings with definitions to produce `CardModel` rows.
actor SetSyncService {
    static let shared = SetSyncService()

    /// In-memory cache of the global card-definition index, keyed by `ygoID`.
    /// Lazily loaded on first per-set sync.
    private var cardDefs: [Int: BundledCardDef]?

    /// Load all sets from the bundle. Idempotent — only inserts/updates.
    func syncAllSets(container: ModelContainer) async throws {
        let bundled = try Self.loadBundledSets()
        try await persistSets(bundled, container: container)
    }

    /// Load all cards for one set from the bundle into SwiftData. Idempotent.
    func syncCards(forSetID setID: String, container: ModelContainer) async throws {
        let defs = try loadCardDefsIfNeeded()
        let printings = try Self.loadBundledPrintings(setID: setID)
        try await persistCards(printings, setID: setID, defs: defs, container: container)
    }

    // MARK: - Persistence

    private func persistSets(_ records: [BundledSet], container: ModelContainer) async throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false

        for record in records {
            let code = record.code
            let descriptor = FetchDescriptor<SetModel>(
                predicate: #Predicate { $0.apiID == code }
            )
            let existing = try context.fetch(descriptor)

            if let model = existing.first {
                guard model.name != record.name
                    || model.totalCards != record.totalCards
                    || model.shelf != record.shelf
                    || model.era != record.era
                    || model.featuredCardID != record.featuredCardID else { continue }
                model.name = record.name
                model.totalCards = record.totalCards
                model.shelf = record.shelf
                model.era = record.era
                model.featuredCardID = record.featuredCardID
            } else {
                let model = SetModel(
                    apiID: record.code,
                    name: record.name,
                    releaseDate: record.tcgDate,
                    totalCards: record.totalCards,
                    era: record.era,
                    shelf: record.shelf,
                    featuredCardID: record.featuredCardID
                )
                context.insert(model)
            }
        }
        try context.save()
    }

    private func persistCards(
        _ printings: [BundledPrinting],
        setID: String,
        defs: [Int: BundledCardDef],
        container: ModelContainer
    ) async throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false

        for printing in printings {
            let apiID = "\(setID):\(printing.id)"
            let descriptor = FetchDescriptor<CardModel>(
                predicate: #Predicate { $0.apiID == apiID }
            )
            let existing = try context.fetch(descriptor)
            guard existing.isEmpty else { continue }

            guard let def = defs[printing.id] else {
                // Printing references a card not in the definitions dump — skip rather
                // than insert a stub. This shouldn't happen with a fresh bundle.
                continue
            }

            let model = CardModel(
                apiID: apiID,
                ygoID: def.id,
                name: def.name,
                number: printing.code,
                rarity: printing.rarity,
                setID: setID,
                cardType: def.type,
                frameType: def.frameType,
                desc: def.desc,
                attribute: def.attribute,
                race: def.race,
                level: def.level,
                atk: def.atk,
                def: def.def,
                archetype: def.archetype,
                scale: def.scale,
                linkval: def.linkval,
                linkmarkersRaw: def.linkmarkers?.joined(separator: ",")
            )
            if let price = printing.price, let p = Double(price) {
                model.priceMarket = p
                model.priceLastUpdated = Date()
            }
            context.insert(model)
        }
        try context.save()
    }

    // MARK: - Bundle loading

    private static let decoder = JSONDecoder()

    static func loadBundledSets() throws -> [BundledSet] {
        guard let url = Bundle.main.url(forResource: "sets", withExtension: "json") else {
            throw BundleError.missing("sets.json")
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode([BundledSet].self, from: data)
    }

    static func loadBundledPrintings(setID: String) throws -> [BundledPrinting] {
        // Bundle resources are flattened by Xcode, so files use a `set-cards-<code>` prefix.
        guard let url = Bundle.main.url(forResource: "set-cards-\(setID)", withExtension: "json") else {
            throw BundleError.missing("set-cards-\(setID).json")
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode([BundledPrinting].self, from: data)
    }

    static func loadBundledCardDefs() throws -> [BundledCardDef] {
        guard let url = Bundle.main.url(forResource: "cards", withExtension: "json") else {
            throw BundleError.missing("cards.json")
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode([BundledCardDef].self, from: data)
    }

    private func loadCardDefsIfNeeded() throws -> [Int: BundledCardDef] {
        if let defs = cardDefs { return defs }
        let list = try Self.loadBundledCardDefs()
        let dict = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        cardDefs = dict
        return dict
    }

    enum BundleError: Error { case missing(String) }
}

// MARK: - Bundled JSON shapes

struct BundledSet: Decodable {
    let code: String
    let name: String
    let tcgDate: String
    let totalCards: Int
    let era: String?
    let shelf: String
    let featuredCardID: Int?
}

struct BundledCardDef: Decodable {
    let id: Int
    let name: String
    let type: String
    let frameType: String
    let desc: String
    let attribute: String?
    let race: String?
    let level: Int?
    let atk: Int?
    let def: Int?
    let archetype: String?
    let scale: Int?
    let linkval: Int?
    let linkmarkers: [String]?
}

struct BundledPrinting: Decodable {
    let id: Int
    let rarity: String
    let code: String
    /// Price comes through as a string from YGOPRODeck (e.g., "0.17"); we parse on use.
    let price: String?
}
