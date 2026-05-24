import SwiftUI

/// Card-aspect placeholder shown during the ripping phase. Renders the
/// `CardBack` image asset at the same size as the card about to be revealed,
/// with idle motion matching the reveal-phase cards.
struct CardBackView: View {
    @State private var pulseScale: CGFloat = 1.0
    @State private var bobble: CGFloat = 0
    /// Progressive loading copy that fades in beneath the card. Nil until
    /// the 2s mark; then escalates through three reassurance tiers as the
    /// wait stretches out so the user knows we're still working on it and
    /// haven't simply hung.
    @State private var loadingMessage: String?
    /// Drives `foilRotation`'s tilt input. Auto source idles a figure-8
    /// sweep — same idle motion the cards use in the reveal phase.
    @State private var foilMotion = FoilMotionProvider()

    /// Clip radius for the displayed image, in display points. Matches the
    /// painted card's outer corner radius so the clip is concentric with the
    /// foil rim — too small and white shows, too large and the rim gets eaten.
    private let clipRadius: CGFloat = 26

    var body: some View {
        Image("CardBack")
            .renderingMode(.original)  // no tint, no color profile fudging
            .resizable()
            .aspectRatio(0.714, contentMode: .fit)
            .clipShape(.rect(cornerRadius: clipRadius, style: .continuous))
            .scaleEffect(pulseScale)
            .foilRotation(motion: foilMotion, degrees: 14)
            .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
            .offset(y: bobble)
            // Loading hint anchored below the card — doesn't affect layout.
            .overlay(alignment: .bottom) {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(.white.opacity(0.7))
                        .scaleEffect(0.75)
                    Text(loadingMessage ?? "")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .contentTransition(.opacity)
                }
                .opacity(loadingMessage != nil ? 1 : 0)
                .animation(.easeInOut(duration: 0.4), value: loadingMessage)
                .offset(y: 44)
            }
            .onAppear {
                foilMotion.start(source: .auto)
                // CA-backed implicit animations — these keep moving even when
                // the main actor is briefly blocked.
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    pulseScale = 1.07
                }
                withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                    bobble = -12
                }
            }
            .onDisappear { foilMotion.stop() }
            .task {
                try? await Task.sleep(for: .seconds(2))
                loadingMessage = "Loading…"
                try? await Task.sleep(for: .seconds(4))   // 6s mark
                loadingMessage = "Still working on it…"
                try? await Task.sleep(for: .seconds(6))   // 12s mark
                loadingMessage = "Slow connection — hang tight"
            }
    }
}

#if DEBUG
#Preview {
    ZStack {
        Theme.background.ignoresSafeArea()
        CardBackView()
            .frame(maxWidth: 380)
            .padding()
    }
}
#endif
