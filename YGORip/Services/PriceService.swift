import Foundation
import SwiftData

/// Client for the self-hosted Lavai Labs pricing service (`tcg-prices.com`).
///
/// Replaces the old per-card YGOPRODeck price fetches. The primitive here is the
/// **per-set batch**: one request prices an entire set (edge-cached 24h), keyed
/// by the full printed card code. See `tcg-price-api/docs/client-migration.md`.
///
/// YGO specifics vs the poke-rip reference implementation:
/// - `game=yugioh`. The blob keys are TCGPlayer's printed codes, which are
///   **not** identical to the app's YGOPRODeck codes: TCGPlayer drops the region
///   code on pre-region-code sets (`LOB-001`) while the bundle always carries it
///   (`LOB-EN001`), and zero-padding varies. A raw join misses every classic set.
///   So `normalizedNumber(_:)` (strip region code + leading zeros) is applied to
///   **both** the blob keys and `card.number` — they meet in the middle. (poke-rip
///   normalizes only the card side because that API pre-normalizes its keys; ours
///   doesn't, so we normalize the blob side too.)
/// - Each card carries both `market` and `low`; YGO surfaces both (the old
///   YGOPRODeck path exposed only a single price per printing).
///
/// The API contract:
/// - `GET /v1/prices?game=yugioh&set=<setID>` → `{ cards: { "<code>": { market, low } } }`
/// - `404` = unmapped set (no source carries it — promo/prize/video-game cards).
/// - A card **absent** from a `200` = known but unpriced upstream.
/// Both are *definitive* "no price exists" signals; a 429/5xx/offline is transient.
actor PriceService {
    static let shared = PriceService()

    private let baseURL = URL(string: "https://tcg-prices.com")!
    private let session: URLSession
    private let decoder = JSONDecoder()

    init() {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        self.session = URLSession(configuration: config)
    }

    /// Fetch every price for a set in one request.
    /// - Returns `.priced` (blob keyed by full printed code) or `.unmappedSet`
    ///   (404). Throws only on transient failures — callers must keep existing
    ///   prices on a throw, never blank them.
    func fetchSetPrices(setID: String) async throws -> SetPriceResult {
        let url = baseURL
            .appending(path: "v1/prices")
            .appending(queryItems: [
                .init(name: "game", value: "yugioh"),
                .init(name: "set", value: setID)
            ])
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }

        switch http.statusCode {
        case 200...299:
            let blob = try decoder.decode(PriceBlob.self, from: data)
            // Key by the normalized code so the lookup in PriceRefresh (also
            // normalized) matches regardless of the region-code / padding drift
            // between TCGPlayer's keys and the app's card numbers.
            var priced: [String: CardPrice] = [:]
            priced.reserveCapacity(blob.cards.count)
            for (code, entry) in blob.cards {
                priced[Self.normalizedNumber(code)] = CardPrice(market: entry.market, low: entry.low)
            }
            return .priced(priced)
        case 404:
            return .unmappedSet
        case 429:
            throw APIError.rateLimited
        case 400...499:
            throw APIError.clientError(http.statusCode)
        default:
            throw APIError.serverError(http.statusCode)
        }
    }

    /// Canonicalize a YGO printed code so the bundle's YGOPRODeck-style code
    /// (`LOB-EN001`) and the price blob's TCGPlayer-style key line up. Applied to
    /// **both** sides so they always meet in the middle. Two steps:
    ///  1. Drop a TCG region code (`EN`/`FR`/`DE`/`IT`/`PT`/`SP`) that sits between
    ///     the set-code dash and the number — TCGPlayer omits it on pre-region-code
    ///     sets (`LOB-001`), the bundle always includes it (`LOB-EN001`).
    ///  2. Strip leading zeros in the number (`-001` → `-1`), since padding varies.
    ///
    /// Validated to give 100% key overlap across every era (LOB/MRD/PSV classics
    /// through 25LP/PHNI/RA04); a raw join misses *all* classic-set cards.
    static func normalizedNumber(_ raw: String) -> String {
        var s = raw.uppercased()
        // Drop a TCG region code between the set-code dash and the number, then
        // strip the number's leading zeros. `.regularExpression` (ICU) supports
        // the `(?=…)` lookahead; a string pattern avoids the regex-literal
        // ambiguity of a leading `/-`.
        s = s.replacingOccurrences(of: "-(EN|FR|DE|IT|PT|SP)(?=[0-9])", with: "-", options: .regularExpression)
        s = s.replacingOccurrences(of: "-0+(?=[0-9])", with: "-", options: .regularExpression)
        return s
    }
}

