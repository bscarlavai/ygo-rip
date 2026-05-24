import SwiftUI

/// Metadata for a sister app we'd like to promote.
struct SiblingApp {
    let name: String
    let tagline: String
    let blurb: String
    /// Asset name in Assets.xcassets, or `nil` to fall back to `fallbackSymbol`.
    let iconAsset: String?
    let fallbackSymbol: String
    let appStoreID: String

    var appStoreURL: URL? {
        URL(string: "https://apps.apple.com/app/id\(appStoreID)")
    }
}

extension SiblingApp {
    /// Sibling currently featured from MTGRip. Drop a `PokeRipIcon` image
    /// into Assets.xcassets to replace the SF Symbol placeholder.
    static let pokeRip = SiblingApp(
        name: "PokeRip",
        tagline: "Rip packs, chase rares.",
        blurb: "From the makers of MTGRip. Open booster packs from every era, chase Hyper Rares and Secret Rares, and build your dream collection.",
        iconAsset: "PokeRipIcon",
        fallbackSymbol: "sparkles.rectangle.stack.fill",
        appStoreID: "6762006216"
    )

    /// MTGRip sibling — Magic: The Gathering pack-opening simulator from the same dev.
    /// Drop a `MTGRipIcon` image into Assets.xcassets to replace the SF Symbol placeholder.
    /// TODO: confirm App Store ID once MTGRip is live (placeholder below).
    static let mtgRip = SiblingApp(
        name: "MTGRip",
        tagline: "Rip packs, chase mythics.",
        blurb: "From the makers of PokeRip. Open Magic: The Gathering boosters from every era, chase mythics and special-frame rares, and build your dream collection.",
        iconAsset: "MTGRipIcon",
        fallbackSymbol: "wand.and.stars",
        appStoreID: "REPLACE_WITH_MTGRIP_APP_STORE_ID"
    )
}

/// One-shot cross-promo sheet, presented to engaged users (i.e. after their
/// first pack open). Dismiss → flips `AppState.crossPromoSeen` so it never
/// fires again. A permanent link lives in Settings for later discovery.
struct CrossPromoModal: View {
    let sibling: SiblingApp
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: Theme.spacingLG) {
            Spacer(minLength: 24)

            // App icon (asset → SF Symbol fallback)
            Group {
                if let asset = sibling.iconAsset, UIImage(named: asset) != nil {
                    Image(asset)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(systemName: sibling.fallbackSymbol)
                        .resizable()
                        .scaledToFit()
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Theme.gold)
                        .padding(28)
                        .background(Theme.cardSurface)
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: Theme.gold.opacity(0.4), radius: 20)

            VStack(spacing: Theme.spacingSM) {
                Text(sibling.name)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Theme.primaryText)

                Text(sibling.tagline)
                    .font(.headline)
                    .foregroundStyle(Theme.gold)
            }

            Text(sibling.blurb)
                .font(.body)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.spacingLG)

            Spacer()

            VStack(spacing: Theme.spacingSM) {
                if let url = sibling.appStoreURL {
                    Link(destination: url) {
                        HStack {
                            Image(systemName: "arrow.up.right.square.fill")
                            Text("Get \(sibling.name) on the App Store")
                                .font(.headline.weight(.semibold))
                        }
                        .foregroundStyle(Theme.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Theme.gold, in: Capsule())
                    }
                    .simultaneousGesture(TapGesture().onEnded { onDismiss() })
                }

                Button("Maybe Later", action: onDismiss)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.vertical, 8)
            }
            .padding(.horizontal, Theme.spacingLG)
            .padding(.bottom, Theme.spacingMD)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .overlay(alignment: .topTrailing) {
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .padding(.trailing, 8)
            .padding(.top, 8)
        }
    }
}
