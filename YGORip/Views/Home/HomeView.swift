import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(CollectionStats.self) private var collectionStats
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SetModel.releaseDate, order: .reverse) private var sets: [SetModel]

    @State private var selectedSeries: String?
    @State private var searchText = ""
    @State private var sortOption: SetSortOption = .newest

    enum SetSortOption: String, CaseIterable {
        case newest = "Newest"
        case oldest = "Oldest"
        case name = "Name"
        case completion = "Completion"
    }
    @State private var isSyncing = false
    @State private var syncError: String?
    @State private var shimmerPhase: CGFloat = -1
    @State private var showCrossPromo = false

    private let syncService = SetSyncService.shared

    /// Unique series names ordered by most recent set release date.
    private var seriesNames: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for set in sets {
            if seen.insert(set.series).inserted {
                ordered.append(set.series)
            }
        }
        return ordered
    }

    private var filteredSets: [SetModel] {
        var result = sets
        if let series = selectedSeries {
            result = result.filter { $0.series == series }
        }
        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        switch sortOption {
        case .newest:
            result.sort { $0.releaseDate > $1.releaseDate }
        case .oldest:
            result.sort { $0.releaseDate < $1.releaseDate }
        case .name:
            result.sort { $0.name < $1.name }
        case .completion:
            let counts = ownedCountBySet
            result.sort {
                let a = Double(counts[$0.apiID] ?? 0) / Double(max($0.totalCards, 1))
                let b = Double(counts[$1.apiID] ?? 0) / Double(max($1.totalCards, 1))
                return a > b
            }
        }
        return result
    }

    /// Unique card count per set — pre-aggregated by `CollectionStats` so we
    /// don't keep an `@Query<PullRecord>` observer alive in this view (which
    /// would re-fetch the whole table every time any pack saved).
    private var ownedCountBySet: [String: Int] {
        collectionStats.ownedUniqueBySet
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.spacingLG) {
                    if !NetworkMonitor.shared.isConnected {
                        offlineBanner
                    }

                    if !appState.isUnlimitedRips {
                        dailyPackCounter
                    }

                    // Search + sort
                    HStack(spacing: Theme.spacingSM) {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(Theme.tertiaryText)
                            TextField("Search sets", text: $searchText)
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

                        Menu {
                            ForEach(SetSortOption.allCases, id: \.self) { option in
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
                            Image(systemName: "arrow.up.arrow.down")
                                .foregroundStyle(Theme.accent)
                                .frame(width: 36, height: 36)
                                .background(Theme.cardSurface, in: .rect(cornerRadius: Theme.radiusSM))
                        }
                    }

                    if !seriesNames.isEmpty {
                        seriesPills
                    }

                    if isSyncing && sets.isEmpty {
                        loadingState
                    } else if let error = syncError, sets.isEmpty {
                        errorState(error)
                    } else {
                        setGrid
                    }
                }
                .padding(Theme.spacingMD)
            }
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
            .task { await syncSetsIfNeeded() }
            .refreshable { await syncSetsIfNeeded() }
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    shimmerPhase = 1
                }
                // Cross-promo fires once, on first return to Home after the
                // user has opened their first pack. Flip `crossPromoSeen`
                // up front so swipe-to-dismiss also counts (otherwise the
                // sheet would re-open on next .onAppear).
                if appState.hasOpenedFirstPack && !appState.crossPromoSeen {
                    appState.crossPromoSeen = true
                    showCrossPromo = true
                }
            }
            .sheet(isPresented: $showCrossPromo) {
                CrossPromoModal(sibling: .pokeRip) {
                    showCrossPromo = false
                }
            }
        }
    }

    // MARK: - Pack Counter

    /// Free-tier pack budget indicator. Hidden by the call site when the
    /// user owns Unlimited Rips — the circles are meaningless in that case.
    private var dailyPackCounter: some View {
        HStack(spacing: Theme.spacingSM) {
            ForEach(0..<AppState.maxPacks, id: \.self) { index in
                Circle()
                    .fill(index < appState.currentPacks ? Theme.accent : Theme.cardSurface)
                    .frame(width: 12, height: 12)
            }

            if let countdown = appState.nextPackCountdown {
                Text("\(appState.currentPacks)/\(AppState.maxPacks) • next in \(countdown)")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            } else {
                Text("\(appState.currentPacks)/\(AppState.maxPacks)")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    // MARK: - Series Pills

    private var seriesPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.spacingSM) {
                seriesPill("All", isSelected: selectedSeries == nil) {
                    selectedSeries = nil
                }

                ForEach(seriesNames, id: \.self) { series in
                    seriesPill(series, isSelected: selectedSeries == series) {
                        selectedSeries = series
                    }
                }
            }
        }
    }

    private func seriesPill(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? Theme.background : Theme.primaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    if isSelected {
                        Capsule().fill(Theme.holo)
                    } else {
                        Capsule().fill(Theme.cardSurface)
                    }
                }
        }
    }

    // MARK: - Set Grid

    private var setGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.spacingMD)],
            spacing: Theme.spacingMD
        ) {
            ForEach(filteredSets, id: \.apiID) { set in
                NavigationLink(value: set) {
                    SetGridCard(set: set, ownedCount: ownedCountBySet[set.apiID] ?? 0)
                }
                .buttonStyle(.plain)
            }
        }
        .navigationDestination(for: SetModel.self) { set in
            SetDetailView(set: set)
        }
    }

    // MARK: - Loading / Error States

    private var loadingState: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.spacingMD)],
            spacing: Theme.spacingMD
        ) {
            ForEach(0..<8, id: \.self) { _ in
                skeletonSetCard
            }
        }
    }

    private var skeletonSetCard: some View {
        VStack(spacing: Theme.spacingSM) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.cardSurface)
                .frame(height: 80)
                .shimmer(phase: shimmerPhase)

            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.cardSurface)
                .frame(height: 12)
                .shimmer(phase: shimmerPhase)

            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.cardSurface)
                .frame(width: 60, height: 10)
                .shimmer(phase: shimmerPhase)
        }
        .padding(Theme.spacingMD)
        .background(Theme.cardSurface.opacity(0.5), in: .rect(cornerRadius: Theme.radiusMD))
    }

    private var offlineBanner: some View {
        HStack(spacing: Theme.spacingSM) {
            Image(systemName: "wifi.slash")
            Text("Offline — showing cached sets")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(Theme.primaryText)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.spacingSM)
        .background(Theme.cardSurface, in: .rect(cornerRadius: Theme.radiusSM))
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: Theme.spacingMD) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(Theme.tertiaryText)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await syncSetsIfNeeded() }
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - Sync

    private func syncSetsIfNeeded() async {
        guard !isSyncing, NetworkMonitor.shared.isConnected else { return }
        isSyncing = true
        syncError = nil

        do {
            try await syncService.syncAllSets(container: modelContext.container)
        } catch {
            if !NetworkMonitor.shared.isConnected {
                syncError = nil // Don't show error if we just went offline
            } else {
                syncError = error.localizedDescription
            }
        }

        isSyncing = false
    }
}