/// Result of a set price fetch. `.priced` carries a `normalizedNumber → price`
/// map; a card missing from the map is unpriced upstream (definitive).
enum SetPriceResult {
    case priced([String: CardPrice])
    case unmappedSet
}

struct CardPrice {
    let market: Double?
    let low: Double?
}

// MARK: - Decode shape

private struct PriceBlob: Decodable {
    let cards: [String: Entry]
    struct Entry: Decodable {
        let market: Double?
        let low: Double?
    }
}

// MARK: - Apply to the store

/// Applies fetched set prices onto the on-disk `CardModel`s. This is the single
/// place the migration's persistence rules live (client-migration.md §1a):
/// - **success + price present** → write live market/low, stamp resolved.
/// - **definitive no-price** (404 set, or card absent from a healthy 200) → clear
///   any stale bundle seed to `nil` and stamp resolved, so the card shows the
///   terminal "No market price" state instead of a frozen number we can never
///   refresh (a stale 2026 price shown in 2029 is worse than none).
/// - **transient failure** (throw) → leave everything untouched (never blank).
@MainActor
enum PriceRefresh {
    private static let stalenessSeconds: TimeInterval = 24 * 60 * 60

    /// Refresh one set's prices if any of its cards are stale (or `force`).
    /// Safe to call from any set-touch site — gates on staleness and network,
    /// coalesces to one request, and self-heals on the next call after a failure.
    ///
    /// Returns `false` only when the API was unreachable (offline / transient
    /// failure) so a batch caller can retry; `true` means "no outstanding work"
    /// (applied, already fresh, or nothing to price).
    @discardableResult
    static func refresh(
        setID: String,
        modelContext: ModelContext,
        collectionStats: CollectionStats,
        force: Bool = false
    ) async -> Bool {
        let cards: [CardModel]
        do {
            cards = try modelContext.fetch(FetchDescriptor<CardModel>(
                predicate: #Predicate { $0.setID == setID }
            ))
        } catch { return true }
        guard !cards.isEmpty else { return true }

        if !force {
            let now = Date()
            let anyStale = cards.contains { card in
                guard let last = card.priceLastUpdated else { return true }
                return now.timeIntervalSince(last) > stalenessSeconds
            }
            guard anyStale else { return true }
        }
        guard NetworkMonitor.shared.isConnected else { return false }

        let result: SetPriceResult
        do {
            result = try await PriceService.shared.fetchSetPrices(setID: setID)
        } catch {
            return false  // transient — keep existing prices, retry on the next touch
        }

        let stamp = Date()
        switch result {
        case .unmappedSet:
            // Definitive: no source can price this set (1-card manga/video-game
            // promos, Duelist League participation cards, World Championship
            // prize cards, etc.). Drop any stale seed → terminal "No market price".
            for card in cards {
                card.priceMarket = nil
                card.priceLow = nil
                card.priceLastUpdated = stamp
            }
        case .priced(let byNumber):
            // Defensive: an empty blob on a 200 is an ingest anomaly, not "every
            // card is unpriced" — don't mass-clear a set's prices over it. We did
            // reach the API, so this isn't a retryable failure.
            guard !byNumber.isEmpty else { return true }
            for card in cards {
                if let price = byNumber[PriceService.normalizedNumber(card.number)],
                   price.market != nil || price.low != nil {
                    // Present with a real market and/or a recovered lowest-listing
                    // price. `market` may be nil for listing-only cards — the API
                    // keeps `{market: null, low: X}` for cards TCGPlayer has live
                    // listings for but no computed market aggregate. Write both
                    // verbatim; the display shows the low as a listing, never as
                    // the market price, and Stats' market-based Collection Value
                    // simply skips the nil market.
                    card.priceMarket = price.market
                    card.priceLow = price.low
                    card.priceLastUpdated = stamp
                } else if card.priceMarket == nil {
                    // Absent from a *priced* set (or present but fully unpriced) and
                    // we hold no price of our own → confirm as unpriced so the card
                    // shows "No market price" instead of a perpetual spinner.
                    card.priceLastUpdated = stamp
                }
                // Else: absent, but we already hold a price — keep the bundled
                // value rather than blanking. Only a whole-set 404 drops a seed,
                // and only because *nothing* can price that set.
            }
        }

        try? modelContext.save()
        collectionStats.priceRefreshTick &+= 1
        return true
    }
}

// MARK: - Errors

enum APIError: LocalizedError {
    case invalidResponse
    case rateLimited
    case clientError(Int)
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid API response"
        case .rateLimited: "API rate limit reached. Try again shortly."
        case .clientError(let code): "Request failed (\(code))"
        case .serverError(let code): "Server error (\(code))"
        }
    }
}
