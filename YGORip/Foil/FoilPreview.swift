#if DEBUG
import SwiftUI
import SwiftData

/// Debug sandbox: shows one card with all five foil treatments applied so
/// you can compare them side-by-side. Picks the highest-rarity card the
/// user owns by default; the picker lets you swap to any other card.
struct FoilPreview: View {
    @Query private var cards: [CardModel]

    @State private var motion = FoilMotionProvider()
    @State private var manualTilt: CGSize = .zero
    @State private var intensity: Double = 1.0
    @State private var useAutoMotion = true
    @State private var sampleCardIndex = 0
    @State private var zoomedTreatment: FoilTreatment?

    private let treatments: [FoilTreatment] = FoilTreatment.allCases

    /// Top 12 cards by rarityTier so the picker leads with the most
    /// visually interesting cards in the user's collection.
    private var rankedCards: [CardModel] {
        cards
            .filter { !$0.imageLargeURL.isEmpty }
            .sorted { $0.rarityTier > $1.rarityTier }
            .prefix(12)
            .map { $0 }
    }

    private var currentCard: CardModel? {
        guard !rankedCards.isEmpty else { return nil }
        return rankedCards[sampleCardIndex % rankedCards.count]
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 160), spacing: Theme.spacingMD)],
                    spacing: Theme.spacingLG
                ) {
                    ForEach(treatments) { treatment in
                        tile(for: treatment)
                    }
                }
                .padding(Theme.spacingMD)
            }

            controls
        }
        .background(Theme.background)
        .navigationTitle("Foil Sandbox")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear { motion.start(source: useAutoMotion ? .auto : .drag) }
        .onDisappear { motion.stop() }
        .onChange(of: zoomedTreatment) { _, new in
            if new != nil {
                motion.start(source: .drag)
                motion.setDragTilt(.zero)
            } else if useAutoMotion {
                motion.start(source: .auto)
            }
        }
        .fullScreenCover(item: $zoomedTreatment) { treatment in
            ZoomedFoilView(
                card: currentCard,
                treatment: treatment,
                motion: motion,
                intensity: Float(intensity),
                onDismiss: { zoomedTreatment = nil }
            )
        }
    }

    @ViewBuilder
    private func tile(for treatment: FoilTreatment) -> some View {
        VStack(spacing: Theme.spacingXS) {
            cardArt
                .frame(width: 150, height: 210)
                .foilEffect(
                    treatment: treatment,
                    motion: motion,
                    intensity: Float(intensity)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    if currentCard != nil { zoomedTreatment = treatment }
                }
                .opacity(currentCard == nil ? 0.6 : 1)

            VStack(spacing: 2) {
                Text(treatment.rawValue.uppercased())
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.primaryText)
                Text(treatment.sandboxHint)
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: 170)
        }
    }

    @ViewBuilder
    private var cardArt: some View {
        if let card = currentCard {
            CachedCardImage(urlString: card.imageLargeURL, showSkeleton: true)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMD))
        } else {
            RoundedRectangle(cornerRadius: Theme.radiusMD)
                .fill(Theme.cardSurface)
                .overlay(
                    VStack(spacing: 6) {
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 26))
                            .foregroundStyle(Theme.tertiaryText)
                        Text("Pull a card to preview")
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .padding(8)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusMD)
                        .strokeBorder(Theme.tertiaryText.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
        }
    }

    private var controls: some View {
        VStack(spacing: Theme.spacingSM) {
            if !rankedCards.isEmpty {
                HStack {
                    Text("Card").frame(width: 60, alignment: .leading)
                    Picker("Card", selection: $sampleCardIndex) {
                        ForEach(rankedCards.indices, id: \.self) { i in
                            Text("\(rankedCards[i].name) · \(rankedCards[i].rarity)")
                                .tag(i)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.accent)
                    Spacer()
                }
            }

            Toggle("Auto Motion", isOn: $useAutoMotion)
                .onChange(of: useAutoMotion) { _, on in
                    motion.start(source: on ? .auto : .drag)
                    if !on { motion.setDragTilt(manualTilt) }
                }
                .tint(Theme.accent)

            HStack {
                Text("X").frame(width: 60, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { manualTilt.width },
                        set: {
                            manualTilt.width = $0
                            motion.setDragTilt(manualTilt)
                        }
                    ),
                    in: -1...1
                )
            }
            .disabled(useAutoMotion)
            .opacity(useAutoMotion ? 0.5 : 1)

            HStack {
                Text("Y").frame(width: 60, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { manualTilt.height },
                        set: {
                            manualTilt.height = $0
                            motion.setDragTilt(manualTilt)
                        }
                    ),
                    in: -1...1
                )
            }
            .disabled(useAutoMotion)
            .opacity(useAutoMotion ? 0.5 : 1)

            HStack {
                Text("Intensity").frame(width: 60, alignment: .leading)
                DeferredSlider(
                    value: $intensity,
                    range: 0...1.5,
                    onEditing: { editing in
                        if editing {
                            motion.stop()
                        } else if useAutoMotion {
                            motion.start(source: .auto)
                        }
                    }
                )
            }
        }
        .font(.caption)
        .foregroundStyle(Theme.primaryText)
        .padding(Theme.spacingMD)
        .background(.regularMaterial)
    }
}

