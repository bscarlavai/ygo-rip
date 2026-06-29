import SwiftUI
import StoreKit
import SwiftData

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(CollectionStats.self) private var collectionStats
    @Environment(\.modelContext) private var modelContext
    @Environment(\.requestReview) private var requestReview

    @State private var restoreInfo: CollectionBackup.RestoreInfo?
    @State private var confirmStartFresh = false

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
            // Offer to restore if the store is empty but a backup exists (an
            // unintended wipe). Surfaced as a prompt, never applied silently.
            restoreInfo = CollectionBackup.availableRestore(context: modelContext)
            // Not a wipe → ensure a current backup exists. Covers users updating
            // into this version: they're protected from first launch instead of
            // waiting for their next pack or app-background. (write() guards
            // against clobbering a good backup, so this is safe.)
            if restoreInfo == nil {
                let container = modelContext.container
                Task.detached { CollectionBackup.write(from: ModelContext(container)) }
            }
        }
        .onChange(of: appState.shouldRequestReview) { _, shouldRequest in
            if shouldRequest {
                requestReview()
                appState.shouldRequestReview = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            // Centralized backup refresh: captures current pulls +
            // favorites/wishlist whenever the user leaves the app. write()
            // guards against clobbering a good backup with an empty one.
            let container = modelContext.container
            Task.detached { CollectionBackup.write(from: ModelContext(container)) }
        }
        // Primary prompt. Modal and forced (no soft dismiss): the user must
        // pick Restore or Start Fresh before reaching the app, so they can't
        // start playing and silently overwrite the backup mid-decision.
        .alert("Restore your collection?", isPresented: Binding(
            get: { restoreInfo != nil && !confirmStartFresh },
            set: { if !$0 && !confirmStartFresh { restoreInfo = nil } }
        )) {
            Button("Restore") {
                restoreInfo = nil
                Task { await CollectionRestore.perform(modelContext: modelContext, collectionStats: collectionStats) }
            }
            Button("Start Fresh", role: .destructive) { confirmStartFresh = true }
        } message: {
            if let info = restoreInfo {
                Text("Your collection looks empty, but we found a backup of \(info.recordCount) cards from \(info.savedAt.formatted(date: .abbreviated, time: .shortened)).")
            }
        }
        // Destructive confirm. A stale backup can't coexist with a fresh start,
        // so declining deletes it — double-confirmed since it's irreversible.
        .alert("Delete your backup?", isPresented: $confirmStartFresh) {
            Button("Delete Backup", role: .destructive) {
                CollectionBackup.delete()
                confirmStartFresh = false
                restoreInfo = nil
            }
            // Returns to the restore prompt (restoreInfo is still set).
            Button("Keep Backup", role: .cancel) { confirmStartFresh = false }
        } message: {
            if let info = restoreInfo {
                Text("This permanently deletes your backup of \(info.recordCount) cards and can't be undone.")
            }
        }
    }
}
