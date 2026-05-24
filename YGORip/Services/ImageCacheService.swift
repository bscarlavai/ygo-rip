import CryptoKit
import SwiftUI

/// Downloads and caches card images to the filesystem.
actor ImageCacheService {
    static let shared = ImageCacheService()

    private let cacheDirectory: URL
    private let session: URLSession
    private var inFlightTasks: [URL: Task<UIImage, Error>] = [:]
    nonisolated(unsafe) private let memoryCache = NSCache<NSString, UIImage>()

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDirectory = caches.appending(path: "CardImages")
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(
            memoryCapacity: 50 * 1024 * 1024,
            diskCapacity: 200 * 1024 * 1024
        )
        self.session = URLSession(configuration: config)

        // Keep up to 200 images in memory
        memoryCache.countLimit = 200
    }

    /// Synchronous memory-cache-only lookup (no actor hop). Returns nil on miss.
    nonisolated func cachedImage(for urlString: String) -> UIImage? {
        memoryCache.object(forKey: urlString as NSString)
    }

    /// Load an image from memory cache, disk cache, or download it.
    func image(for urlString: String) async throws -> UIImage {
        guard let url = URL(string: urlString) else {
            throw ImageCacheError.invalidURL
        }

        let cacheKey = urlString as NSString

        // Check memory cache first (instant)
        if let cached = memoryCache.object(forKey: cacheKey) {
            return cached
        }

        // Check disk cache
        let cacheFile = cacheFileURL(for: url)
        if let data = try? Data(contentsOf: cacheFile),
           let image = UIImage(data: data) {
            memoryCache.setObject(image, forKey: cacheKey)
            return image
        }

        // Deduplicate in-flight requests
        if let existing = inFlightTasks[url] {
            return try await existing.value
        }

        let task = Task<UIImage, Error> {
            let (data, response) = try await session.data(from: url)
            guard let image = UIImage(data: data) else {
                throw ImageCacheError.decodingFailed
            }
            // Some image servers return 404 with a card-back placeholder body — return
            // the image so the UI has something to show, but don't cache it so we retry
            // if the real image becomes available later.
            if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                throw ImageCacheError.notFound(image)
            }
            // Write to disk + memory cache
            try? data.write(to: cacheFile)
            self.memoryCache.setObject(image, forKey: urlString as NSString)
            return image
        }

        inFlightTasks[url] = task
        defer { inFlightTasks[url] = nil }

        return try await task.value
    }

    private func cacheFileURL(for url: URL) -> URL {
        // SHA256 of the full URL — 64 hex chars, guaranteed to differentiate.
        // Earlier base64-truncate(64) version had a bug where URLs sharing a
        // long prefix (e.g. images.ygoprodeck.com/images/cards_small/<id>.jpg)
        // hashed to the same filename when the ID landed past byte 49, causing
        // every grid thumbnail to render the same cached image.
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let filename = digest.compactMap { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appending(path: filename)
    }
}

enum ImageCacheError: LocalizedError {
    case invalidURL
    case decodingFailed
    case notFound(UIImage)  // Carries the placeholder image (card back)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid image URL"
        case .decodingFailed: "Failed to decode image data"
        case .notFound: "Image not available"
        }
    }
}