private struct ZoomedFoilView: View {
    let card: CardModel?
    let treatment: FoilTreatment
    let motion: FoilMotionProvider
    let intensity: Float
    let onDismiss: () -> Void

    @State private var cardSize: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(spacing: Theme.spacingLG) {
                VStack(spacing: 2) {
                    Text(treatment.rawValue.uppercased())
                        .font(.headline.monospaced())
                        .foregroundStyle(.white.opacity(0.8))
                    if let card {
                        Text("\(card.name) · \(card.rarity)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }

                cardArt
                    .frame(width: 300, height: 420)
                    .background {
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { cardSize = geo.size }
                                .onChange(of: geo.size) { _, new in cardSize = new }
                        }
                    }
                    .foilEffect(
                        treatment: treatment,
                        motion: motion,
                        intensity: intensity,
                        rotationDegrees: 20
                    )
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard cardSize.width > 0, cardSize.height > 0 else { return }
                                let nx = (value.location.x - cardSize.width / 2) / (cardSize.width / 2)
                                let ny = (value.location.y - cardSize.height / 2) / (cardSize.height / 2)
                                let cx = max(-1, min(1, -nx))
                                let cy = max(-1, min(1, -ny))
                                motion.setDragTilt(CGSize(width: cx, height: cy))
                            }
                            .onEnded { _ in
                                motion.setDragTilt(.zero)
                            }
                    )

                Text("Tap/hold the card to tilt · Tap outside to dismiss")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding()

            VStack {
                HStack {
                    Spacer()
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.85))
                            .padding()
                    }
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var cardArt: some View {
        if let card {
            CachedCardImage(urlString: card.imageLargeURL, showSkeleton: true)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLG))
        } else {
            RoundedRectangle(cornerRadius: Theme.radiusLG)
                .fill(Theme.cardSurface)
                .overlay(
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 60))
                        .foregroundStyle(Theme.tertiaryText)
                )
        }
    }
}

private struct DeferredSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onEditing: (Bool) -> Void = { _ in }

    @State private var sliding: Double

    init(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        onEditing: @escaping (Bool) -> Void = { _ in }
    ) {
        _value = value
        self.range = range
        _sliding = State(initialValue: value.wrappedValue)
        self.onEditing = onEditing
    }

    var body: some View {
        Slider(
            value: $sliding,
            in: range,
            onEditingChanged: { editing in
                onEditing(editing)
                if !editing {
                    value = sliding
                }
            }
        )
    }
}

#Preview {
    NavigationStack { FoilPreview() }
}
#endif
