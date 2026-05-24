import SwiftUI

/// Skeleton placeholder grid that shimmers while cards are loading.
struct ShimmerCardGrid: View {
    let cardCount: Int

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var shimmerPhase: CGFloat = -1

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            // Fake section header skeleton
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.cardSurface)
                .frame(width: 120, height: 14)
                .shimmer(phase: shimmerPhase)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: hSizeClass == .regular ? 130 : 80), spacing: Theme.spacingSM)],
                spacing: Theme.spacingSM
            ) {
                ForEach(0..<cardCount, id: \.self) { index in
                    skeletonCard
                        .shimmer(phase: shimmerPhase)
                        // Stagger the appearance
                        .opacity(appearOpacity(for: index))
                }
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                shimmerPhase = 1
            }
        }
    }

    private var skeletonCard: some View {
        RoundedRectangle(cornerRadius: Theme.radiusSM)
            .fill(Theme.cardSurface)
            .aspectRatio(0.714, contentMode: .fit)
    }

    private func appearOpacity(for index: Int) -> Double {
        // First few rows fully visible, fade out toward bottom
        let row = index / 4
        if row < 3 { return 1.0 }
        if row < 5 { return 0.6 }
        return 0.3
    }
}

// MARK: - Shimmer Effect

struct ShimmerModifier: ViewModifier {
    let phase: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                LinearGradient(
                    colors: [
                        .clear,
                        .white.opacity(0.08),
                        .white.opacity(0.12),
                        .white.opacity(0.08),
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .offset(x: phase * 300)
            }
            .clipped()
    }
}

extension View {
    func shimmer(phase: CGFloat) -> some View {
        modifier(ShimmerModifier(phase: phase))
    }
}
