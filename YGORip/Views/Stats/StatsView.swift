import SwiftUI
import SwiftData

struct StatsView: View {
    @Environment(AppState.self) private var appState
    @Environment(CollectionStats.self) private var collectionStats
    @Query private var allCards: [CardModel]
    @Query private var allSets: [SetModel]

    @State private var shareItem: ShareableImage?
    @State private var selectedCard: CardModel?
    @State private var lastPullCount = 0

    // Cached stats — rebuilt only when CollectionStats's totalPulls changes
    @State private var cachedUniqueCount = 0
    @State private var cachedRarityBreakdown: [(String, Int)] = []
    @State private var cachedLuckiestPulls: [(CardModel, Double)] = []
    @State private var cachedCollectionValue = 0.0
    @State private var cachedSetCompletions: [(SetModel, Int, Int)] = []

    private func rebuildStats() {
        let cardsByID = Dictionary(uniqueKeysWithValues: allCards.map { ($0.apiID, $0) })
        let setsByID = Dictionary(uniqueKeysWithValues: allSets.map { ($0.apiID, $0) })
        let pullCount = collectionStats.pullCountByCardID

        // Unique count
        cachedUniqueCount = pullCount.count

        // Rarity breakdown — YGO rarity tiers, ordered low → high.
        // `rarityCounts` keys are the raw per-printing rarity strings stored
        // on CardModel (capitalized as YGOPRODeck returns them, e.g.
        // "Super Rare", "Quarter Century Secret Rare").
        let rarityCounts = collectionStats.rarityCounts
        let order = [
            "Common",
            "Short Print",
            "Rare",
            "Super Rare",
            "Ultra Rare",
            "Ultimate Rare",
            "Secret Rare",
            "Ghost Rare",
            "Starlight Rare",
            "Quarter Century Secret Rare",
            "Collector's Rare",
            "Prismatic Secret Rare",
        ]
        cachedRarityBreakdown = order.compactMap { rarity in
            guard let count = rarityCounts[rarity], count > 0 else { return nil }
            return (rarity, count)
        }

        // Luckiest pulls + collection value (single pass over the per-card
        // pull counts).
        var pulls: [(CardModel, Double)] = []
        var totalValue = 0.0
        for (cardID, count) in pullCount {
            guard let card = cardsByID[cardID], let price = card.priceMarket, price > 0 else { continue }
            pulls.append((card, price))
            totalValue += price * Double(count)
        }
        cachedLuckiestPulls = pulls.sorted { $0.1 > $1.1 }.prefix(5).map { $0 }
        cachedCollectionValue = totalValue

        // Set completions. Use the actual bundled card count per set rather
        // than setModel.totalCards — set metadata can lag the real card list,
        // causing owned > total display.
        let cardsBySet = Dictionary(grouping: allCards) { $0.setID }
        var completions: [(SetModel, Int, Int)] = []
        for (setID, uniqueInSet) in collectionStats.ownedUniqueBySet {
            guard let setModel = setsByID[setID] else { continue }
            let totalInSet = cardsBySet[setID]?.count ?? setModel.totalCards
            let denominator = max(uniqueInSet, totalInSet)
            completions.append((setModel, uniqueInSet, denominator))
        }
        cachedSetCompletions = completions.sorted {
            Double($0.1) / Double(max($0.2, 1)) > Double($1.1) / Double(max($1.2, 1))
        }

        lastPullCount = collectionStats.totalPulls
    }

    // Convenience accessors for the cached data
    private var rarityBreakdown: [(String, Int)] { cachedRarityBreakdown }
    private var luckiestPulls: [(CardModel, Double)] { cachedLuckiestPulls }
    private var totalCollectionValue: Double { cachedCollectionValue }
    private var setCompletions: [(SetModel, Int, Int)] { cachedSetCompletions }

