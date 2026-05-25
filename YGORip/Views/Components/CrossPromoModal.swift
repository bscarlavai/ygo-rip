import SwiftUI

/// Metadata for a sister app we'd like to promote.
struct SiblingApp: Identifiable {
    /// Stable key used for "have we shown this user this sibling?" tracking
    /// in `AppState.crossPromoSeenApps`. Must be unique per sibling and
    /// stable across releases — renaming this string breaks the seen-set
    /// for already-installed users.
    let key: String
    let name: String
    let tagline: String
    let blurb: String
    /// Asset name in Assets.xcassets, or `nil` to fall back to `fallbackSymbol`.
    let iconAsset: String?
    let fallbackSymbol: String
    let appStoreID: String

    var id: String { key }
    var appStoreURL: URL? {
        URL(string: "https://apps.apple.com/app/id\(appStoreID)")
    }
}

extension SiblingApp {
    static let pokeRip = SiblingApp(
        key: "pokerip",
        name: "PokeRip",
        tagline: "Rip packs, chase rares.",
        blurb: "From the makers of YGORip. Open booster packs from every era, chase Hyper Rares and Secret Rares, and build your dream collection.",
        iconAsset: "PokeRipIcon",
        fallbackSymbol: "sparkles.rectangle.stack.fill",
        appStoreID: "6762006216"
    )

    static let mtgRip = SiblingApp(
        key: "mtgrip",
        name: "MTGRip",
        tagline: "Rip packs, chase mythics.",
        blurb: "From the makers of YGORip. Open boosters from every era, chase mythics and special-frame rares, and build your dream collection.",
        iconAsset: "MTGRipIcon",
        fallbackSymbol: "wand.and.stars",
        appStoreID: "6770387435"
    )

    /// Sibling apps this app promotes, in priority order. On each Home
    /// appearance after the user has opened their first pack, the first
    /// entry not yet in `AppState.crossPromoSeenApps` shows its modal.
    /// Adding a new sibling here causes it to surface on next launch for
    /// every install — even users who already saw earlier siblings —
    /// because the seen-set is per-key.
    static let crossPromoTargets: [SiblingApp] = [.pokeRip, .mtgRip]
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
