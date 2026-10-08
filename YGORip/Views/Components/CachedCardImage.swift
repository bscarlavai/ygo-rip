import SwiftUI

/// Async card image with shimmer skeleton placeholder, caching, and retry.
struct CachedCardImage: View {
    let urlString: String
    var showSkeleton = true

    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var hasFailed = false
    @State private var isNotFound = false
    @State private var shimmerPhase: CGFloat = -1

    init(urlString: String, showSkeleton: Bool = true) {
        self.urlString = urlString
        self.showSkeleton = showSkeleton
        // Seed from memory cache synchronously so the first frame already has the image
        _image = State(initialValue: ImageCacheService.shared.cachedImage(for: urlString))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(MTGCardCornerShape())
                    .transition(.opacity)
                    .overlay {
                        if isNotFound {
                            VStack {
                                Spacer()
                                Text("Image not available")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.black.opacity(0.6), in: Capsule())
                                    .padding(.bottom, 8)
                            }
                        }
                    }
            } else if hasFailed {
                failedPlaceholder
            } else if showSkeleton {
                skeletonPlaceholder
            }
        }
        .task(id: urlString) {
            await loadImage()
        }
        // A failed tile retries on its own when the reason it failed may have
        // gone away — the network came back, or the user returned to the app —
        // instead of waiting for a tap on every tile in a grid. (Scrolling a
        // tile off and back on already retries: `.task` re-fires on appear.)
        .onChange(of: NetworkMonitor.shared.isConnected) { _, connected in
            if connected { retryIfFailed() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            retryIfFailed()
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                shimmerPhase = 1
            }
        }
    }

    private var skeletonPlaceholder: some View {
        MTGCardCornerShape()
            .fill(Theme.cardSurface)
            .aspectRatio(MTGCardCornerShape.aspectRatio, contentMode: .fit)
            .shimmer(phase: shimmerPhase)
    }

    private var failedPlaceholder: some View {
        MTGCardCornerShape()
            .fill(Theme.cardSurface)
            .aspectRatio(MTGCardCornerShape.aspectRatio, contentMode: .fit)
            .overlay {
                VStack(spacing: Theme.spacingSM) {
                    Image(systemName: "photo")
                        .foregroundStyle(Theme.tertiaryText)
                    Button("Retry") { retry() }
                    .font(.caption)
                }
            }
    }

    private func retryIfFailed() {
        if hasFailed { retry() }
    }

    private func retry() {
        hasFailed = false
        Task { await loadImage() }
    }

    private func loadImage() async {
        // Already seeded from memory cache in init — nothing to do
        if image != nil { return }
        isLoading = true
        hasFailed = false
        isNotFound = false

        // Single retry with short delay
        for attempt in 0..<2 {
            do {
                let result = try await ImageCacheService.shared.image(for: urlString)
                self.image = result
                isLoading = false
                return
            } catch let error as ImageCacheError {
                if case .notFound(let placeholder) = error {
                    self.image = placeholder
                    self.isNotFound = true
                    isLoading = false
                    return
                }
                if attempt < 1 {
                    try? await Task.sleep(for: .milliseconds(300))
                }
            } catch {
                if attempt < 1 {
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
        }

        isLoading = false
        hasFailed = true
    }
}

/// Card-shaped rounded rectangle whose corner radius scales with the bounds.
/// MTG cards are 63mm wide with a 3mm corner radius — ~4.76% of width.
/// Using a Shape (not a fixed cornerRadius) means every render site —
/// thumbnail, inspect, pack reveal — gets the right curve for its size.
struct MTGCardCornerShape: Shape {
    static let aspectRatio: CGFloat = 2.5 / 3.5
    static let radiusRatio: CGFloat = 0.0476

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) * Self.radiusRatio
        return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
    }
}
