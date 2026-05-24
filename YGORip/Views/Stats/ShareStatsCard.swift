import SwiftUI

/// Self-contained stats card for ImageRenderer — no @Environment, no @Query.
/// Designed to look good when shared on social media.
struct ShareStatsCard: View {
    let totalPulls: Int
    let uniqueCards: Int
    let packsOpened: Int
    let collectionValue: Double
    let bestPullName: String?
    let bestPullRarity: String?
    let bestPullValue: Double?

    private let holoColors: [Color] = [
        Color(hex: 0xA8D8EA),
        Color(hex: 0xC4B7D5),
        Color(hex: 0xE8C4D8),
        Color(hex: 0xC4D5B7),
        Color(hex: 0xA8D8EA),
    ]

    private let gold = Color(hex: 0xFFD700)
    private let bg = Color(hex: 0x0F1923)
    private let surface = Color(hex: 0x1A2634)

    var body: some View {
        VStack(spacing: 0) {
            // Header with holo border
            VStack(spacing: 8) {
                Text("YGORip")
                    .font(.system(size: 36, weight: .black, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(colors: holoColors, startPoint: .leading, endPoint: .trailing)
                    )

                Text("COLLECTION STATS")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.top, 32)
            .padding(.bottom, 24)

            // Stats row
            HStack(spacing: 0) {
                statItem("PULLS", value: "\(totalPulls)", icon: "rectangle.stack.fill")
                divider
                statItem("UNIQUE", value: "\(uniqueCards)", icon: "sparkles")
                divider
                statItem("PACKS", value: "\(packsOpened)", icon: "shippingbox.fill")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(surface)

            // Collection value
            VStack(spacing: 6) {
                Text("COLLECTION VALUE")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.4))

                Text(String(format: "$%.2f", collectionValue))
                    .font(.system(size: 36, weight: .bold).monospacedDigit())
                    .foregroundStyle(
                        LinearGradient(colors: holoColors, startPoint: .leading, endPoint: .trailing)
                    )
            }
            .padding(.vertical, 20)

            // Best pull
            if let name = bestPullName {
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 12))
                        Text("BEST PULL")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(2)
                    }
                    .foregroundStyle(gold)

                    Text(name)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)

                    HStack(spacing: 12) {
                        if let rarity = bestPullRarity {
                            Text(rarity)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        if let value = bestPullValue {
                            Text(String(format: "$%.2f", value))
                                .font(.system(size: 14, weight: .bold).monospacedDigit())
                                .foregroundStyle(gold)
                        }
                    }
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
                .background(surface, in: .rect(cornerRadius: 12))
                .padding(.horizontal, 20)
            }

            Spacer().frame(height: 24)

            // Footer
            HStack(spacing: 6) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 10))
                Text("YGORip")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.25))
            .padding(.bottom, 20)
        }
        .frame(width: 400)
        .background(bg)
        .clipShape(.rect(cornerRadius: 20))
        .overlay {
            // Holo border
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(
                    LinearGradient(colors: holoColors, startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 2
                )
                .opacity(0.6)
        }
    }

    private func statItem(_ title: String, value: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.4))
            Text(value)
                .font(.system(size: 22, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1)
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.1))
            .frame(width: 1, height: 40)
    }
}
