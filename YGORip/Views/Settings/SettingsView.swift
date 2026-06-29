import SwiftUI
import SwiftData
import RevenueCat

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(CollectionStats.self) private var collectionStats
    @Environment(\.modelContext) private var modelContext
    @Environment(StoreKitService.self) private var storeKit
    @State private var showResetConfirmation = false
    @State private var showResetSuccess = false
    @State private var showDisclaimerSheet = false
    @State private var backupInfo: CollectionBackup.RestoreInfo?
    @State private var canRestore = false
    @State private var showRestoreConfirmation = false
    @State private var restoreResultMessage: String?
    #if DEBUG
    @State private var showDebugCrossPromo = false
    #endif

    var body: some View {
        NavigationStack {
            List {
                premiumSection
                preferencesSection
                gameplaySection
                dataSection
                moreFromLavaiLabsSection
                supportSection
                legalSection
                aboutSection
                #if DEBUG
                debugSection
                #endif
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
            .tint(Theme.accent)
            .foregroundStyle(Theme.primaryText)
            .task { if storeKit.offerings.isEmpty { await storeKit.loadOfferings() } }
            .onAppear { refreshBackupState() }
            .alert("Restore from Backup?", isPresented: $showRestoreConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Restore") {
                    Task {
                        let count = await CollectionRestore.perform(
                            modelContext: modelContext,
                            collectionStats: collectionStats
                        )
                        refreshBackupState()
                        restoreResultMessage = count > 0
                            ? "Restored \(count) cards. Refreshing prices in the background…"
                            : "Nothing to restore."
                    }
                }
            } message: {
                if let info = backupInfo {
                    Text("This re-adds \(info.recordCount) cards from your backup of \(info.savedAt.formatted(date: .abbreviated, time: .shortened)).")
                }
            }
            .alert("Restore Complete", isPresented: Binding(
                get: { restoreResultMessage != nil },
                set: { if !$0 { restoreResultMessage = nil } }
            )) {
                Button("OK") {}
            } message: {
                Text(restoreResultMessage ?? "")
            }
            .alert("Reset Collection", isPresented: $showResetConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete Everything", role: .destructive) {
                    resetAllData()
                }
            } message: {
                Text("This will permanently delete all your pulled cards, pull history, and stats. This cannot be undone.")
            }
            .alert("Collection Reset", isPresented: $showResetSuccess) {
                Button("OK") {}
            } message: {
                Text("All data has been deleted. Start fresh!")
            }
            .sheet(isPresented: $showDisclaimerSheet) {
                disclaimerSheet
            }
            #if DEBUG
            .sheet(isPresented: $showDebugCrossPromo) {
                CrossPromoModal(siblings: SiblingApp.crossPromoTargets) {
                    showDebugCrossPromo = false
                }
            }
            #endif
        }
    }

    // MARK: - Premium

    private var premiumSection: some View {
        Section {
            if appState.isUnlimitedRips {
                HStack {
                    Label("Unlimited Rips", systemImage: "flame.fill")
                        .foregroundStyle(Theme.gold)
                    Spacer()
                    Text("Active")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.gold)
                }
            } else {
                VStack(alignment: .leading, spacing: Theme.spacingSM) {
                    Label("Support YuRip", systemImage: "heart.fill")
                        .foregroundStyle(Theme.gold)

                    Text("A one-time tip (no subscription) unlocks unlimited pack opens and removes the regen timer for good.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }

                // Tip tiers
                ForEach(storeKit.offerings, id: \.identifier) { package in
                    Button {
                        Task { await storeKit.purchase(package) }
                    } label: {
                        HStack {
                            Label(package.storeProduct.localizedTitle, systemImage: "gift.fill")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.primaryText)
                            Spacer()
                            Text(package.localizedPriceString)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Theme.gold)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Theme.gold.opacity(0.15), in: Capsule())
                        }
                    }
                }

                Button {
                    Task { await storeKit.restore() }
                } label: {
                    HStack {
                        Label("Restore Purchases", systemImage: "arrow.clockwise")
                        if storeKit.isRestoring {
                            Spacer()
                            ProgressView()
                                .tint(Theme.accent)
                        }
                    }
                }
                .disabled(storeKit.isRestoring)
            }

            if let message = storeKit.restoreMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(storeKit.isUnlimitedRips ? .green : Theme.secondaryText)
            }

            #if DEBUG
            if let error = storeKit.purchaseError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            #endif
        } header: {
            Text("Premium")
                .foregroundStyle(Theme.secondaryText)
        }
        .listRowBackground(Theme.cardSurface)
    }

    // MARK: - Preferences

    @ViewBuilder
    private var preferencesSection: some View {
        Section {
            @Bindable var state = appState
            Toggle(isOn: $state.hapticsEnabled) {
                Label("Haptic Feedback", systemImage: "hand.tap.fill")
            }
            #if DEBUG
            // Sound effects are wired up but not yet shipped to release
            // builds — default volume is 0, slider hidden. When ready to
            // launch, remove the #if and raise the default in AppState.
            VStack(alignment: .leading, spacing: Theme.spacingXS) {
                Label("Sound Effects", systemImage: state.soundEffectsVolume > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill")
                Slider(value: $state.soundEffectsVolume, in: 0...1)
                    .tint(Theme.accent)
            }
            #endif
            Toggle(isOn: $state.notificationsEnabled) {
                Label("Pack Notifications", systemImage: "bell.fill")
            }
            .onChange(of: appState.notificationsEnabled) { _, enabled in
                if enabled { appState.requestNotificationPermission() }
            }
            Picker(selection: cardMotionBinding(for: state)) {
                Text("None").tag(CardMotionMode.off)
                Text("Idle").tag(CardMotionMode.idle)
                Text("Gyro").tag(CardMotionMode.gyro)
            } label: {
                Label("Card Motion", systemImage: "gyroscope")
            }
        } header: {
            Text("Preferences")
                .foregroundStyle(Theme.secondaryText)
        }
        .listRowBackground(Theme.cardSurface)
    }

    // MARK: - Gameplay

    @ViewBuilder
    private var gameplaySection: some View {
        Section {
            @Bindable var state = appState
            Toggle(isOn: $state.unownedCardBiasEnabled) {
                Label("Favor Unpulled Cards", systemImage: "wand.and.stars")
            }
        } header: {
            Text("Gameplay")
                .foregroundStyle(Theme.secondaryText)
        } footer: {
            Text("Once a set passes 60% complete, packs lean toward cards you haven't pulled yet — scaling up to 4× by 100%. Turn off for pure pack RNG.")
                .foregroundStyle(Theme.tertiaryText)
        }
        .listRowBackground(Theme.cardSurface)
    }

    // MARK: - Support

    private let appStoreID = "6773177746"

    // MARK: - More from Lavai Labs

    private let siblingApps: [SiblingApp] = [.mtgRip, .pokeRip]

    private var moreFromLavaiLabsSection: some View {
        Section {
            ForEach(siblingApps, id: \.appStoreID) { app in
                if let url = app.appStoreURL {
                    Link(destination: url) {
                        HStack(spacing: Theme.spacingMD) {
                            Group {
                                if let asset = app.iconAsset, UIImage(named: asset) != nil {
                                    Image(asset)
                                        .resizable()
                                        .interpolation(.high)
                                } else {
                                    Image(systemName: app.fallbackSymbol)
                                        .resizable()
                                        .scaledToFit()
                                        .symbolRenderingMode(.hierarchical)
                                        .foregroundStyle(Theme.gold)
                                        .padding(8)
                                        .background(Theme.cardSurface)
                                }
                            }
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.primaryText)
                                Text(app.tagline)
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryText)
                            }

                            Spacer()

                            Image(systemName: "arrow.up.right.square")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
        } header: {
            Text("More from Lavai Labs")
                .foregroundStyle(Theme.secondaryText)
        }
        .listRowBackground(Theme.cardSurface)
    }

    private var supportSection: some View {
        Section {
            if let url = URL(string: "https://apps.apple.com/app/id\(appStoreID)?action=write-review") {
                Link(destination: url) {
                    Label("Rate YuRip", systemImage: "star.fill")
                }
            }

            if let url = URL(string: "mailto:yurip@lavailabs.com") {
                Link(destination: url) {
                    Label("Contact Support", systemImage: "envelope.fill")
                }
            }
        } header: {
            Text("Support")
                .foregroundStyle(Theme.secondaryText)
        }
        .listRowBackground(Theme.cardSurface)
    }

    // MARK: - Legal

    private var legalSection: some View {
        Section {
            if let url = URL(string: "https://lavailabs.com/ygo-rip/privacy") {
                Link(destination: url) {
                    Label("Privacy Policy", systemImage: "hand.raised.fill")
                }
            }

            if let url = URL(string: "https://lavailabs.com/ygo-rip/terms") {
                Link(destination: url) {
                    Label("Terms of Service", systemImage: "doc.text.fill")
                }
            }

            Button {
                showDisclaimerSheet = true
            } label: {
                Label("IP Disclaimer", systemImage: "info.circle.fill")
            }
        } header: {
            Text("Legal")
                .foregroundStyle(Theme.secondaryText)
        }
        .listRowBackground(Theme.cardSurface)
    }

    // MARK: - Danger Zone

    private var dataSection: some View {
        Section {
            if let info = backupInfo {
                HStack {
                    Label("Last Backup", systemImage: "externaldrive.fill.badge.checkmark")
                    Spacer()
                    Text("\(info.recordCount) cards")
                        .foregroundStyle(Theme.tertiaryText)
                }
                HStack {
                    Label {
                        Text("Saved")
                    } icon: {
                        // Invisible placeholder so "Saved" (and the row
                        // separator) line up under "Last Backup" without a
                        // second, redundant drive icon.
                        Image(systemName: "externaldrive.fill.badge.checkmark")
                            .hidden()
                    }
                    Spacer()
                    Text(info.savedAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(Theme.tertiaryText)
                }
                Button {
                    showRestoreConfirmation = true
                } label: {
                    Label("Restore from Backup", systemImage: "arrow.counterclockwise")
                }
                .disabled(!canRestore)
            }

            Button(role: .destructive) {
                showResetConfirmation = true
            } label: {
                Label("Reset Collection", systemImage: "trash.fill")
            }
        } header: {
            Text("Data")
                .foregroundStyle(Theme.secondaryText)
        } footer: {
            Text(dataSectionFooter)
                .foregroundStyle(Theme.tertiaryText)
        }
        .listRowBackground(Theme.cardSurface)
    }

    private var dataSectionFooter: String {
        if canRestore {
            return "Your collection looks empty. Restore re-adds your backed-up cards. Reset clears everything, including the backup."
        }
        if backupInfo != nil {
            return "Your cards are backed up automatically. Reset permanently deletes everything, including the backup."
        }
        return "Open a pack to start a backup. Reset permanently deletes all pulled cards, history, and stats."
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    .foregroundStyle(Theme.tertiaryText)
            }

            HStack {
                Text("Build")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                    .foregroundStyle(Theme.tertiaryText)
            }
        } header: {
            Text("About")
                .foregroundStyle(Theme.secondaryText)
        }
        .listRowBackground(Theme.cardSurface)
    }

    // MARK: - Debug

    #if DEBUG
    private var debugSection: some View {
        Section {
            @Bindable var state = appState
            Toggle(isOn: $state.isUnlimitedRips) {
                Label("Unlimited Rips", systemImage: "flame.fill")
            }

            Button("Reset Daily Pack Counter") {
                UserDefaults.standard.set(0, forKey: "packsOpenedToday")
                UserDefaults.standard.removeObject(forKey: "lastPackDate")
            }

            Button("Force Next Hot Pack") {
                PullRateEngine.forceNextHotPack = true
            }

            Menu {
                Button("Tier 0 — Common")          { PullRateEngine.forceNextPackRarity = "Common" }
                Button("Tier 1 — Rare")            { PullRateEngine.forceNextPackRarity = "Rare" }
                Button("Tier 2 — Super Rare")      { PullRateEngine.forceNextPackRarity = "Super Rare" }
                Button("Tier 3 — Ultra Rare")      { PullRateEngine.forceNextPackRarity = "Ultra Rare" }
                Button("Tier 4 — Secret Rare")     { PullRateEngine.forceNextPackRarity = "Secret Rare" }
                Button("Tier 4 — Starlight Rare")  { PullRateEngine.forceNextPackRarity = "Starlight Rare" }
                Button("Tier 4 — 25th Anniv. Secret") { PullRateEngine.forceNextPackRarity = "Quarter Century Secret Rare" }
            } label: {
                Label("Force Next Pack Rarity", systemImage: "wand.and.stars")
            }

            Button("Add 100 Fake Packs to Stats") {
                UserDefaults.standard.set(
                    appState.totalPacksOpened + 100,
                    forKey: "totalPacksOpened"
                )
            }

            NavigationLink {
                FoilPreview()
            } label: {
                Label("Foil Sandbox", systemImage: "sparkles.rectangle.stack")
            }

            Button {
                showDebugCrossPromo = true
            } label: {
                Label("Show Cross-Promo Modal", systemImage: "megaphone.fill")
            }

            Button(role: .destructive) {
                simulateDataLoss()
            } label: {
                Label("Simulate Data Loss (keep backup)", systemImage: "exclamationmark.triangle.fill")
            }
        } header: {
            Text("Debug")
                .foregroundStyle(Theme.secondaryText)
        } footer: {
            Text("Only visible in debug builds.")
                .foregroundStyle(Theme.tertiaryText)
        }
        .listRowBackground(Theme.cardSurface)
    }
    #endif

    // MARK: - Disclaimer Sheet

    private var disclaimerSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacingMD) {
                    Text("Disclaimer")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.primaryText)

                    Text("""
                    YuRip is an independent, unofficial fan project. It is not \
                    produced, endorsed, supported by, or affiliated with any trading \
                    card game publisher or rights-holder.

                    All card names, artwork, and related content are the property of \
                    their respective owners. Card images and data are sourced from \
                    publicly available community resources covering published trading cards.

                    This app is created for entertainment and educational purposes only. \
                    No real cards are distributed or sold. Pull rates \
                    are simulated and do not represent actual product odds. \
                    No copyright infringement is intended.
                    """)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                }
                .padding(Theme.spacingLG)
            }
            .background(Theme.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showDisclaimerSheet = false }
                }
            }
        }
    }

    // MARK: - Card Motion Setting

    private enum CardMotionMode: String, Hashable {
        case off, idle, gyro
    }

    /// Bridges the tri-state picker to the two underlying booleans so we
    /// don't have to migrate UserDefaults. Gyro takes priority on read.
    private func cardMotionBinding(for state: AppState) -> Binding<CardMotionMode> {
        Binding(
            get: {
                if state.gyroEnabled { return .gyro }
                if state.idleHoloShimmerEnabled { return .idle }
                return .off
            },
            set: { mode in
                switch mode {
                case .off:
                    state.gyroEnabled = false
                    state.idleHoloShimmerEnabled = false
                case .idle:
                    state.gyroEnabled = false
                    state.idleHoloShimmerEnabled = true
                case .gyro:
                    state.gyroEnabled = true
                    state.idleHoloShimmerEnabled = false
                }
            }
        )
    }

    // MARK: - Actions

    private func resetAllData() {
        // 1. Wipe SwiftData rows.
        do {
            try modelContext.delete(model: PullRecord.self)
            try modelContext.delete(model: CardModel.self)
            try modelContext.delete(model: SetModel.self)
            try modelContext.save()
        } catch {
            // SwiftData delete can throw but rarely fails
        }

        // 2. Clear the in-memory CollectionStats aggregates. Without
        //    this, Home / Stats keep showing pre-reset counts until
        //    the next app launch re-initializes the cache from the
        //    (now empty) database.
        collectionStats.reset()

        // 3. Reset AppState pack counters via the @Observable setters.
        //    Poking UserDefaults directly (the old reset path did)
        //    leaves AppState's in-memory values stale until relaunch.
        appState.resetCollectionCounters()

        // 4. Discard any pack staged by the prefetcher. The staged pack's
        //    PulledCards have `isNew` baked in from the pre-reset PullRecord
        //    state — without invalidating, the next pack the user opens
        //    would show its cards as "not new" because they were previously
        //    owned, even though their entire pull history was just wiped.
        PackPrefetcher.shared.cancelPending()

        // 5. Re-arm the one-shot price backfill so post-reset pulls
        //    of previously-owned cards get fresh prices instead of
        //    inheriting whatever bundled-or-stale prices SwiftData
        //    would re-seed on next sync.
        PriceBackfillService.reset()

        // 6. Legacy UserDefaults keys the resetCollectionCounters() path
        //    doesn't own (kept as belt-and-suspenders for older builds).
        UserDefaults.standard.set(0, forKey: "packsOpenedToday")
        UserDefaults.standard.removeObject(forKey: "lastPackDate")

        // Clear the recoverable backup to an empty snapshot. Without this, the
        // wiped store + a stale non-empty backup would offer to restore on the
        // next launch and resurrect the data the user just deleted.
        CollectionBackup.clear()
        refreshBackupState()

        showResetSuccess = true
    }

    private func refreshBackupState() {
        backupInfo = CollectionBackup.lastBackup()
        canRestore = CollectionBackup.availableRestore(context: modelContext) != nil
    }

    #if DEBUG
    /// Snapshots current data, then wipes the store to mimic a migration
    /// data-loss — relaunch to see the restore prompt. Keeps the backup so the
    /// prompt has something to offer; cards/sets re-seed from the bundle.
    private func simulateDataLoss() {
        CollectionBackup.write(from: modelContext)
        try? modelContext.delete(model: PullRecord.self)
        try? modelContext.delete(model: CardModel.self)
        try? modelContext.delete(model: SetModel.self)
        try? modelContext.save()
        collectionStats.reset()
        refreshBackupState()
    }
    #endif
}
