import SwiftUI

/// Home grid tile. Renders the set's "boss card" cropped art as the tile
/// background (per-set visual identity — every set's iconic monster) with
/// a name + counter overlay at the bottom. Falls back to the YGO logo via
/// `SetSymbolView` if the bundle didn't pick a featured card for this set.
struct SetGridCard: View {
    let set: SetModel
    var ownedCount: Int = 0

    /// Loaded boss-card art for the background fill. Lazy-loads on appear
    /// via `ImageCacheService` (memory + disk cached), shared with the
    /// rest of the app's card image loading.
    @State private var artImage: UIImage?
    /// True once we've tried to load the featured-card cropped art and
    /// failed (URL 404 / network error). Used to fall back to the YGO
    /// logo instead of leaving the tile in its dark "loading" state
    /// forever — YGOPRODeck doesn't serve cropped art for some rare
    /// promo card IDs.
    @State private var artLoadFailed: Bool = false

    private var isComplete: Bool {
        let total = set.totalCards
        return total > 0 && ownedCount >= total
    }

    var body: some View {
        // Layout strategy: a `Color.clear` carries the tile's aspect ratio,
        // and ALL visual content lives in `.overlay {}` modifiers on it.
        // Image / gradient / label children can't grow the tile via their
        // intrinsic sizes — overlays don't propagate to the host's frame.
        // Critical for `scaledToFill()` images whose source dimensions
        // vary per set: without this clamp the larger-source-art tiles
        // (e.g. D/D/D Zero Doom Queen Machinex's 710×530 crop vs Yubel's
        // 624×624) physically grow their tile past its neighbors in the
        // grid.
        Color.clear
            .aspectRatio(0.95, contentMode: .fit)
            .overlay { artBackground }
            .overlay {
                // Dark gradient bottom so the labels stay legible against
                // whatever the art happens to be.
                LinearGradient(
                    stops: [
                        .init(color: .clear,                         location: 0.30),
                        .init(color: Theme.background.opacity(0.55), location: 0.55),
                        .init(color: Theme.background.opacity(0.92), location: 1.00),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(set.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2, reservesSpace: false)
                        .multilineTextAlignment(.leading)
                        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)

                    if isComplete {
                        Text("COMPLETE")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(Theme.gold)
                    } else {
                        Text("\(ownedCount)/\(set.totalCards)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(ownedCount > 0 ? Theme.secondaryText : Theme.tertiaryText)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .background(Theme.cardSurface)
            .clipShape(.rect(cornerRadius: Theme.radiusMD))
            .overlay {
                // Subtle hairline border so tiles separate from the dark
                // Home background. Hidden under the holo border when the
                // set is complete.
                RoundedRectangle(cornerRadius: Theme.radiusMD)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            }
            .overlay {
                if isComplete {
                    RoundedRectangle(cornerRadius: Theme.radiusMD)
                        .strokeBorder(
                            LinearGradient(
                                colors: Theme.holoColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 3
                        )
                }
            }
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var artBackground: some View {
        if let url = set.featuredCardCroppedURL, !artLoadFailed {
            Group {
                if let img = artImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    // Loading state — solid card-surface tint, no shimmer.
                    Theme.cardSurface
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .allowsHitTesting(false)
            .task(id: url) { await loadArt(urlString: url) }
        } else {
            // Either the bundle didn't pick a featured card OR the URL
            // 404'd on YGOPRODeck. Either way, fall back to the YGO
            // logo centered like the old tile.
            VStack {
                Spacer()
                SetSymbolView(set: set, size: 130, color: Theme.accent)
                Spacer()
            }
        }
    }

    private func loadArt(urlString: String) async {
        // Sync seed from memory cache (instant on re-render after scroll).
        if let cached = ImageCacheService.shared.cachedImage(for: urlString) {
            self.artImage = cached
            return
        }
        // Async fetch — disk cache hit is fast, network fetch lazy.
        // On failure flip the artLoadFailed flag so the view re-renders
        // with the YGO-logo fallback instead of holding the dark
        // "loading" tint forever.
        do {
            let img = try await ImageCacheService.shared.image(for: urlString)
            self.artImage = img
        } catch {
            self.artLoadFailed = true
        }
    }
}
