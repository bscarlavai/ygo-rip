import SwiftUI

/// Reusable card container styling — dark surface background with rounded corners.
extension View {
    func cardContainer(opacity: Double = 1.0) -> some View {
        self
            .padding(Theme.spacingMD)
            .background(Theme.cardSurface.opacity(opacity), in: .rect(cornerRadius: Theme.radiusMD))
    }
}
