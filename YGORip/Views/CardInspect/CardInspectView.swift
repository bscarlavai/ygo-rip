import SwiftUI
import SwiftData

struct CardInspectView: View {
    let card: CardModel

    @Environment(AppState.self) private var appState
    @Environment(CollectionStats.self) private var collectionStats
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isRefreshingPrice = false
    @State private var setName = ""
    @State private var pullCount = 0
    @State private var firstPulledDate: Date?

    @State private var foilMotion = FoilMotionProvider()
    @State private var cardFrame: CGSize = .zero
    @State private var isTouchingCard = false

    /// True when motion + a non-`.none` treatment apply for this card. YGO
    /// foil is intrinsic to rarity (Rare+ printings are foil), so the shader
    /// runs whenever the card's tier is non-Common; Reduce Motion suppresses.
    private var gyroAvailable: Bool {
        !reduceMotion && appState.gyroEnabled
    }

    private var passiveMotionSource: FoilMotionProvider.Source? {
        if reduceMotion { return nil }
        if gyroAvailable { return .device }
        if appState.idleHoloShimmerEnabled { return .auto }
        return nil
    }

    /// Whether the foil shader should actually be running. Matches poke-rip's
    /// pattern: only run when the user is actively touching the card OR a
    /// passive motion source (idle sweep / gyro) is on. Skipping the shader
    /// when no animation is happening is both a perf win (no GPU cost
    /// re-rendering a static foil) and a stability win (reduces the surface
    /// for the Metal shader / `@Observable tilt` interaction to misbehave
    /// during gesture transitions).
    private var foilActive: Bool {
        isTouchingCard || passiveMotionSource != nil
    }

    private var effectiveTreatment: FoilTreatment {
        guard !reduceMotion, foilActive else { return .none }
        // YGO rarity is per-printing — every Rare+ printing IS foil in real life,
        // so we drive the treatment off rarity tier alone.
        return FoilTreatment.forYGORarity(card.rarityTier)
    }

    private func loadCardDetails() {
        // SetModel fetch by apiID — cheap, the predicate hits an indexed key.
        let setID = card.setID
        let setDescriptor = FetchDescriptor<SetModel>(
            predicate: #Predicate { $0.apiID == setID }
        )
        setName = (try? modelContext.fetch(setDescriptor))?.first?.name ?? ""

        // Pull info — read from the pre-aggregated CollectionStats instead
        // of running a `cardAPIID`-filtered fetch on PullRecord. The previous
        // fetch wasn't index-backed (only setID is indexed) so it scanned the
        // whole table synchronously on main during .onAppear, right when
        // applyFoilMotion was kicking off the foil tick loop — visible as a
        // jumpy first second of idle motion on heavy collections.
        let cardID = card.apiID
        pullCount = collectionStats.pullCountByCardID[cardID] ?? 0
        firstPulledDate = collectionStats.pullDatesByCardID[cardID]?.first
    }

