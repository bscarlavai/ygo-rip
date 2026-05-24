import SwiftUI

extension View {
    /// Presents a sheet on compact (iPhone) and a full-screen cover on regular (iPad).
    /// iPad's default `.sheet` form-sheet crops card art and wastes space — full screen lets the card breathe.
    func adaptiveDetailSheet<Item: Identifiable, Detail: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Detail
    ) -> some View {
        modifier(AdaptiveDetailSheet(item: item, detail: content))
    }
}

private struct AdaptiveDetailSheet<Item: Identifiable, Detail: View>: ViewModifier {
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Binding var item: Item?
    let detail: (Item) -> Detail

    func body(content: Content) -> some View {
        if hSizeClass == .regular {
            content.fullScreenCover(item: $item) { detail($0) }
        } else {
            content.sheet(item: $item) { detail($0) }
        }
    }
}
