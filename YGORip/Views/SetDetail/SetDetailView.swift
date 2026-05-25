import SwiftUI
import SwiftData

struct SetDetailView: View {
    let set: SetModel

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    @State private var isSyncing = false
    @State private var loadError: String?
    @State private var showPackOpening = false
    @State private var selectedCard: CardModel?

    private let syncService = SetSyncService.shared

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: Theme.spacingLG) {
                Color.clear.frame(height: 0).id("top")
                setHero
                RipPackButton(
                    set: set,
                    isSyncing: isSyncing,
                    showPackOpening: $showPackOpening
                )
                SetPullHistory(
                    setID: set.apiID,
                    selectedCard: $selectedCard
                )
                SetCardGrid(
                    setID: set.apiID,
                    totalCards: set.totalCards,
                    isSyncing: isSyncing,
                    loadError: loadError,
                    selectedCard: $selectedCard,
                    onRetry: { Task { await syncCards() } }
                )
            }
            .padding(.horizontal, Theme.spacingMD)
            .padding(.bottom, Theme.spacingMD)
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                withAnimation { proxy.scrollTo("top") }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .frame(width: 40, height: 40)
                    .background(Theme.cardSurface, in: Circle())
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            }
            .padding(.trailing, Theme.spacingMD)
            .padding(.bottom, Theme.spacingLG)
        }
        } // ScrollViewReader
        .background(Theme.background)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { await syncCards() }
        .fullScreenCover(isPresented: $showPackOpening) {
            SetCardListWrapper(setID: set.apiID) { cards in
                PackOpeningView(set: set, cards: cards)
            }
        }
        .adaptiveDetailSheet(item: $selectedCard) { card in
            CardInspectView(card: card)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: showPackOpening, condition: { _, _ in appState.hapticsEnabled })
    }

    // MARK: - Hero

    private var setHero: some View {
        VStack(spacing: Theme.spacingMD) {
            VStack(spacing: 4) {
                SetSymbolView(set: set, size: 240, color: Theme.accent)
                    .padding(.top, Theme.spacingSM)

                Text(set.name)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.primaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, Theme.spacingLG)
            }

            Text("\(set.totalCards) cards  •  \(set.formattedReleaseDate)")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)

            SetCollectionBar(setID: set.apiID, totalCards: set.totalCards)
                .padding(.horizontal, Theme.spacingMD)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, Theme.spacingMD)
        .background {
            // Giant blurred symbol as ambient atmosphere behind the hero.
            SetSymbolView(set: set, size: 360, color: Theme.accent)
                .frame(height: 650)
                .blur(radius: 60)
                .opacity(0.25)
                .offset(y: -180)
                .padding(.horizontal, -Theme.spacingMD)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Sync

    private func syncCards() async {
        let setID = set.apiID
        let descriptor = FetchDescriptor<CardModel>(
            predicate: #Predicate { $0.setID == setID }
        )

        // Skip if already cached
        if let cached = try? modelContext.fetch(descriptor), !cached.isEmpty {
            return
        }

        isSyncing = true
        loadError = nil

        do {
            try await syncService.syncCards(forSetID: set.apiID, container: modelContext.container)
        } catch {
            loadError = "Failed to load cards. Check your connection."
        }

        isSyncing = false
    }
}

// MARK: - Card Grid (reactive via @Query)

/// Child view with its own @Query that updates as cards are inserted by the sync service.
struct SetCardGrid: View {
    @Query private var cards: [CardModel]

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(CollectionStats.self) private var collectionStats

    let setID: String
    let totalCards: Int
    let isSyncing: Bool
    let loadError: String?
    @Binding var selectedCard: CardModel?
    var onRetry: () -> Void

    @State private var sortOption: ChecklistSort = .number
    @State private var filterOwned: OwnedFilter = .all

    enum ChecklistSort: String, CaseIterable {
        case number = "Number"
        case name = "Name"
        case rarity = "Rarity"
    }

    enum OwnedFilter: String, CaseIterable {
        case all = "All"
        case owned = "Owned"
        case missing = "Missing"
    }

    /// Owned card IDs for this set — pre-aggregated by `CollectionStats`,
    /// no `@Query<PullRecord>` observer alive in this view.
    private var ownedCardIDs: Set<String> {
        collectionStats.ownedCardIDs(forSet: setID)
    }

