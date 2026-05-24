import SwiftUI

struct DisclaimerView: View {
    @Binding var isPresented: Bool
    var onAccept: () -> Void

    var body: some View {
        VStack(spacing: Theme.spacingLG) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.accent)

            Text("Disclaimer")
                .font(.title.weight(.bold))
                .foregroundStyle(Theme.primaryText)

            Text("""
            This app is not produced, endorsed, supported by, \
            or affiliated with Konami Digital Entertainment, \
            Konami Group Corporation, Studio Dice, Shueisha, TV Tokyo, \
            or any of their subsidiaries.

            Yu-Gi-Oh! and all related trademarks are property of \
            their respective owners. Card images and metadata are \
            sourced from YGOPRODeck and YGOJSON — community APIs \
            providing publicly available information about published \
            trading cards.

            This is an independent fan project created for \
            entertainment and educational purposes only. \
            No real cards are distributed or sold. Pull rates \
            are simulated and do not represent actual product odds. \
            No copyright infringement is intended.
            """)
            .font(.subheadline)
            .foregroundStyle(Theme.secondaryText)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.spacingLG)

            Spacer()

            Button {
                onAccept()
                isPresented = false
            } label: {
                Text("I Understand")
                    .font(.headline)
                    .foregroundStyle(Theme.background)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accent, in: .rect(cornerRadius: Theme.radiusMD))
            }
            .padding(.horizontal, Theme.spacingLG)
            .padding(.bottom, Theme.spacingXL)
        }
        .background(Theme.background)
    }
}
