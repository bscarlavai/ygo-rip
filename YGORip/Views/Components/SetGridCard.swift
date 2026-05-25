import SwiftUI

struct SetGridCard: View {
    let set: SetModel
    var ownedCount: Int = 0

    private var isComplete: Bool {
        let total = set.totalCards
        return total > 0 && ownedCount >= total
    }

    var body: some View {
        VStack(spacing: Theme.spacingSM) {
            SetSymbolView(set: set, size: 130, color: Theme.accent)
                .frame(height: 60)

            Text(set.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.center)

            if isComplete {
                Text("COMPLETE")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(Theme.gold)
            } else {
                Text("\(ownedCount)/\(set.totalCards)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(ownedCount > 0 ? Theme.secondaryText : Theme.tertiaryText)
            }
        }
        .padding(Theme.spacingMD)
        .frame(maxWidth: .infinity)
        .background(Theme.cardSurface, in: .rect(cornerRadius: Theme.radiusMD))
        .overlay {
            if isComplete {
                RoundedRectangle(cornerRadius: Theme.radiusMD)
                    .strokeBorder(
                        LinearGradient(
                            colors: Theme.holoColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 3
                    )
            }
        }
        .contentShape(Rectangle())
    }
}
