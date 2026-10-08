import SwiftUI
import SwiftData

@main
struct YGORipApp: App {
    @State private var appState = AppState()
    @State private var storeKit = StoreKitService()
    @State private var collectionStats = CollectionStats()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false
    @State private var showDisclaimer = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(storeKit)
                .environment(collectionStats)
                .preferredColorScheme(.dark)
                .task { await compileFoilShaders() }
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView(isPresented: $showOnboarding) {
                        // After onboarding, show disclaimer
                        showDisclaimer = true
                    }
                    .interactiveDismissDisabled()
                }
                .sheet(isPresented: $showDisclaimer) {
                    DisclaimerView(isPresented: $showDisclaimer) {
                        hasCompletedOnboarding = true
                    }
                    .interactiveDismissDisabled()
                }
                .onAppear {
                    storeKit.appState = appState
                    storeKit.configure()
                    SoundEffectService.shared.appState = appState
                    if !hasCompletedOnboarding {
                        showOnboarding = true
                    }
                    appState.startRegenClock()
                    BackgroundMusicService.shared.setVolume(appState.backgroundMusicVolume)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                    appState.regenPacks()
                    // Restart rather than resume: the sleep is unreliable across
                    // suspension, and regenPacks() already applied what was
                    // earned while away — this re-arms it for the next pack.
                    appState.startRegenClock()
                    BackgroundMusicService.shared.resumeIfNeeded()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                    appState.stopRegenClock()
                    BackgroundMusicService.shared.pause()
                }
        }
        .modelContainer(for: [
            CardModel.self,
            SetModel.self,
            PullRecord.self
        ])
    }
}
