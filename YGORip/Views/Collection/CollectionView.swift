import SwiftUI
import SwiftData

struct CollectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(CollectionStats.self) private var collectionStats
    @Query private var allCards: [CardModel]

    @State private var viewMode: ViewMode = .grid
    @State private var sortOption: SortOption = .recent
    @State private var filterRarity: String?
    @State private var filterFavorites = false
    @State private var searchText = ""
    @State private var selectedCard: CardModel?
    @State private var cachedOwnedCards: [OwnedCard] = []
    @State private var displayedCards: [OwnedCard] = []
    @State private var binderPages: [[OwnedCard]] = []
    @State private var binderPage: Int? = 0
    @State private var lastPullCount = 0

    enum ViewMode: String, CaseIterable {
        case grid = "Grid"
        case binder = "Binder"
        case list = "List"
    }

    enum SortOption: String, CaseIterable {
        case recent = "Recent"
        case name = "Name"
        case rarity = "Rarity"
        case setNumber = "Set #"
    }

    private var rarities: [String] {
        let all = Set(cachedOwnedCards.map(\.model.rarity))
        return Array(all).sorted {
            let r1 = CardModel.rarityRank(for: $0)
            let r2 = CardModel.rarityRank(for: $1)
            return r1 != r2 ? r1 < r2 : $0 < $1
        }
    }

    /// Build owned cards list from `CollectionStats` aggregates + card lookup.
    /// Reads from the pre-aggregated dictionaries rather than re-grouping the
    /// whole `PullRecord` table on every save — that observer cascade used to
    /// block main for ~1s on heavy collections.
    private func rebuildOwnedCards() {
        let cardsByID = Dictionary(uniqueKeysWithValues: allCards.map { ($0.apiID, $0) })

        var cards: [OwnedCard] = []
        for (cardID, count) in collectionStats.pullCountByCardID {
            guard let model = cardsByID[cardID] else { continue }
            let dates = collectionStats.pullDatesByCardID[cardID]
            cards.append(OwnedCard(
                model: model,
                count: count,
                firstPulled: dates?.first ?? .now,
                lastPulled: dates?.last ?? .now
            ))
        }

        cachedOwnedCards = cards
        lastPullCount = collectionStats.totalPulls
        refreshDisplay()
    }

    /// Apply current sort/filter and chunk into binder pages. Run only when inputs change.
    private func refreshDisplay() {
        let filtered = applySortAndFilter(to: cachedOwnedCards)
        displayedCards = filtered
        binderPages = stride(from: 0, to: filtered.count, by: 9).map { start in
            Array(filtered[start..<min(start + 9, filtered.count)])
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                cardList
            }
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
            .adaptiveDetailSheet(item: $selectedCard) { card in
                CardInspectView(card: card)
            }
            .onAppear { rebuildIfNeeded() }
            .onChange(of: collectionStats.totalPulls) { _, _ in rebuildIfNeeded() }
            .onChange(of: sortOption) { _, _ in refreshDisplay() }
            .onChange(of: filterRarity) { _, _ in refreshDisplay() }
            .onChange(of: filterFavorites) { _, _ in refreshDisplay() }
            .onChange(of: searchText) { _, _ in refreshDisplay() }
        }
    }

    private func rebuildIfNeeded() {
        guard collectionStats.totalPulls != lastPullCount else { return }
        rebuildOwnedCards()
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: Theme.spacingSM) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.tertiaryText)
                TextField("Search cards", text: $searchText)
                    .foregroundStyle(Theme.primaryText)

                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
            }
            .padding(Theme.spacingSM)
            .background(Theme.cardSurface, in: .rect(cornerRadius: Theme.radiusSM))

            HStack {
                // View mode toggle
                Picker("View", selection: $viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
                .layoutPriority(1)

                Spacer()

                // Sort picker
                Menu {
                    ForEach(SortOption.allCases, id: \.self) { option in
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
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down")
                        Text(sortOption.rawValue)
                            .lineLimit(1)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.cardSurface, in: Capsule())
                }

                // Favorites filter
                Button {
                    filterFavorites.toggle()
                } label: {
                    Image(systemName: filterFavorites ? "heart.fill" : "heart")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(filterFavorites ? .red : Theme.primaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.cardSurface, in: Capsule())
                }


                // Rarity filter
                Menu {
                    Button("All Rarities") { filterRarity = nil }
                    ForEach(rarities, id: \.self) { rarity in
                        Button(rarity.capitalized) { filterRarity = rarity }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease")
                        Text(filterRarity?.capitalized ?? "Rarity")
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(filterRarity != nil ? Theme.accent : Theme.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.cardSurface, in: Capsule())
                }
            }

            // Stats bar
            HStack {
                Text("\(displayedCards.count) unique cards")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Text("\(collectionStats.totalPulls) total pulls")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(Theme.spacingMD)
    }

    // MARK: - Card Display

    @ViewBuilder
    private var cardList: some View {
        if displayedCards.isEmpty {
            ScrollView { emptyState }
        } else if viewMode == .binder {
            // Binder uses TabView which can't be inside ScrollView
            binderView
        } else {
            ScrollView {
                switch viewMode {
                case .grid: gridView
                case .list: listView
                default: EmptyView()
                }
            }
        }
    }

    private var gridView: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: hSizeClass == .regular ? 150 : 100), spacing: Theme.spacingSM)],
            spacing: Theme.spacingSM
        ) {
            ForEach(displayedCards) { owned in
                Button {
                    selectedCard = owned.model
                } label: {
                    VStack(spacing: 2) {
                        CachedCardImage(urlString: owned.model.imageSmallURL)
                            .aspectRatio(0.714, contentMode: .fit)
                            .clipShape(.rect(cornerRadius: Theme.radiusSM))
                            .overlay(alignment: .topTrailing) {
                                if owned.count > 1 {
                                    Text("×\(owned.count)")
                                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                                        .foregroundStyle(Theme.background)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Theme.accent, in: Capsule())
                                        .padding(4)
                                }
                            }

                        Text(owned.model.name)
                            .font(.caption2)
                            .foregroundStyle(Theme.primaryText)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.spacingMD)
    }

    // MARK: - Binder View

    private var binderView: some View {
        VStack(spacing: 0) {
            if binderPages.isEmpty {
                emptyState
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(binderPages.indices, id: \.self) { pageIndex in
                            binderPageView(binderPages[pageIndex])
                                .containerRelativeFrame(.horizontal)
                                .id(pageIndex)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $binderPage)
                .scrollIndicators(.hidden)

                // Page indicator
                HStack(spacing: Theme.spacingSM) {
                    Button {
                        withAnimation { binderPage = max(0, (binderPage ?? 0) - 1) }
                    } label: {
                        Image(systemName: "chevron.left")
                            .foregroundStyle((binderPage ?? 0) > 0 ? Theme.primaryText : Theme.tertiaryText)
                    }
                    .disabled((binderPage ?? 0) == 0)

                    Text("Page \((binderPage ?? 0) + 1) of \(binderPages.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.secondaryText)

                    Button {
                        withAnimation { binderPage = min(binderPages.count - 1, (binderPage ?? 0) + 1) }
                    } label: {
                        Image(systemName: "chevron.right")
                            .foregroundStyle((binderPage ?? 0) < binderPages.count - 1 ? Theme.primaryText : Theme.tertiaryText)
                    }
                    .disabled((binderPage ?? 0) >= binderPages.count - 1)
                }
                .padding(.vertical, Theme.spacingSM)
            }
        }
    }

    private func binderPageView(_ cards: [OwnedCard]) -> some View {
        // 3x3 grid on a binder page
        VStack(spacing: 0) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                spacing: 10
            ) {
                ForEach(cards) { owned in
                    Button { selectedCard = owned.model } label: {
                        binderSlot(owned)
                    }
                    .buttonStyle(.plain)
                }

                // Fill empty slots on last page
                if cards.count < 9 {
                    ForEach(0..<(9 - cards.count), id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Theme.cardSurface.opacity(0.3))
                            .aspectRatio(0.714, contentMode: .fit)
                    }
                }
            }
            .padding(16)
            .background(
                // Binder page background
                RoundedRectangle(cornerRadius: Theme.radiusMD)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hex: 0x1E2A36),
                                Color(hex: 0x162230),
                                Color(hex: 0x1E2A36)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            )
            .overlay {
                // Binder ring holes on the left edge
                HStack {
                    VStack(spacing: 50) {
                        ForEach(0..<3, id: \.self) { _ in
                            Circle()
                                .fill(Theme.background)
                                .frame(width: 10, height: 10)
                        }
                    }
                    .offset(x: -3)
                    Spacer()
                }
            }
            .padding(.horizontal, Theme.spacingMD)
        }
        .compositingGroup()
    }

    private func binderSlot(_ owned: OwnedCard) -> some View {
        CachedCardImage(urlString: owned.model.imageSmallURL)
            .aspectRatio(0.714, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 6))
            .background {
                // Shadow rendered from a vector path, not from the rasterized image alpha —
                // much cheaper on device than `.shadow` on a clipped UIImage.
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
            }
            .overlay(alignment: .bottomTrailing) {
                if owned.count > 1 {
                    Text("×\(owned.count)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.background)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Theme.accent, in: Capsule())
                        .padding(3)
                }
            }
    }

    // MARK: - List View

    private var listView: some View {
        LazyVStack(spacing: Theme.spacingSM) {
            ForEach(displayedCards) { owned in
                Button {
                    selectedCard = owned.model
                } label: {
                    HStack(spacing: Theme.spacingSM) {
                        CachedCardImage(urlString: owned.model.imageSmallURL)
                            .aspectRatio(0.714, contentMode: .fit)
                            .frame(width: 65)
                            .clipShape(.rect(cornerRadius: 6))

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Text(owned.model.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.primaryText)
                                    .lineLimit(1)

                                if owned.model.isFavorite {
                                    Image(systemName: "heart.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.red)
                                }
                            }

                            HStack(spacing: 6) {
                                Text("#\(owned.model.number)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(Theme.tertiaryText)

                                Text(owned.model.rarity.capitalized)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(Theme.rarityColor(for: owned.model.rarity))
                            }

                            Text(owned.firstPulled, style: .date)
                                .font(.caption2)
                                .foregroundStyle(Theme.tertiaryText)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 4) {
                            Text("×\(owned.count)")
                                .font(.subheadline.weight(.bold).monospacedDigit())
                                .foregroundStyle(Theme.primaryText)

                            if let market = owned.model.priceMarket {
                                Text("$\(market, specifier: "%.2f")")
                                    .font(.caption.weight(.medium).monospacedDigit())
                                    .foregroundStyle(Theme.accent)
                            }

                            if let low = owned.model.priceLow {
                                Text("Low $\(low, specifier: "%.2f")")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .padding(Theme.spacingSM)
                    .background(Theme.cardSurface, in: .rect(cornerRadius: Theme.radiusSM))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.spacingMD)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.spacingMD) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(Theme.tertiaryText)
            Text("No cards yet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
            Text("Rip some packs to start your collection!")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .containerRelativeFrame(.vertical) { height, _ in height * 0.8 }
    }

    // MARK: - Sort & Filter

    private func applySortAndFilter(to cards: [OwnedCard]) -> [OwnedCard] {
        var result = cards

        // Search
        if !searchText.isEmpty {
            result = result.filter {
                $0.model.name.localizedCaseInsensitiveContains(searchText)
            }
        }

        // Favorites filter
        if filterFavorites {
            result = result.filter { $0.model.isFavorite }
        }

        // Rarity filter
        if let rarity = filterRarity {
            result = result.filter { $0.model.rarity == rarity }
        }

        // Sort
        switch sortOption {
        case .recent:
            result.sort { $0.lastPulled > $1.lastPulled }
        case .name:
            result.sort { $0.model.name < $1.model.name }
        case .rarity:
            result.sort { $0.model.rarityRank > $1.model.rarityRank }
        case .setNumber:
            result.sort { $0.model.number.localizedStandardCompare($1.model.number) == .orderedAscending }
        }

        return result
    }
}

// MARK: - Owned Card

struct OwnedCard: Identifiable {
    let model: CardModel
    let count: Int
    let firstPulled: Date
    let lastPulled: Date

    var id: String { model.apiID }
}