    var body: some View {
        ScrollView {
            if collectionStats.hasLoadedInitial && collectionStats.totalPulls == 0 {
                VStack(spacing: Theme.spacingMD) {
                    Image(systemName: "chart.bar")
                        .font(.system(size: 48))
                        .foregroundStyle(Theme.tertiaryText)
                    Text("No stats yet")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                    Text("Rip some packs and your stats will appear here!")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical) { height, _ in height * 0.95 }
                .padding(Theme.spacingLG)
            } else {
            VStack(spacing: Theme.spacingLG) {
                overviewCards
                rarityChart
                luckiestPullsList
                setCompletionList

                Button {
                    generateShareImage()
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text("Share Stats")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.cardSurface, in: .rect(cornerRadius: Theme.radiusMD))
                }
            }
            .padding(Theme.spacingMD)
            } // else
        }
        .background(Theme.background)
        .onAppear { rebuildStats() }
        .onChange(of: collectionStats.totalPulls) { _, _ in rebuildStats() }
        .sheet(item: $shareItem) { item in
            ShareSheet(image: item.image)
        }
        .adaptiveDetailSheet(item: $selectedCard) { card in
            CardInspectView(card: card)
        }
    }

    private func generateShareImage() {
        let bestPull = luckiestPulls.first
        let card = ShareStatsCard(
            totalPulls: collectionStats.totalPulls,
            uniqueCards: cachedUniqueCount,
            packsOpened: appState.totalPacksOpened,
            collectionValue: totalCollectionValue,
            bestPullName: bestPull?.0.name,
            bestPullRarity: bestPull?.0.rarity.capitalized,
            bestPullValue: bestPull?.1
        )
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3.0
        if let image = renderer.uiImage {
            shareItem = ShareableImage(image: image)
        }
    }

    // MARK: - Overview Cards

    private var overviewCards: some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            spacing: Theme.spacingSM
        ) {
            statCard("Total Pulls", value: "\(collectionStats.totalPulls)", icon: "rectangle.stack.fill")
            statCard("Unique Cards", value: "\(cachedUniqueCount)", icon: "sparkles")
            statCard("Packs Opened", value: "\(appState.totalPacksOpened)", icon: "shippingbox.fill")
            statCard("Collection Value", value: String(format: "$%.2f", totalCollectionValue), icon: "dollarsign.circle.fill")
        }
    }

    private func statCard(_ title: String, value: String, icon: String) -> some View {
        VStack(spacing: Theme.spacingSM) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Theme.holo)

            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.holo)

            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.spacingMD)
        .background(Theme.cardSurface, in: .rect(cornerRadius: Theme.radiusMD))
    }

    // MARK: - Rarity Breakdown

    private var rarityChart: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            Text("Rarity Breakdown")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primaryText)

            if rarityBreakdown.isEmpty {
                Text("No pulls yet")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
            } else {
                let maxCount = rarityBreakdown.map(\.1).max() ?? 1

                ForEach(rarityBreakdown, id: \.0) { rarity, count in
                    HStack(spacing: Theme.spacingSM) {
                        Text(rarity)
                            .font(.caption)
                            .foregroundStyle(Theme.rarityColor(for: rarity))
                            .frame(width: 100, alignment: .trailing)

                        GeometryReader { geo in
                            let fraction = CGFloat(count) / CGFloat(maxCount)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Theme.rarityColor(for: rarity))
                                .frame(width: geo.size.width * fraction)
                        }
                        .frame(height: 12)

                        Text("\(count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
        .padding(Theme.spacingMD)
        .background(Theme.cardSurface, in: .rect(cornerRadius: Theme.radiusMD))
    }

    // MARK: - Luckiest Pulls

    private var luckiestPullsList: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            Text("Luckiest Pulls")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primaryText)

            if luckiestPulls.isEmpty {
                Text("Open packs to find your best pulls!")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
            } else {
                ForEach(Array(luckiestPulls.enumerated()), id: \.offset) { index, pull in
                    let (card, price) = pull
                    Button { selectedCard = card } label: {
                        HStack(spacing: Theme.spacingSM) {
                            Text("\(index + 1).")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(Theme.holo)
                                .frame(width: 20)

                            CachedCardImage(urlString: card.imageSmallURL)
                                .aspectRatio(0.714, contentMode: .fit)
                                .frame(width: 36)
                                .clipShape(.rect(cornerRadius: 4))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(card.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Theme.primaryText)
                                    .lineLimit(1)
                                Text(card.rarity.capitalized)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.rarityColor(for: card.rarity))
                            }

                            Spacer()

                            Text(String(format: "$%.2f", price))
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(Theme.holo)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.spacingMD)
        .background(Theme.cardSurface, in: .rect(cornerRadius: Theme.radiusMD))
    }

    // MARK: - Set Completion

    private var setCompletionList: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            Text("Set Completion")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primaryText)

            if setCompletions.isEmpty {
                Text("Start collecting to track set progress!")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
            } else {
                ForEach(setCompletions, id: \.0.apiID) { set, owned, total in
                    VStack(spacing: 4) {
                        HStack {
                            Text(set.name)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Theme.primaryText)
                                .lineLimit(1)
                            Spacer()
                            Text("\(owned)/\(total)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.secondaryText)
                        }

                        GeometryReader { geo in
                            let fraction = total > 0 ? CGFloat(owned) / CGFloat(total) : 0
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.background)
                                Capsule()
                                    .fill(Theme.holo)
                                    .frame(width: geo.size.width * fraction)
                            }
                        }
                        .frame(height: 6)
                    }
                }
            }
        }
        .padding(Theme.spacingMD)
        .background(Theme.cardSurface, in: .rect(cornerRadius: Theme.radiusMD))
    }
}

struct ShareableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}
