import Foundation

/// Client for the YGOPRODeck API. Free, no key required.
///
/// We bundle all set/card metadata, so this service exists only for runtime needs
/// the bundle can't satisfy: live price refresh on the inspect view, and
/// on-demand card lookup (rare).
///
/// Rate limits (per YGOPRODeck): **20 req/sec**, 1-hour IP block on violation.
/// Card-data cache TTL is 2 days on their side. Don't poll.
///
/// Note: image fetching is handled separately by `ImageCacheService`, which
/// downloads each card image once and persists to disk (YGOPRODeck forbids
/// hotlinking; per-device single-fetch + permanent local cache is acceptable).
actor YGOPRODeckService {
    private let baseURL = URL(string: "https://db.ygoprodeck.com/api/v7")!
    private let session: URLSession
    private let decoder: JSONDecoder

    init() {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "Accept": "application/json",
            "User-Agent": "ygo-rip/1.0"
        ]
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()
    }

    /// Fetch a single card by numeric YGO ID. Used for price refresh on inspect.
    func fetchCard(id: Int) async throws -> YGOCard {
        let url = baseURL.appending(path: "cardinfo.php").appending(queryItems: [
            URLQueryItem(name: "id", value: String(id))
        ])
        let envelope: YGOCardEnvelope = try await fetch(url)
        guard let card = envelope.data.first else {
            throw APIError.invalidResponse
        }
        return card
    }

    private func fetch<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        switch http.statusCode {
        case 200...299:
            return try decoder.decode(T.self, from: data)
        case 429:
            throw APIError.rateLimited
        case 400...499:
            throw APIError.clientError(http.statusCode)
        case 500...599:
            throw APIError.serverError(http.statusCode)
        default:
            throw APIError.invalidResponse
        }
    }
}

// MARK: - YGOPRODeck response shapes

/// `cardinfo.php` always wraps results in `{ "data": [...] }`, even for single-card lookups.
struct YGOCardEnvelope: Decodable {
    let data: [YGOCard]
}

struct YGOCard: Decodable {
    let id: Int
    let name: String
    /// One entry per printing across every set. We match by `set_code` to
    /// get per-printing prices — this is the accurate number (Blue-Eyes
    /// LOB-001 at ~$253, not the reprint floor).
    let card_sets: [YGOPrinting]?
    /// Per-card-design prices (one element). The `tcgplayer_price` here is
    /// the floor across all reprints — it understates multi-rarity chase
    /// cards, but it's populated even when per-printing `set_price` isn't.
    /// Used only as a fallback below.
    let card_prices: [YGOCardPrice]?

    /// TCGPlayer price for the given printing (`set_code` like "LOB-EN001").
    ///
    /// Prefers the per-printing `set_price` (accurate for older sets), and
    /// falls back to the design-level `card_prices[].tcgplayer_price` when
    /// that's missing. YGOPRODeck returns `set_price: "0"` for modern/recent
    /// sets (Arc-V onward, Sevens era, etc.), so without this fallback those
    /// eras show no price at all — both in the bundle and on live refresh.
    ///
    /// The fallback's known weakness (design-level price is the floor across
    /// all reprints, understating chase variants) doesn't bite us: the app
    /// dedupes chase variants to the base printing (see CLAUDE.md §8), so the
    /// floor *is* the number we display. Returns nil only when neither field
    /// carries a usable price.
    func priceUSD(forSetCode code: String) -> Double? {
        if let printing = card_sets?.first(where: { $0.set_code == code }),
           let value = Self.parsePrice(printing.set_price) {
            return value
        }
        return Self.parsePrice(card_prices?.first?.tcgplayer_price)
    }

    /// Parse a YGOPRODeck price string. Treats "0"/"0.00"/empty/nil as
    /// "no data" → nil, so a zeroed field falls through to the next source.
    private static func parsePrice(_ raw: String?) -> Double? {
        guard let raw, raw != "0.00", raw != "0",
              let value = Double(raw), value > 0 else { return nil }
        return value
    }
}

/// Per-printing record. `set_price` comes through as a string ("239.93");
/// parse on use. YGOPRODeck uses "0.00" or empty for "no data" — treat as nil.
struct YGOPrinting: Decodable {
    let set_code: String
    let set_price: String?
}

/// Per-card-design price record. Only `tcgplayer_price` is consumed; the
/// other market fields (cardmarket, ebay, amazon, coolstuffinc) are ignored.
struct YGOCardPrice: Decodable {
    let tcgplayer_price: String?
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
