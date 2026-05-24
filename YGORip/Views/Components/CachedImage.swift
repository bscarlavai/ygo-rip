import SwiftUI

/// Generic cached image — uses ImageCacheService for persistent disk caching.
/// Unlike AsyncImage, this survives view rebuilds and shares cache across the app.
struct CachedImage: View {
    let urlString: String

    @State private var image: UIImage?
    @State private var hasLoaded = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if hasLoaded {
                // Failed — show nothing (caller provides fallback via frame/overlay)
                Color.clear
            } else {
                ProgressView()
                    .tint(Theme.tertiaryText)
            }
        }
        .task(id: urlString) {
            guard !urlString.isEmpty else {
                hasLoaded = true
                return
            }
            do {
                let result = try await ImageCacheService.shared.image(for: urlString)
                self.image = result
            } catch {
                // Silently fail
            }
            hasLoaded = true
        }
    }
}
