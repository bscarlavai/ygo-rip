import XCTest
import SwiftData
@testable import YGORip

/// End-to-end set-completion tests against the REAL bundled card data and the
/// REAL pull pipeline (PullRateEngine era configs + PackPrefetcher slot fill).
///
/// Regression guard for the "Spell Ruler stuck at 100/104" bug: SRL's 4
/// Super Short Prints weren't in any LOB-era weight table, and the slot
/// filler's tier fallback never fires in a set whose exact-rarity pools are
/// never empty — so the cards were mathematically unpullable. Same class of
/// bug affected Short Prints (classic/modern eras) and Ultimate Rares
/// (modern era).
@MainActor
final class SetCompletionTests: XCTestCase {

    /// One representative set per affected bug class, plus the originally
    /// reported set. Era strings mirror sets.json.
    private static let cases: [(code: String, era: String, mustHaveRarity: String)] = [
        ("SRL", "lob", "Super Short Print"),    // user-reported: stuck at 100/104
        ("MRL", "lob", "Super Short Print"),
        ("PTDN", "gx", "Short Print"),          // classic era
        ("CORE", "arcv", "Ultimate Rare"),      // modern era (also has Short Prints)
    ]

    func testAffectedSetsCanReachFullCompletion() throws {
        let container = try ModelContainer(
            for: CardModel.self, SetModel.self, PullRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        for (code, era, mustHaveRarity) in Self.cases {
            let printings = try SetSyncService.loadBundledPrintings(setID: code)
            XCTAssertFalse(printings.isEmpty, "[\(code)] no bundled printings")
            XCTAssertTrue(
                printings.contains { $0.rarity == mustHaveRarity },
                "[\(code)] expected at least one \(mustHaveRarity) — bundle data changed; pick a new representative set"
            )

            let set = SetModel(
                apiID: code, name: code, releaseDate: "", totalCards: printings.count, era: era
            )
            context.insert(set)

            var cards: [CardModel] = []
            for p in printings {
                let card = CardModel(
                    apiID: "\(code):\(p.id)", ygoID: p.id, name: "\(p.code)",
                    number: p.code, rarity: p.rarity, setID: code,
                    cardType: "", frameType: ""
                )
                context.insert(card)
                cards.append(card)
            }
            try context.save()

            // Rip packs with Favor Unpulled Cards on until the collection
            // completes or the budget runs out. Pre-fix, SRL plateaus at
            // 100/104 and burns the entire budget.
            let allIDs = Set(cards.map(\.apiID))
            var owned = Set<String>()
            var packs = 0
            let budget = 5_000
            while owned != allIDs && packs < budget {
                let (pulled, _) = PackPrefetcher.generate(
                    set: set, cards: cards, modelContext: context,
                    ownedCardIDs: owned, biasUnownedCards: true
                )
                XCTAssertFalse(pulled.isEmpty, "[\(code)] generated an empty pack")
                owned.formUnion(pulled.map(\.model.apiID))
                packs += 1
            }

            let missing = allIDs.subtracting(owned)
            XCTAssertTrue(
                missing.isEmpty,
                "[\(code)] stuck at \(owned.count)/\(allIDs.count) after \(budget) packs — unpullable: \(missing.sorted())"
            )
            if missing.isEmpty {
                print("[\(code)] completed \(allIDs.count)/\(allIDs.count) in \(packs) packs")
            }
        }
    }
}
