import SwiftUI
import SwiftData

/// The core pack opening experience — 4 phases: sealed → rip → reveal → summary.
struct PackOpeningView: View {
    let set: SetModel
    let cards: [CardModel]

    @Environment(AppState.self) private var appState
    @Environment(CollectionStats.self) private var collectionStats
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var foilMotion = FoilMotionProvider()

    @State private var phase: PackPhase = .sealed
    @State private var pulledCards: [PulledCard] = []
    @State private var currentIndex = 0
    @State private var revealedCount = 0
    @State private var hapticLight = 0
    @State private var hapticMedium = 0
    @State private var hapticHeavy = 0
    @State private var showRareFlash = false
    @State private var showDarkBackdrop = false
    @State private var revealScale: CGFloat = 1.0
    @State private var glowPulse = false

    // Tiered reveal dopamine state
    @State private var showRainbowBackdrop = false        // tier 4
    @State private var showLightRays = false              // tier 3+
    @State private var showContinuousTwinkles = false     // tier 3+
    @State private var particleBurstID = 0                // bump to fire burst
    @State private var shimmerSweepID = 0                 // bump to fire one-shot card sweep
    @State private var particlesVisible = true            // gates ParticleBurst opacity during swipes

    // Sealed phase animation state
    @State private var packBreathing = false
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var ripSplit: CGFloat = 0  // 0 = sealed, 1 = fully split
    @State private var ripFraction: CGFloat = 0.5  // where on the pack to split (0 = top, 1 = bottom)
    @State private var ripSeed: Int = Int.random(in: 0...10000)  // unique jagged pattern per rip

    // Card reveal swipe state
    @State private var cardSwipeOffset: CGFloat = 0
    @State private var cardSwipeRotation: Double = 0
    @State private var isCardSwiping = false


    // Preloading
    @State private var preloadedPack: [PulledCard]?
    /// Set true once slot 0's large image is in the cache. `ripPack` polls
    /// this with a 4s ceiling before transitioning to the reveal phase.
    @State private var firstCardReady = false
    @State private var isHotPack = false
    /// One-shot: ensures we don't save the same pack's PullRecords twice.
    /// Set inside `savePackIfNeeded` so concurrent callers (the .ripping
    /// Task and the .onDisappear safety net) can't double-save.
    @State private var packSaved = false
    /// Set true inside `savePackIfNeeded` when this pack pushed the set's
    /// unique-owned count from <100% to 100%. Drives the celebration banner
    /// at the top of the summary screen. Reset on `openAnother` so a second
    /// pack from the same (now-complete) set doesn't show stale celebration.
    @State private var justCompletedSet = false
    /// 0 = showing CardBackView, 1 = card flipped over to slot 0's front.
    /// The .ripping phase animates this to 1.0 as a "flip the card over"
    /// transition that hides the save's main-thread blip and bridges to
    /// the reveal phase. Slot 0 only — subsequent cards swipe normally.
    @State private var flipProgress: CGFloat = 0
    /// Discrete face-toggle. Driven manually at the flip's midpoint inside
    /// a non-animating transaction so the visibility swap snaps instantly
    /// while the 3D rotation continues to interpolate.
    @State private var showingCardFront = false

    // Card inspect from summary
    @State private var selectedCard: CardModel?

    @Environment(\.horizontalSizeClass) private var hSizeClass

    enum PackPhase {
        case sealed, ripping, reveal, summary
    }

    private var palette: PackPalette {
        PackPalette.palette(forSeries: set.series, shelf: set.shelf)
    }

    // MARK: - Foil motion (per Card Motion setting)

    private var gyroAvailable: Bool {
        !reduceMotion && appState.gyroEnabled
    }

    private var passiveMotionSource: FoilMotionProvider.Source? {
        if reduceMotion { return nil }
        if gyroAvailable { return .device }
        if appState.idleHoloShimmerEnabled { return .auto }
        return nil
    }

