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
    /// Always an array of one in practice; YGOPRODeck unconditionally emits a one-element array.
    let card_prices: [YGOPrices]?

    var priceUSD: Double? {
        guard let raw = card_prices?.first?.tcgplayer_price else { return nil }
        return Double(raw)
    }
}

/// All prices come through as strings (e.g. `"0.17"`). Parse on use.
struct YGOPrices: Decodable {
    let tcgplayer_price: String?
    let cardmarket_price: String?
    let ebay_price: String?
    let amazon_price: String?
    let coolstuffinc_price: String?
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
