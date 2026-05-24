import SwiftUI

/// "NEW" badge overlay for first-pull cards.
struct NewBadge: View {
    enum Size { case small, large }
    var size: Size = .large

    var body: some View {
        Text("NEW")
            .font(size == .small
                ? .system(size: 8, weight: .bold)
                : .caption2.weight(.bold)
            )
            .foregroundStyle(Theme.background)
            .padding(.horizontal, size == .small ? 4 : 8)
            .padding(.vertical, size == .small ? 2 : 4)
            .background(Theme.gold, in: Capsule())
            .padding(size == .small ? 4 : 8)
    }
}
