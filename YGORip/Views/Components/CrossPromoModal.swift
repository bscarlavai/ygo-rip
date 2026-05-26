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
    /// appearance after the user has opened their first pack, every
    /// entry not yet in `AppState.crossPromoSeenApps` is shown together
    /// in a single `CrossPromoModal`. Adding a new sibling here causes
    /// it to surface in the next modal for every existing install (the
    /// new key isn't in their seen-set yet) without re-showing siblings
    /// they've already dismissed.
    static let crossPromoTargets: [SiblingApp] = [.pokeRip, .mtgRip]
}

/// "More from Lavai Labs" sheet — surfaces every sibling app the user
/// hasn't yet dismissed. Shown at most once per "batch of unseen
/// siblings": fires after first pack open with all currently-unseen
/// targets; on dismiss all of them get marked seen. When a future
/// release adds a new sibling, the next launch fires the modal again
/// with just that new sibling. Each row is a self-contained App Store
/// link; tapping any row marks all displayed siblings as seen and
/// closes the sheet.
struct CrossPromoModal: View {
    let siblings: [SiblingApp]
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Top spacer accommodates the X close overlay.
            Spacer(minLength: 32)

            Text("More from Lavai Labs")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.spacingLG)

            Spacer(minLength: Theme.spacingLG)

            ScrollView {
                VStack(spacing: Theme.spacingMD) {
                    ForEach(siblings) { sib in
                        SiblingRow(sibling: sib)
                    }
                }
                .padding(.horizontal, Theme.spacingLG)
            }

            Spacer(minLength: Theme.spacingMD)

            // Matches the translucent-pill "Reveal All" style used in
            // PackOpeningView so the dismiss action reads with the same
            // visual weight as the app's other primary-action buttons.
            Button(action: onDismiss) {
                Text("Done")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(.white.opacity(0.15)))
                    .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.5))
                    .contentShape(Capsule())
            }
            .padding(.horizontal, 32)
            .padding(.bottom, Theme.spacingMD)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
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

/// One row in the cross-promo modal — icon, name, tagline, Get button.
/// The whole row is a tap target that opens the App Store; the Get
/// button is visual affordance only (it inherits the row's tap).
private struct SiblingRow: View {
    let sibling: SiblingApp

    var body: some View {
        Group {
            if let url = sibling.appStoreURL {
                // Tapping a row navigates to the App Store but doesn't
                // dismiss the modal — when the user returns to the app,
                // the modal is still up so they can tap other siblings
                // from the list.
                Link(destination: url) { content }
            } else {
                content
            }
        }
    }

    private var content: some View {
        HStack(spacing: Theme.spacingMD) {
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
                        .padding(12)
                        .background(Theme.cardSurface)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(sibling.name)
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                Text(sibling.tagline)
                    .font(.caption)
                    .foregroundStyle(Theme.gold)
                    .lineLimit(2)
            }

            Spacer()

            HStack(spacing: 4) {
                Text("Get")
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "arrow.up.right.square.fill")
                    .font(.subheadline)
            }
            .foregroundStyle(Theme.background)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.gold, in: Capsule())
        }
        .padding(Theme.spacingMD)
        .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: Theme.radiusMD, style: .continuous))
        .contentShape(Rectangle())
    }
}
