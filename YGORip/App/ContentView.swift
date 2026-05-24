import SwiftUI
import StoreKit
import SwiftData

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(CollectionStats.self) private var collectionStats
    @Environment(\.modelContext) private var modelContext
    @Environment(\.requestReview) private var requestReview

    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }

            CollectionView()
                .tabItem {
                    Label("Collection", systemImage: "book.closed.fill")
                }

            StatsView()
                .tabItem {
                    Label("Stats", systemImage: "chart.bar.fill")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .tint(Theme.accent)
        .task {
            // Initial aggregation pass — runs off the main actor and
            // populates CollectionStats's published values. Home / Collection
            // / Stats views read from there instead of @Query<PullRecord>,
            // so the heavy table sweep happens once at launch instead of
            // synchronously on every pack save.
            collectionStats.refresh(container: modelContext.container)
        }
        .onChange(of: appState.shouldRequestReview) { _, shouldRequest in
            if shouldRequest {
                requestReview()
                appState.shouldRequestReview = false
            }
        }
    }
}
