import SwiftUI

struct OnboardingView: View {
    @Binding var isPresented: Bool
    var onComplete: () -> Void

    @State private var currentPage = 0

    private let pages: [(icon: String, title: String, subtitle: String)] = [
        (
            "shippingbox.fill",
            "Rip Packs",
            "Swipe to tear open booster packs from every era of the trading card game."
        ),
        (
            "sparkles",
            "Chase Secret Rares",
            "Every pack is a chance at Ultra Rares, Secret Rares, and chase cards from every era — going back to Legend of Blue Eyes."
        ),
        (
            "book.closed.fill",
            "Build Your Collection",
            "Track every card you pull. Browse in grid, list, or binder view."
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $currentPage) {
                ForEach(pages.indices, id: \.self) { index in
                    page(pages[index])
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            // Bottom button
            Button {
                if currentPage < pages.count - 1 {
                    withAnimation { currentPage += 1 }
                } else {
                    onComplete()
                    isPresented = false
                }
            } label: {
                Text(currentPage < pages.count - 1 ? "Next" : "Let's Rip")
                    .font(.headline)
                    .foregroundStyle(Theme.background)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.holo, in: .rect(cornerRadius: Theme.radiusMD))
            }
            .padding(.horizontal, Theme.spacingLG)
            .padding(.bottom, Theme.spacingXL)

            if currentPage < pages.count - 1 {
                Button("Skip") {
                    onComplete()
                    isPresented = false
                }
                .font(.subheadline)
                .foregroundStyle(Theme.tertiaryText)
                .padding(.bottom, Theme.spacingLG)
            } else {
                Spacer().frame(height: 50)
            }
        }
        .background(Theme.background)
    }

    private func page(_ data: (icon: String, title: String, subtitle: String)) -> some View {
        VStack(spacing: Theme.spacingLG) {
            Spacer()

            Image(systemName: data.icon)
                .font(.system(size: 64))
                .foregroundStyle(Theme.holo)

            Text(data.title)
                .font(.title.weight(.bold))
                .foregroundStyle(Theme.primaryText)

            Text(data.subtitle)
                .font(.body)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.spacingXL)

            Spacer()
            Spacer()
        }
    }
}