    private func applyFoilMotion() {
        if let src = passiveMotionSource {
            foilMotion.start(source: src)
        } else {
            foilMotion.stop()
            foilMotion.setDragTilt(.zero)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.spacingLG) {
                    cardImage

                    if effectiveTreatment != .none {
                        Text("Hold and drag to inspect")
                            .font(.caption)
                            .foregroundStyle(Theme.tertiaryText)
                    }

                    cardInfo
                    pullInfo
                }
                .padding(Theme.spacingMD)
            }
            .background(Theme.background)
            .onAppear {
                loadCardDetails()
                applyFoilMotion()
            }
            .onDisappear { foilMotion.stop() }
            .onChange(of: passiveMotionSource) { _, _ in applyFoilMotion() }
            .navigationBarTitleDisplayMode(.inline)
            .task { await refreshPriceIfStale() }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                            card.isFavorite.toggle()
                            try? modelContext.save()
                        }
                    } label: {
                        Image(systemName: card.isFavorite ? "heart.fill" : "heart")
                            .foregroundStyle(card.isFavorite ? .red : Theme.secondaryText)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    buyMenu
                }
            }
        }
    }

    // MARK: - Card Image

    private var cardImage: some View {
        CachedCardImage(urlString: card.imageLargeURL)
            .aspectRatio(0.714, contentMode: .fit)
            .clipShape(.rect(cornerRadius: Theme.radiusMD))
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { cardFrame = geo.size }
                        .onChange(of: geo.size) { _, new in cardFrame = new }
                }
            }
            // Split foilShader + foilRotation so the foil badge sits between
            // them — rotates with the card but isn't tinted by the shader.
            .foilShader(
                treatment: effectiveTreatment,
                motion: foilMotion,
                intensity: 1.0
            )
            .foilRotation(motion: foilMotion, degrees: 12)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard cardFrame.width > 0, cardFrame.height > 0 else { return }
                        if !isTouchingCard {
                            isTouchingCard = true
                            foilMotion.start(source: .drag)
                        }
                        let nx = (value.location.x - cardFrame.width / 2) / (cardFrame.width / 2)
                        let ny = (value.location.y - cardFrame.height / 2) / (cardFrame.height / 2)
                        let cx = max(-1, min(1, -nx))
                        let cy = max(-1, min(1, -ny))
                        foilMotion.setDragTilt(CGSize(width: cx, height: cy))
                    }
                    .onEnded { _ in
                        isTouchingCard = false
                        if let src = passiveMotionSource {
                            foilMotion.start(source: src)
                        } else {
                            foilMotion.stop()
                            foilMotion.setDragTilt(.zero)
                        }
                    }
            )
            .shadow(
                color: Theme.rarityColor(for: card.rarity).opacity(0.4),
                radius: 16
            )
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.spacingLG)
    }

    // MARK: - Card Info (minimal — image is the display)

    private var cardInfo: some View {
        VStack(spacing: Theme.spacingSM) {
            Text(card.name)
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)

            HStack(spacing: Theme.spacingSM) {
                Text(card.number.isEmpty ? "—" : card.number)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)

                Text("•")
                    .foregroundStyle(Theme.tertiaryText)

                Text(card.rarity)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.rarityColor(for: card.rarity))
            }

            HStack(spacing: Theme.spacingMD) {
                VStack(spacing: 2) {
                    Text("Market")
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiaryText)
                    if isRefreshingPrice && card.priceMarket == nil {
                        ProgressView()
                            .tint(Theme.tertiaryText)
                            .scaleEffect(0.7)
                            .frame(height: 20)
                    } else {
                        Text(card.priceMarket.map { String(format: "$%.2f", $0) } ?? "——")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(card.priceMarket != nil ? Theme.accent : Theme.tertiaryText)
                    }
                }
                VStack(spacing: 2) {
                    Text("Lowest")
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiaryText)
                    if isRefreshingPrice && card.priceLow == nil {
                        ProgressView()
                            .tint(Theme.tertiaryText)
                            .scaleEffect(0.7)
                            .frame(height: 20)
                    } else {
                        Text(card.priceLow.map { String(format: "$%.2f", $0) } ?? "——")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(card.priceLow != nil ? .green : Theme.tertiaryText)
                    }
                }
            }
            .padding(.top, Theme.spacingXS)
        }
    }

    // MARK: - Pull Info

    private var pullInfo: some View {
        VStack(spacing: Theme.spacingSM) {
            HStack {
                Label("Owned", systemImage: "rectangle.stack.fill")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Text("×\(pullCount)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.primaryText)
            }

            if let date = firstPulledDate {
                HStack {
                    Label("First Pulled", systemImage: "calendar")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                    Spacer()
                    Text(date, style: .date)
                        .font(.subheadline)
                        .foregroundStyle(Theme.primaryText)
                }
            }
        }
        .padding(Theme.spacingMD)
        .background(Theme.cardSurface, in: .rect(cornerRadius: Theme.radiusMD))
    }
    // MARK: - Buy Menu

    private var buyMenu: some View {
        Menu {
            if let url = tcgPlayerURL {
                Link(destination: url) {
                    Label("TCGPlayer", systemImage: "cart.fill")
                }
            }
            if let url = ebayURL {
                Link(destination: url) {
                    Label("eBay", systemImage: "magnifyingglass")
                }
            }
        } label: {
            Image(systemName: "cart.fill")
                .foregroundStyle(Theme.accent)
        }
    }

    // MARK: - Marketplace URLs
    //
    // Plain TCGPlayer + eBay search links. No affiliate wrappers — TCGPlayer
    // declined the affiliate application; eBay Partner Network hasn't been
    // applied for. If/when an affiliate program is approved, wrap these URLs
    // in the appropriate redirect.

    private var tcgPlayerURL: URL? {
        // Prefer API-provided direct URL, fall back to search.
        // YGOPRODeck doesn't return TCGPlayer URLs, so `card.tcgPlayerURL` is
        // always nil in practice today — left in for forward-compat if a
        // future data source provides per-printing TCGPlayer links.
        if let direct = card.tcgPlayerURL { return URL(string: direct) }
        let searchQuery = "\(card.name) \(setName) \(card.number)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://www.tcgplayer.com/search/yugioh/product?q=\(searchQuery)&view=grid&productLineName=yugioh")
    }

    private var ebayURL: URL? {
        // Include "yu-gi-oh" + card name + set + collector number for precise
        // results, e.g. "yu-gi-oh Dark Magician LOB-EN005". eBay's relevance
        // ranking handles category selection across keyword matches.
        let query = "yu-gi-oh \(card.name) \(setName) \(card.number)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        // BIN only, sorted by price low→high.
        return URL(string: "https://www.ebay.com/sch/i.html?_nkw=\(query)&LH_BIN=1&_sop=15")
    }

    // MARK: - Price Refresh

    private func refreshPriceIfStale() async {
        // Refresh if: no price data, or price is older than 24h
        let hasPrice = card.priceMarket != nil
        if hasPrice, let lastUpdated = card.priceLastUpdated,
           lastUpdated.timeIntervalSinceNow > -86400 {
            return  // Fresh enough
        }

        isRefreshingPrice = true
        let api = YGOPRODeckService()
        do {
            let ygoCard = try await api.fetchCard(id: card.ygoID)
            if let market = ygoCard.priceUSD {
                card.priceMarket = market
                // YGOPRODeck doesn't expose a separate "low" — reuse market for both.
                card.priceLow = market
            }
            // Always mark as updated so we don't re-fetch constantly for cards with no price.
            card.priceLastUpdated = .now
            try? modelContext.save()
        } catch {
            // Silently fail — stale price is better than no price
        }
        isRefreshingPrice = false
    }
}

// MARK: - CardModel + Identifiable

extension CardModel: Identifiable {
    var id: String { apiID }
}
