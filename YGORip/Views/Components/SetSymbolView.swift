import SwiftUI

/// Renders the Yu-Gi-Oh! franchise logo as a set's visual identity.
///
/// Earlier iterations tried per-set logos (Yugipedia's `<CODE>-LogoEN.png` /
/// `<CODE>-BoosterEN.png`) and per-era anime logos. Both looked off — per-set
/// pack-art photos as "logos" felt like "a pack inside a pack", and per-era
/// logos meant every booster in the same era looked identical. The cleanest
/// answer: ship the YGO franchise logo everywhere, then let `PackPalette`
/// vary the surrounding foil-pack gradient per-set so each pack feels distinct.
struct SetSymbolView: View {
    let set: SetModel
    /// Target *width* for the logo. Height is derived from the image's
    /// natural aspect ratio (≈2.8:1), so the logo doesn't get squashed into
    /// a square frame.
    var size: CGFloat = 32
    var color: Color? = nil

    var body: some View {
        Group {
            if let image = Self.ygoLogo {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size)
            } else {
                Image(systemName: "rectangle.stack.fill")
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(color ?? Theme.secondaryText)
                    .padding(size * 0.15)
                    .frame(width: size, height: size)
            }
        }
    }

    /// Cached logo. Loaded once on first access; sticks around for the
    /// app's lifetime since every set tile renders it.
    private static let ygoLogo: UIImage? = {
        guard let url = Bundle.main.url(forResource: "ygo_logo", withExtension: "png"),
              let img = UIImage(contentsOfFile: url.path)
        else { return nil }
        return img
    }()
}