    private var sortedFilteredCards: [CardModel] {
        var result = Array(cards)

        // Filter
        let owned = ownedCardIDs
        switch filterOwned {
        case .all: break
        case .owned: result = result.filter { owned.contains($0.apiID) }
        case .missing: result = result.filter { !owned.contains($0.apiID) }
        }

        // Sort
        switch sortOption {
        case .number:
            result.sort { (Int($0.number) ?? 0) < (Int($1.number) ?? 0) }
        case .name:
            result.sort { $0.name < $1.name }
        case .rarity:
            result.sort { $0.rarityRank > $1.rarityRank }
        }

        return result
    }

    init(
        setID: String,
        totalCards: Int,
        isSyncing: Bool,
        loadError: String?,
        selectedCard: Binding<CardModel?>,
        onRetry: @escaping () -> Void
    ) {
        _cards = Query(
            filter: #Predicate<CardModel> { $0.setID == setID },
            sort: \CardModel.number
        )
        self.setID = setID
        self.totalCards = totalCards
        self.isSyncing = isSyncing
        self.loadError = loadError
        self._selectedCard = selectedCard
        self.onRetry = onRetry
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            if let error = loadError, cards.isEmpty {
                VStack(spacing: Theme.spacingSM) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                    Button("Retry", action: onRetry)
                        .buttonStyle(.bordered)
                        .tint(Theme.accent)
                }
                .frame(maxWidth: .infinity)
                .padding(Theme.spacingLG)
            } else if cards.isEmpty && isSyncing {
                ShimmerCardGrid(cardCount: min(totalCards, 20))
            } else if !cards.isEmpty {
                HStack {
                    Text("Set Checklist")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)

                    if isSyncing {
                        Text("(\(cards.count)/\(totalCards))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.tertiaryText)
                    }

                    Spacer()

                    Menu {
                        // Sort options
                        Section("Sort") {
                            ForEach(ChecklistSort.allCases, id: \.self) { option in
                                Button {
                                    sortOption = option
                                } label: {
                                    HStack {
                                        Text(option.rawValue)
                                        if sortOption == option {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                        // Filter options
                        Section("Show") {
                            ForEach(OwnedFilter.allCases, id: \.self) { option in
                                Button {
                                    filterOwned = option
                                } label: {
                                    HStack {
                                        Text(option.rawValue)
                                        if filterOwned == option {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                    }
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: hSizeClass == .regular ? 130 : 80), spacing: Theme.spacingSM)],
                    spacing: Theme.spacingSM
                ) {
                    ForEach(sortedFilteredCards, id: \.apiID) { card in
                        let isOwned = ownedCardIDs.contains(card.apiID)
                        Button { selectedCard = card } label: {
                            CachedCardImage(urlString: card.imageSmallURL)
                                .aspectRatio(0.714, contentMode: .fit)
                                .clipShape(.rect(cornerRadius: Theme.radiusSM))
                                .opacity(isOwned ? 1.0 : 0.3)
                                .overlay(alignment: .bottomTrailing) {
                                    // Wishlist indicator: favorited but not yet owned
                                    if card.isFavorite && !isOwned {
                                        Image(systemName: "heart.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.red)
                                            .padding(3)
                                            .background(.black.opacity(0.5), in: Circle())
                                            .padding(3)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }

                if isSyncing {
                    HStack(spacing: Theme.spacingSM) {
                        ProgressView()
                            .tint(Theme.accent)
                        Text("Loading more cards...")
                            .font(.caption)
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(Theme.spacingMD)
                }
            }
        }
    }
}

// MARK: - Collection Progress Bar (reactive)

struct SetCollectionBar: View {
    @Query private var allCards: [CardModel]
    @Environment(CollectionStats.self) private var collectionStats
    let setID: String
    let totalCards: Int

    private var ownedCardIDs: Set<String> {
        collectionStats.ownedCardIDs(forSet: setID)
    }

    /// Set metadata can lag the bundled card pool — trust the larger count.
    private var displayTotal: Int { max(allCards.count, totalCards) }

    private var owned: Int {
        allCards.filter { ownedCardIDs.contains($0.apiID) }.count
    }

    init(setID: String, totalCards: Int) {
        _allCards = Query(
            filter: #Predicate<CardModel> { $0.setID == setID }
        )
        self.setID = setID
        self.totalCards = totalCards
    }

    var body: some View {
        VStack(spacing: Theme.spacingSM) {
            HStack {
                Text("Collection")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                Text("\(owned)/\(displayTotal)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }

            GeometryReader { geo in
                let fraction = displayTotal > 0
                    ? min(CGFloat(owned) / CGFloat(displayTotal), 1.0)
                    : 0

                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.cardSurface)
                    Capsule()
                        .fill(Theme.holo)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 8)

        }
        .padding(Theme.spacingMD)
        .background(Theme.background.opacity(0.4), in: .rect(cornerRadius: Theme.radiusMD))
    }
}

// MARK: - Rip Pack Button (reactive via @Query)

struct RipPackButton: View {
    @Environment(AppState.self) private var appState
    @Environment(CollectionStats.self) private var collectionStats
    @Environment(\.modelContext) private var modelContext
    @Query private var cards: [CardModel]

    let set: SetModel
    let isSyncing: Bool
    @Binding var showPackOpening: Bool
    @State private var showPremium = false

    private var hasCards: Bool { !cards.isEmpty }

    private var isEnabled: Bool {
        appState.canOpenPack && hasCards
    }

    init(set: SetModel, isSyncing: Bool, showPackOpening: Binding<Bool>) {
        let setID = set.apiID
        _cards = Query(
            filter: #Predicate<CardModel> { $0.setID == setID }
        )
        self.set = set
        self.isSyncing = isSyncing
        self._showPackOpening = showPackOpening
    }

    var body: some View {
        VStack(spacing: Theme.spacingSM) {
            // Pack status
            if !appState.isUnlimitedRips {
                HStack {
                    // Pack dots
                    HStack(spacing: 4) {
                        ForEach(0..<AppState.maxPacks, id: \.self) { i in
                            Circle()
                                .fill(i < appState.currentPacks ? Theme.accent : Theme.cardSurface)
                                .frame(width: 10, height: 10)
                        }
                    }

                    Spacer()

                    if let countdown = appState.nextPackCountdown {
                        Text("Next in \(countdown)")
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiaryText)
                    } else if appState.currentPacks >= AppState.maxPacks {
                        Text("Full")
                            .font(.caption2)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }

            // Rip button
            Button {
                PackTiming.reset("rip tap")
                // Stage the pack before the fullScreenCover finishes its
                // transition. Pack generation is synchronous, and the first
                // card's large image download starts here — by the time the
                // sealed pack lands on screen the priority image is already
                // partway down the wire.
                PackPrefetcher.shared.prefetch(
                    set: set,
                    cards: cards,
                    modelContext: modelContext,
                    ownedCardIDs: collectionStats.ownedCardIDs(forSet: set.apiID),
                    biasUnownedCards: appState.unownedCardBiasEnabled
                )
                showPackOpening = true
            } label: {
                HStack {
                    Image(systemName: "flame.fill")
                    Text("Rip a Pack")
                        .font(.title3.weight(.bold))
                    Image(systemName: "flame.fill")
                }
                .foregroundStyle(isEnabled ? Theme.background : Theme.tertiaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.spacingMD)
                .background {
                    if isEnabled {
                        RoundedRectangle(cornerRadius: Theme.radiusLG)
                            .fill(Theme.holo)
                    } else {
                        RoundedRectangle(cornerRadius: Theme.radiusLG)
                            .fill(Theme.cardSurface)
                    }
                }
            }
            .disabled(!isEnabled)

            // Status / CTA
            if !appState.canOpenPack && !appState.isUnlimitedRips {
                VStack(spacing: Theme.spacingXS) {
                    if let countdown = appState.nextPackCountdown {
                        Text("Next pack in \(countdown)")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Button {
                        showPremium = true
                    } label: {
                        Text("Unlock Unlimited Rips")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.gold)
                    }
                }
            } else if isSyncing {
                Text("Loading cards...")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .sheet(isPresented: $showPremium) {
            SettingsView()
        }
    }
}

// MARK: - Pull History (reactive via @Query)

struct SetPullHistory: View {
    @Query private var allCards: [CardModel]
    @Environment(CollectionStats.self) private var collectionStats
    let setID: String
    @Binding var selectedCard: CardModel?

    init(setID: String, selectedCard: Binding<CardModel?>) {
        _allCards = Query(
            filter: #Predicate<CardModel> { $0.setID == setID }
        )
        self.setID = setID
        _selectedCard = selectedCard
    }

    /// Recent notable pulls (rare+) from this set, max 5, most-recent first.
    ///
    /// Pre-migration this iterated a `PullRecord`-by-pulledAt-desc @Query and
    /// took the first 5 unique rare+ cards. Post-migration we filter the
    /// per-set `allCards` to those that are (a) owned and (b) rare+, then
    /// sort by the card's most-recent pull date from `CollectionStats`.
    /// Semantically equivalent — both produce the user's 5 most-recently-
    /// pulled rare+ cards in this set.
    private var notablePulls: [(CardModel, Date)] {
        let owned = collectionStats.ownedCardIDs(forSet: setID)
        let dates = collectionStats.pullDatesByCardID
        var results: [(CardModel, Date)] = []
        for card in allCards {
            guard card.rarityTier >= 2, owned.contains(card.apiID),
                  let last = dates[card.apiID]?.last else { continue }
            results.append((card, last))
        }
        results.sort { $0.1 > $1.1 }
        return Array(results.prefix(5))
    }

    private var packsOpened: Int {
        collectionStats.packsOpenedBySet[setID] ?? 0
    }

    private var hasAnyPullsInSet: Bool {
        !collectionStats.ownedCardIDs(forSet: setID).isEmpty
    }

    var body: some View {
        if hasAnyPullsInSet {
            VStack(alignment: .leading, spacing: Theme.spacingSM) {
                HStack {
                    Text("Pull History")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                    Spacer()
                    Text("\(packsOpened) packs opened")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.tertiaryText)
                }

                if notablePulls.isEmpty {
                    Text("No rare pulls yet — keep ripping!")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                } else {
                    ForEach(notablePulls, id: \.0.apiID) { card, date in
                        Button { selectedCard = card } label: {
                            HStack(spacing: Theme.spacingSM) {
                                CachedCardImage(urlString: card.imageSmallURL)
                                    .aspectRatio(0.714, contentMode: .fit)
                                    .frame(width: 36)
                                    .clipShape(.rect(cornerRadius: 4))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(card.name)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Theme.primaryText)
                                        .lineLimit(1)
                                    Text(card.rarity.capitalized)
                                        .font(.caption2)
                                        .foregroundStyle(Theme.rarityColor(for: card.rarity))
                                }

                                Spacer()

                                Text(Self.relativeTime(from: date))
                                    .font(.caption2)
                                    .foregroundStyle(Theme.tertiaryText)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(Theme.spacingMD)
            .background(Theme.cardSurface.opacity(0.5), in: .rect(cornerRadius: Theme.radiusMD))
        }
    }

    private static func relativeTime(from date: Date) -> String {
        let seconds = -date.timeIntervalSinceNow
        if seconds < 60 { return "Just now" }
        if seconds < 3600 {
            let mins = Int(seconds / 60)
            return mins == 1 ? "1 min ago" : "\(mins) min ago"
        }
        if seconds < 86400 {
            let hours = Int(seconds / 3600)
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        }
        if seconds < 604800 {
            let days = Int(seconds / 86400)
            return days == 1 ? "Yesterday" : "\(days) days ago"
        }
        let weeks = Int(seconds / 604800)
        return weeks == 1 ? "1 week ago" : "\(weeks) weeks ago"
    }
}

// MARK: - Helper to pass @Query cards to PackOpeningView

struct SetCardListWrapper<Content: View>: View {
    @Query private var cards: [CardModel]
    let content: ([CardModel]) -> Content

    init(setID: String, @ViewBuilder content: @escaping ([CardModel]) -> Content) {
        _cards = Query(
            filter: #Predicate<CardModel> { $0.setID == setID },
            sort: \CardModel.number
        )
        self.content = content
    }

    var body: some View {
        content(cards)
    }
}