    private func foilTreatment(for card: PulledCard) -> FoilTreatment {
        guard !reduceMotion, passiveMotionSource != nil else { return .none }
        return FoilTreatment.forYGORarity(card.model.rarityTier)
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
        ZStack {
            Theme.background.ignoresSafeArea()

            switch phase {
            case .sealed:
                sealedPhase
            case .ripping:
                rippingPhase
            case .reveal:
                revealPhase
            case .summary:
                summaryPhase
            }

            // Rare card flash overlay — softer opacity (0.08) so rapid card
            // flips don't strobe. Reduce Motion disables it entirely.
            if showRareFlash && !reduceMotion {
                Theme.gold.opacity(0.08)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            // Close button — always top-right, 44pt minimum tap target
            if phase != .summary {
                VStack {
                    HStack {
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.white.opacity(0.5))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .padding(.trailing, 12)
                        .padding(.top, 4)
                    }
                    Spacer()
                }
            }

            // "Reveal All" — primary bottom button during reveal phase only.
            // Hidden once all cards are already revealed.
            if phase == .reveal && currentIndex < pulledCards.count - 1 {
                VStack {
                    Spacer()
                    Button { revealAll() } label: {
                        Text("Reveal All")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                Capsule().fill(.white.opacity(0.15))
                            )
                            .overlay(
                                Capsule().stroke(.white.opacity(0.25), lineWidth: 0.5)
                            )
                            .contentShape(Capsule())
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
                }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: hapticLight, condition: { _, _ in appState.hapticsEnabled })
        .sensoryFeedback(.impact(weight: .medium), trigger: hapticMedium, condition: { _, _ in appState.hapticsEnabled })
        .sensoryFeedback(.impact(weight: .heavy), trigger: hapticHeavy, condition: { _, _ in appState.hapticsEnabled })
        .onChange(of: phase) { _, new in
            if new == .reveal {
                applyFoilMotion()
            } else {
                foilMotion.stop()
            }
            // Stage the next pack as soon as the user reaches the summary,
            // so "Open Another" can reuse the prefetched data instead of
            // running pack generation + image download from scratch.
            if new == .summary, appState.canOpenPack {
                PackPrefetcher.shared.prefetch(
                    set: set,
                    cards: cards,
                    modelContext: modelContext,
                    ownedCardIDs: collectionStats.ownedCardIDs(forSet: set.apiID),
                    biasUnownedCards: appState.unownedCardBiasEnabled
                )
            }
        }
        .onChange(of: passiveMotionSource) { _, _ in
            if phase == .reveal { applyFoilMotion() }
        }
        .onDisappear {
            foilMotion.stop()
            // Safety net for the user dismissing without reaching reveal
            // (e.g., tapping the X during ripping). No-op if already saved.
            savePackIfNeeded()
        }
        .adaptiveDetailSheet(item: $selectedCard) { card in
            CardInspectView(card: card)
        }
        .statusBarHidden()
    }

    // MARK: - Phase 1: Sealed Pack

    @State private var packSize: CGSize = .zero

    private var sealedPhase: some View {
        VStack {
            Spacer()

            // Pack with rip-split effect
            ZStack {
                // Overlap: extend each mask 10pt past split line so jagged edges cover the seam
                let overlap: CGFloat = 10
                let topH = packSize.height > 0 ? packSize.height * ripFraction + overlap : 10000
                let bottomH = packSize.height > 0 ? packSize.height * (1 - ripFraction) + overlap : 10000

                // Top half — jagged bottom edge
                FoilPackView(set: set, palette: palette)
                    .mask(alignment: .top) {
                        TornEdge(side: .topHalf, seed: ripSeed)
                            .frame(height: topH)
                    }
                    .offset(y: -packSize.height * ripFraction * ripSplit * 0.8)
                    .rotationEffect(.degrees(-ripSplit * 5), anchor: .bottom)
                    .opacity(1 - ripSplit)

                // Bottom half — jagged top edge (same seed = interlocking)
                FoilPackView(set: set, palette: palette)
                    .mask(alignment: .bottom) {
                        TornEdge(side: .bottomHalf, seed: ripSeed)
                            .frame(height: bottomH)
                    }
                    .offset(y: packSize.height * (1 - ripFraction) * ripSplit * 0.8)
                    .rotationEffect(.degrees(ripSplit * 5), anchor: .top)
                    .opacity(1 - ripSplit)
            }
            .offset(x: dragOffset)
            .rotationEffect(.degrees(dragOffset * 0.03))
            .scaleEffect(packBreathing && ripSplit == 0 ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: packBreathing)
            .background {
                GeometryReader { geo in
                    Color.clear.onAppear { packSize = geo.size }
                }
            }
            .aspectRatio(FoilPackView.aspectRatio, contentMode: .fit)
            .frame(maxWidth: 480)
            .padding(.horizontal, Theme.spacingMD)

            Spacer()

            // Hint text
            if ripSplit > 0 {
                Color.clear.frame(height: 60)
            } else if preloadedPack != nil {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left")
                    Text("Swipe to rip")
                    Image(systemName: "arrow.right")
                }
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .opacity(isDragging ? 0 : 0.6)
                .padding(.bottom, 60)
            } else {
                HStack(spacing: 6) {
                    ProgressView()
                        .tint(Theme.secondaryText)
                        .scaleEffect(0.8)
                    Text("Preparing pack...")
                }
                .font(.subheadline)
                .foregroundStyle(Theme.tertiaryText)
                .padding(.bottom, 60)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    guard preloadedPack != nil, ripSplit == 0 else { return }
                    isDragging = true
                    dragOffset = value.translation.width * 0.5

                    // Screen Y percentage = pack rip percentage
                    let screenHeight = UIScreen.main.bounds.height
                    if screenHeight > 0 {
                        ripFraction = (value.startLocation.y / screenHeight).clamped(to: 0.15...0.85)
                    }
                }
                .onEnded { value in
                    guard preloadedPack != nil, ripSplit == 0 else { return }
                    let threshold: CGFloat = 80
                    if abs(value.translation.width) > threshold || abs(value.predictedEndTranslation.width) > 400 {
                        hapticMedium += 1
                        withAnimation(.easeOut(duration: 0.35)) {
                            ripSplit = 1
                            dragOffset = 0
                        }
                        Task {
                            try? await Task.sleep(for: .milliseconds(400))
                            ripPack()
                        }
                    } else {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                            dragOffset = 0
                            isDragging = false
                        }
                    }
                }
        )
        .onAppear { packBreathing = true }
        .task { await generateAndPreload() }
    }

    // MARK: - Phase 2: Ripping

    @State private var hotPackStage = 0  // 0=dark, 1=flash, 2=text, 3=glow

    @ViewBuilder
    private var rippingPhase: some View {
        if isHotPack {
            // Full screen — no ZStack container that could inherit card sizing
            hotPackReveal
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
        } else {
            // 3D flip container. `flipProgress` 0 → 1 rotates the whole
            // ZStack 180° on the Y axis, swapping visibility between the
            // card back (front face) and slot 0's actual card (back face,
            // pre-rotated 180° so it lands right-side-up). The ripPack Task
            // drives this animation once `firstCardReady` is satisfied —
            // the flip masks the image-load wait so the user never sees a
            // static spinner or an empty card.
            ZStack {
                CardBackView()
                    .opacity(showingCardFront ? 0 : 1)

                if let first = pulledCards.first {
                    cardReveal(first)
                        .rotation3DEffect(
                            .degrees(180),
                            axis: (x: 0, y: 1, z: 0),
                            perspective: 0
                        )
                        .opacity(showingCardFront ? 1 : 0)
                }
            }
            .rotation3DEffect(
                .degrees(Double(flipProgress) * 180),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.5
            )
            // Implicit animation tied specifically to flipProgress changes —
            // more robust on device than wrapping the state mutation in
            // `withAnimation`, which can be cancelled when other state in
            // the view tree updates mid-flight (e.g. CardBackView's 60Hz
            // foilMotion tick or the showingCardFront swap halfway through).
            .animation(.easeInOut(duration: 0.55), value: flipProgress)
            .frame(maxWidth: 380)
            .padding(.horizontal, Theme.spacingMD)
            .padding(.top, 50)
            .padding(.bottom, 40)
            .transition(.identity)
        }
    }

    private var hotPackReveal: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Single fixed gold radial — NEVER changes its stops, only its opacity
            // This prevents SwiftUI from bitmap-compositing gradient transitions
            RadialGradient(
                stops: [
                    .init(color: Theme.gold, location: 0),
                    .init(color: Theme.gold.opacity(0.5), location: 0.15),
                    .init(color: Theme.gold.opacity(0.15), location: 0.35),
                    .init(color: .clear, location: 0.55)
                ],
                center: .center,
                startRadius: 0,
                endRadius: 900
            )
            .ignoresSafeArea()
            .opacity(hotPackStage == 1 ? 0.5 : (hotPackStage >= 2 ? 0.1 : 0))
            .animation(.easeOut(duration: 0.3), value: hotPackStage)

            // Text glow circle
            Circle()
                .fill(Theme.gold)
                .frame(width: 300, height: 300)
                .blur(radius: 80)
                .opacity(hotPackStage >= 2 ? 0.4 : 0)
                .scaleEffect(hotPackStage >= 3 ? 1.3 : 0.8)
                .animation(.easeOut(duration: 0.6), value: hotPackStage)

            // HOT PACK text
            VStack(spacing: 12) {
                HStack(spacing: 20) {
                    Image(systemName: "sparkle").font(.title2)
                    Image(systemName: "sparkle").font(.title3)
                    Image(systemName: "sparkle").font(.title2)
                }
                .foregroundStyle(Theme.gold)
                .opacity(hotPackStage >= 3 ? 1 : 0)

                Text("HOT PACK")
                    .font(.system(size: 42, weight: .black, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Theme.gold, .white, Theme.gold],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                HStack(spacing: 20) {
                    Image(systemName: "sparkle").font(.title3)
                    Image(systemName: "sparkle").font(.title2)
                    Image(systemName: "sparkle").font(.title3)
                }
                .foregroundStyle(Theme.gold)
                .opacity(hotPackStage >= 3 ? 1 : 0)
            }
            .scaleEffect(hotPackStage >= 2 ? (hotPackStage >= 3 ? 1.0 : 0.3) : 0.01)
            .opacity(hotPackStage >= 2 ? 1 : 0)
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: hotPackStage)
        }
        .onAppear { runHotPackSequence() }
    }

    private func runHotPackSequence() {
        // Stage 0: darkness (already showing)
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            hapticHeavy += 1

            // Stage 1: gold flash
            withAnimation(.easeIn(duration: 0.1)) { hotPackStage = 1 }
            try? await Task.sleep(for: .milliseconds(200))
            hapticHeavy += 1

            // Stage 2: text appears, flash dims
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { hotPackStage = 2 }
            try? await Task.sleep(for: .milliseconds(300))
            hapticHeavy += 1

            // Stage 3: glow expands, sparkles appear
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { hotPackStage = 3 }
        }
    }

    // MARK: - Phase 3: Card Reveal

    private var revealPhase: some View {
        ZStack {
            // Cinematic backdrop layers — suppressed under Reduce Motion so
            // the rapid dark↔bright transitions don't strobe.
            if !reduceMotion {
                // Layer 1: dark backdrop (tier 3+)
                if showDarkBackdrop {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                        .transition(.opacity)
                }

                // Layer 2: rainbow gradient backdrop (tier 4)
                if showRainbowBackdrop {
                    rainbowBackdrop
                        .ignoresSafeArea()
                        .transition(.opacity)
                }

                // Layer 3: rotating light rays behind card (tier 3+)
                if showLightRays {
                    LightRays(color: lightRayColor, intensity: 0.55)
                        .frame(width: 700, height: 700)
                        .transition(.opacity)
                }
            }

            // Layer 4: continuous twinkles around card (tier 3+)
            if showContinuousTwinkles {
                ContinuousTwinkles(
                    isActive: showContinuousTwinkles,
                    rate: twinkleRate,
                    colors: twinkleColors,
                    sizeRange: 2...5,
                    lifespanRange: 1.0...2.0
                )
                .padding(.horizontal, 24)
            }

            if currentIndex < pulledCards.count {
                let card = pulledCards[currentIndex]
                cardReveal(card)
                    .id(card.id) // Prevents SwiftUI from cross-fading badge state between cards
                    .scaleEffect(revealScale)
                    .offset(x: cardSwipeOffset)
                    .rotationEffect(.degrees(cardSwipeRotation))
                    .opacity(1.0 - abs(cardSwipeOffset) / 400)
                    .padding(.horizontal, Theme.spacingMD)
                    .padding(.top, 50)
                    .padding(.bottom, 40)
            }

            // Layer 6: particle burst at center.
            // Opacity gate hides in-flight particles when the card swipes off,
            // so we don't render sparkles in empty space.
            ParticleBurst(
                trigger: particleBurstID,
                count: burstCount,
                colors: burstColors,
                speedRange: burstSpeedRange,
                lifespanRange: 0.8...1.6,
                sizeRange: 4...10
            )
            .opacity(particlesVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: particlesVisible)

            // Progress dots
            VStack {
                HStack(spacing: 4) {
                    ForEach(0..<pulledCards.count, id: \.self) { i in
                        Circle()
                            .fill(i < revealedCount ? Theme.accent : Theme.cardSurface)
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(.top, 16)
                Spacer()
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    guard !isCardSwiping else { return }
                    cardSwipeOffset = value.translation.width
                    cardSwipeRotation = Double(value.translation.width) * 0.06
                }
                .onEnded { value in
                    let threshold: CGFloat = 80
                    let velocity = value.predictedEndTranslation.width
                    if abs(value.translation.width) > threshold || abs(velocity) > 500 {
                        let direction: CGFloat = value.translation.width > 0 ? 1 : -1
                        swipeCardAway(direction: direction)
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            cardSwipeOffset = 0
                            cardSwipeRotation = 0
                        }
                    }
                }
        )
        .onTapGesture {
            guard !isCardSwiping else { return }
            swipeCardAway(direction: -1)
        }
    }

    // MARK: - Reveal helpers (per current card tier)

    private var currentTier: Int {
        guard currentIndex < pulledCards.count else { return 0 }
        return pulledCards[currentIndex].model.rarityTier
    }

    private var burstCount: Int {
        switch currentTier {
        case 4...: 26
        case 3: 14
        case 2: 6
        default: 0
        }
    }

    private var burstColors: [Color] {
        switch currentTier {
        case 4...: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .white]
        case 3: [Theme.gold, .yellow, .white, Color(hex: 0xFFE08A)]
        case 2: [.cyan, .white, .purple, .pink]
        default: [.white]
        }
    }

    private var burstSpeedRange: ClosedRange<CGFloat> {
        switch currentTier {
        case 4...: 120...300
        case 3: 100...240
        case 2: 60...160
        default: 60...120
        }
    }

    private var lightRayColor: Color {
        currentTier >= 4 ? .white : Theme.gold
    }

    private var twinkleColors: [Color] {
        switch currentTier {
        case 4...: [.white, .yellow, .cyan, .pink]
        default: [Theme.gold, .white, Color(hex: 0xFFE08A)]
        }
    }

    private var twinkleRate: Double {
        currentTier >= 4 ? 10 : 6
    }

    private var rainbowBackdrop: some View {
        LinearGradient(
            colors: [
                Color(hex: 0x4A0E2C),
                Color(hex: 0x2A0E4A),
                Color(hex: 0x0E2A4A),
                Color(hex: 0x0E4A4A),
                Color(hex: 0x4A2A0E),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .opacity(0.85)
    }

    private func cardReveal(_ card: PulledCard) -> some View {
        let rarityTier = card.model.rarityTier
        let glowColor = rarityTier >= 3
            ? Theme.gold
            : Theme.rarityColor(for: card.model.rarity)
        let glowRadius: CGFloat = rarityTier >= 3
            ? (glowPulse ? 30 : 16)
            : (card.isRare ? 12 : 4)

        return CachedCardImage(urlString: card.model.imageLargeURL)
            .aspectRatio(0.714, contentMode: .fit)
            .clipShape(.rect(cornerRadius: Theme.radiusMD))
            .foilShader(
                treatment: foilTreatment(for: card),
                motion: foilMotion,
                intensity: 1.0
            )
            .overlay {
                // One-shot reveal sweep — between shader and rotation so it
                // rotates with the card. Suppressed under Reduce Motion
                // (rapid swipes were strobing).
                if rarityTier >= 2 && !reduceMotion {
                    ShimmerSweep(trigger: shimmerSweepID, color: .white, duration: 1.0)
                        .clipShape(.rect(cornerRadius: Theme.radiusMD))
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                NewBadge()
                    .opacity(card.isNew ? 1 : 0)
                    .animation(nil, value: card.isNew)
            }
            .foilRotation(motion: foilMotion, degrees: 6)
            .shadow(color: glowColor.opacity(0.6), radius: glowRadius)
            .shadow(color: glowColor.opacity(rarityTier >= 3 ? 0.3 : 0), radius: glowRadius * 2)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: glowPulse)
            .frame(maxWidth: 380)
    }

    /// 0 = Common · 1 = Rare · 2 = Super Rare · 3 = Ultra/Ultimate · 4 = Secret/Ghost/Starlight/QC/Collector's/Prismatic
    // MARK: - Phase 4: Summary

    /// Pack contents sorted for the summary grid — rarest first so the chase
    /// card and any unexpected good pulls land at the top. Original reveal
    /// order is the tiebreaker within the same rarity tier so it stays stable.
    private var summarySortedCards: [PulledCard] {
        pulledCards.sorted { a, b in
            if a.model.rarityTier != b.model.rarityTier {
                return a.model.rarityTier > b.model.rarityTier
            }
            return a.slotIndex < b.slotIndex
        }
    }

    /// Gold-trimmed celebration banner shown above the summary header when
    /// this pack pushed the set to 100% unique-owned. Fires a heavy haptic
    /// on appear. Auto-dismisses with the summary screen — the user clears
    /// it by tapping Back to Set or Open Another.
    private var setCompletionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(Theme.gold)
            VStack(alignment: .leading, spacing: 2) {
                Text("Set Complete!")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.primaryText)
                Text(set.name)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(Theme.gold)
        }
        .padding(.horizontal, Theme.spacingMD)
        .padding(.vertical, Theme.spacingSM)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: Theme.radiusMD))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusMD)
                .stroke(Theme.gold, lineWidth: 1.5)
        )
        .padding(.horizontal, Theme.spacingMD)
        .padding(.top, Theme.spacingMD)
        .transition(.move(edge: .top).combined(with: .opacity))
        .onAppear { hapticHeavy += 1 }
    }

    private var summaryPhase: some View {
        VStack(spacing: Theme.spacingMD) {
            if justCompletedSet {
                setCompletionBanner
            }

            HStack {
                Text(isHotPack ? "HOT PACK!" : "Pack Summary")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(isHotPack ? Theme.gold : Theme.primaryText)
                Spacer()
                // X removed — "Back to Set" button below already provides
                // the dismiss action, and the action is more obvious there.
            }
            .padding(.horizontal, Theme.spacingMD)
            .padding(.top, Theme.spacingLG)

            ScrollView {
                let minColumnWidth: CGFloat = hSizeClass == .regular ? 160 : 100
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: minColumnWidth), spacing: Theme.spacingSM)],
                    spacing: Theme.spacingSM
                ) {
                    ForEach(summarySortedCards) { card in
                        Button { selectedCard = card.model } label: {
                            VStack(spacing: 4) {
                                CachedCardImage(urlString: card.model.imageSmallURL)
                                    .aspectRatio(0.714, contentMode: .fit)
                                    .clipShape(.rect(cornerRadius: Theme.radiusSM))
                                    .shadow(
                                        color: Theme.rarityColor(for: card.model.rarity).opacity(0.4),
                                        radius: card.isRare ? 8 : 2
                                    )
                                    .overlay(alignment: .topTrailing) {
                                        if card.isNew { NewBadge(size: .small) }
                                    }

                                Text(card.model.name)
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

            // Bottom action buttons — same capsule style + size as the
            // "Reveal All" button on the reveal screen for visual consistency.
            // "Back to Set" is the secondary action, "Open Another" keeps
            // the holo gradient as the primary action.
            HStack(spacing: Theme.spacingMD) {
                Button {
                    dismiss()
                } label: {
                    Text("Back to Set")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            Capsule().fill(.white.opacity(0.15))
                        )
                        .overlay(
                            Capsule().stroke(.white.opacity(0.25), lineWidth: 0.5)
                        )
                        .contentShape(Capsule())
                }

                if appState.canOpenPack {
                    Button {
                        openAnother()
                    } label: {
                        Text("Open Another")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(Theme.background)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.holo, in: Capsule())
                            .contentShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Actions

    /// Adopt a prefetched pack (from `PackPrefetcher`) or start one fresh if
    /// none is staged for this set. Either way, when this returns the view
    /// has a pulled list to render and the first card's large image is in
    /// flight.
    private func generateAndPreload() async {
        PackTiming.mark("view: generateAndPreload begin")
        // Idempotent: openAnother() resets state and re-enters sealed phase,
        // which fires both an explicit Task and the sealedPhase `.task`.
        // Without this guard the second call would re-consume the prefetcher
        // (returning nil now) and overwrite the prefetched pack with a fresh
        // random pull — defeating the Open Another prefetch.
        guard !cards.isEmpty, preloadedPack == nil else {
            PackTiming.mark("view: generateAndPreload skipped (already loaded)")
            return
        }

        let prefetched = PackPrefetcher.shared.consume(forSetID: set.apiID)
        PackTiming.mark("view: consume \(prefetched != nil ? "hit" : "miss")")
        let pulled: [PulledCard]
        let firstTask: Task<Void, Never>

        if let prefetched {
            pulled = prefetched.pulled
            isHotPack = prefetched.isHotPack
            firstTask = prefetched.firstCardReady
        } else {
            // No prefetch staged — generate now and start the priority download
            // for slot 0 immediately. The rest fan out behind it (see
            // `PackPrefetcher.startImageFanOut`).
            let (generated, hotPack) = PackPrefetcher.generate(
                set: set,
                cards: cards,
                modelContext: modelContext,
                ownedCardIDs: collectionStats.ownedCardIDs(forSet: set.apiID),
                biasUnownedCards: appState.unownedCardBiasEnabled
            )
            guard !generated.isEmpty else { return }
            pulled = generated
            isHotPack = hotPack
            (firstTask, _) = PackPrefetcher.startImageFanOut(for: generated)
        }

        preloadedPack = pulled
        PackTiming.mark("view: preloadedPack set (\(pulled.count) cards)")

        // Flip the gate once the priority download completes. This lets the
        // reveal phase proceed as soon as the first card image is on screen —
        // no longer waits for all images.
        await firstTask.value
        firstCardReady = true
        PackTiming.mark("view: firstCardReady = true")
    }

    private func ripPack() {
        guard let pulled = preloadedPack, !pulled.isEmpty else { return }
        PackTiming.mark("ripPack: enter (firstCardReady=\(firstCardReady))")

        pulledCards = pulled

        // Instant phase change — no withAnimation. The .sealed phase's
        // implicit opacity transition would otherwise fade the torn pack
        // out over the card back for 300ms, darkening it and preventing it
        // from ever reading at full brightness before the flip starts.
        phase = .ripping
        PackTiming.mark("ripPack: phase = .ripping")

        Task {
            // Save is deferred to AFTER the flip completes. Even though the
            // save is on a bg context, SwiftData's auto-merge back to main
            // can still cost a few ms of bookkeeping at the moment of merge.
            // Saving AFTER reveal mounts lands the cost during user reading
            // time instead of swallowing the flip animation.
            try? await Task.sleep(for: .milliseconds(100))

            // Wait for slot 0's image to be cached before flipping. No
            // ceiling: `firstCardReady` is set by `generateAndPreload` once
            // `firstTask.value` resolves, and that task uses `try?` so even
            // an outright fetch failure completes the task (and flips the
            // gate). URLSession's own timeouts (~60s default) cap the wait
            // in the worst case. While polling, `CardBackView`'s progressive
            // copy at 2s / 6s / 12s reassures the user we're still working
            // on it.
            PackTiming.mark("reveal: wait begin (firstCardReady=\(firstCardReady))")
            while !firstCardReady {
                try? await Task.sleep(for: .milliseconds(50))
            }
            PackTiming.mark("reveal: wait end")

            if isHotPack {
                // Hot Pack sequence runs its own timing via runHotPackSequence
                try? await Task.sleep(for: .milliseconds(2000))
            }

            // Flip the card back over to reveal slot 0. Rotation is declared
            // on the view via `.animation(_:value:)` — we mutate flipProgress
            // directly and SwiftUI handles the interpolation. At the rotation
            // midpoint we snap the face by toggling `showingCardFront` outside
            // any animation context.
            PackTiming.mark("flip: begin (flipProgress -> 1)")
            flipProgress = 1.0
            try? await Task.sleep(for: .milliseconds(275))
            PackTiming.mark("flip: midpoint (showingCardFront = true)")
            showingCardFront = true
            try? await Task.sleep(for: .milliseconds(275))
            PackTiming.mark("flip: end")

            phase = .reveal
            revealedCount = 1
            PackTiming.mark("reveal: phase = .reveal (post-flip)")

            // Save NOW — after reveal mounts. recordPulls updates the in-
            // memory aggregator on main immediately; the bg save Task runs
            // in parallel and SwiftData's auto-merge lands during the user's
            // card-reading time instead of swallowing the flip animation.
            savePackIfNeeded()
        }
    }

    /// Persist this pack's PullRecords and decrement the pack counter.
    /// Idempotent (one-shot via `packSaved`).
    ///
    /// Runs the insert + save on a background `ModelContext` via
    /// `Task.detached`. The actual save is ~30ms, but doing it on main
    /// blocked the reveal transition; doing it off-main lets the foil tick
    /// loop establish smoothly. `collectionStats.recordPulls` runs on main
    /// *first* so observing views (Home / Collection / Stats / SetDetail)
    /// see the new counts immediately — they no longer keep
    /// `@Query<PullRecord>` observers alive, so the bg save's auto-merge
    /// notification doesn't fire a re-render cascade.
    private func savePackIfNeeded() {
        guard !packSaved, let pulled = preloadedPack, !pulled.isEmpty else { return }
        packSaved = true

        appState.recordPackOpened()

        let setID = set.apiID
        let container = modelContext.container
        let sessionID = UUID()
        let snapshots: [PullSnapshot] = pulled.enumerated().map { (idx, card) in
            PullSnapshot(
                cardAPIID: card.model.apiID,
                rarity: card.model.rarity,
                isNew: card.isNew,
                slotIndex: idx
            )
        }

        // Update in-memory aggregator synchronously on main, before the bg
        // save kicks off. Views observe CollectionStats, not @Query<PullRecord>.
        //
        // Around the update, sample the per-set owned count before/after so
        // we can fire the "Set Complete!" banner on the summary screen. Use
        // `cards.count` as the denominator (the actual bundled pool for this
        // set) rather than `set.totalCards`, which can lag reality.
        let totalInSet = cards.count
        let ownedBefore = collectionStats.ownedCardIDs(forSet: setID).count
        collectionStats.recordPulls(snapshots, setID: setID)
        let ownedAfter = collectionStats.ownedCardIDs(forSet: setID).count
        if totalInSet > 0 && ownedBefore < totalInSet && ownedAfter >= totalInSet {
            justCompletedSet = true
        }

        Task.detached(priority: .utility) {
            let bgContext = ModelContext(container)
            for s in snapshots {
                let record = PullRecord(
                    cardAPIID: s.cardAPIID,
                    setID: setID,
                    rarity: s.rarity,
                    packSessionID: sessionID,
                    isNew: s.isNew,
                    slotIndex: s.slotIndex
                )
                bgContext.insert(record)
            }
            try? bgContext.save()
        }
    }

    /// Skip remaining card-by-card reveals and jump straight to the summary.
    /// Pull records were saved when the pack was first ripped (in `ripPack`),
    /// so no data is lost — this just shortcuts past the per-card animations.
    private func revealAll() {
        guard phase == .reveal, !isCardSwiping else { return }
        withAnimation(.easeOut(duration: 0.3)) {
            // Mark every card as revealed
            currentIndex = pulledCards.count
            revealedCount = pulledCards.count
            // Reset any in-flight reveal effects so the summary doesn't
            // open with leftover backdrops / glows / particles
            showDarkBackdrop = false
            showRainbowBackdrop = false
            showLightRays = false
            showContinuousTwinkles = false
            glowPulse = false
            cardSwipeOffset = 0
            cardSwipeRotation = 0
            revealScale = 1.0
            particlesVisible = true
            isCardSwiping = false
            phase = .summary
        }
    }

    private func swipeCardAway(direction: CGFloat) {
        guard !isCardSwiping else { return }
        isCardSwiping = true

        // Determine next card's rarity tier
        let nextIndex = currentIndex + 1
        let nextTier: Int
        if nextIndex < pulledCards.count {
            nextTier = pulledCards[nextIndex].model.rarityTier
        } else {
            nextTier = 0
        }

        // Initial swipe haptic — light tap for the gesture itself
        hapticLight += 1

        // Animate current card off screen AND fade residual effects with it,
        // so the "sausage being made" (rays, twinkles, backdrop) isn't visible
        // on its own once the card is gone.
        withAnimation(.easeIn(duration: 0.25)) {
            cardSwipeOffset = direction * 500
            cardSwipeRotation = Double(direction) * 15
            showDarkBackdrop = false
            showRainbowBackdrop = false
            showLightRays = false
            showContinuousTwinkles = false
            glowPulse = false
        }
        // Hide any in-flight particles immediately (animated via the .opacity
        // modifier on ParticleBurst).
        particlesVisible = false

        Task {
            try? await Task.sleep(for: .milliseconds(250))

            revealScale = 1.0
            // Re-enable particle visibility before the next burst can fire.
            particlesVisible = true

            let nextIndex = currentIndex + 1

            if nextIndex >= pulledCards.count {
                withAnimation(.easeOut(duration: 0.3)) {
                    currentIndex = nextIndex
                    revealedCount = pulledCards.count
                    cardSwipeOffset = 0
                    cardSwipeRotation = 0
                    isCardSwiping = false
                    phase = .summary
                }
                return
            }

            if nextTier >= 4 && !reduceMotion {
                // === CINEMATIC REVEAL for Secret / Ghost / Starlight / QC / Collector's / Prismatic ===
                revealScale = 0
                cardSwipeOffset = 0
                cardSwipeRotation = 0
                currentIndex = nextIndex

                // 1. Screen darkens + rainbow backdrop fades in
                withAnimation(.easeIn(duration: 0.4)) {
                    showDarkBackdrop = true
                    showRainbowBackdrop = true
                }
                try? await Task.sleep(for: .milliseconds(500))

                // 2. Layered flash
                withAnimation(.easeIn(duration: 0.1)) { showRareFlash = true }
                hapticHeavy += 1
                try? await Task.sleep(for: .milliseconds(80))
                hapticHeavy += 1
                try? await Task.sleep(for: .milliseconds(100))
                withAnimation(.easeOut(duration: 0.35)) { showRareFlash = false }

                // 3. Light rays + particle burst
                withAnimation(.easeIn(duration: 0.3)) { showLightRays = true }
                particleBurstID += 1

                // 4. Slow scale-up for anticipation
                withAnimation(.spring(response: 0.7, dampingFraction: 0.55)) {
                    revealedCount = nextIndex + 1
                    revealScale = 1.0
                }
                shimmerSweepID += 1
                hapticHeavy += 1
                try? await Task.sleep(for: .milliseconds(100))
                hapticHeavy += 1

                // 5. Settle — twinkles, continuous shimmer, glow pulse
                try? await Task.sleep(for: .milliseconds(300))
                showContinuousTwinkles = true
                glowPulse = true

                isCardSwiping = false

            } else if nextTier == 3 && !reduceMotion {
                // === DRAMATIC REVEAL for ultra rare ===
                revealScale = 0
                cardSwipeOffset = 0
                cardSwipeRotation = 0
                currentIndex = nextIndex

                // 1. Screen darkens
                withAnimation(.easeIn(duration: 0.3)) {
                    showDarkBackdrop = true
                }
                try? await Task.sleep(for: .milliseconds(400))

                // 2. Gold flash + first heavy haptic
                withAnimation(.easeIn(duration: 0.1)) { showRareFlash = true }
                hapticHeavy += 1
                try? await Task.sleep(for: .milliseconds(150))
                withAnimation(.easeOut(duration: 0.3)) { showRareFlash = false }

                // 3. Light rays appear
                withAnimation(.easeIn(duration: 0.3)) { showLightRays = true }

                // 4. Card springs into view + particle burst + shimmer sweep
                withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                    revealedCount = nextIndex + 1
                    revealScale = 1.0
                }
                particleBurstID += 1
                shimmerSweepID += 1
                hapticMedium += 1
                try? await Task.sleep(for: .milliseconds(100))
                hapticHeavy += 1

                // 5. Continuous twinkles + glow pulse
                try? await Task.sleep(for: .milliseconds(200))
                showContinuousTwinkles = true
                glowPulse = true

                isCardSwiping = false

            } else if nextTier >= 2 {
                // === Reveal for rare/holo: shimmer sweep + small sparkle burst.
                // Tier 3+ falls through here under Reduce Motion (cinematic
                // delays were leaving 700ms of invisible pauses). ===
                cardSwipeOffset = 0
                cardSwipeRotation = 0
                revealScale = 0.9
                currentIndex = nextIndex
                revealedCount = nextIndex + 1
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    revealScale = 1.0
                }
                particleBurstID += 1
                shimmerSweepID += 1
                hapticMedium += 1
                Task {
                    try? await Task.sleep(for: .milliseconds(120))
                    hapticMedium += 1
                }
                isCardSwiping = false

            } else {
                // === Normal reveal for commons/uncommons ===
                cardSwipeOffset = 0
                cardSwipeRotation = 0
                currentIndex = nextIndex
                revealedCount = nextIndex + 1
                isCardSwiping = false
            }
        }
    }

    private func openAnother() {
        pulledCards = []
        preloadedPack = nil
        firstCardReady = false
        packSaved = false
        justCompletedSet = false
        flipProgress = 0
        showingCardFront = false
        isHotPack = false
        hotPackStage = 0
        currentIndex = 0
        revealedCount = 0
        dragOffset = 0
        ripSplit = 0
        ripFraction = 0.5
        ripSeed = Int.random(in: 0...10000)
        isDragging = false
        packBreathing = false
        cardSwipeOffset = 0
        cardSwipeRotation = 0
        isCardSwiping = false
        showDarkBackdrop = false
        showRareFlash = false
        showRainbowBackdrop = false
        showLightRays = false
        showContinuousTwinkles = false
        glowPulse = false
        revealScale = 1.0
        phase = .sealed
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            packBreathing = true
            await generateAndPreload()
        }
    }
}

// MARK: - Sendable snapshot for background save

/// Plain-value snapshot of a single pull, safe to send across actor
/// boundaries. We snapshot on the main actor (where pulled CardModels live)
/// and ship the array to a Task.detached that writes to a background
/// ModelContext — none of the SwiftData models themselves cross the
/// boundary.
struct PullSnapshot: Sendable {
    let cardAPIID: String
    let rarity: String
    let isNew: Bool
    let slotIndex: Int
}

// MARK: - Pulled Card Model

struct PulledCard: Identifiable {
    let id: UUID
    let model: CardModel
    let slotIndex: Int
    let isNew: Bool

    var isRare: Bool { model.isRare }
}
