import SwiftUI

/// Renders a set logo. YGO has no equivalent of MTG's Keyrune icon font —
/// sets use full pack-art logos, not corner glyphs. We try a bundled PNG
/// (mirrored from Yugipedia by `data-pipeline/build_bundle.py` at build
/// time), falling back to an SF Symbol when no logo is shipped.
struct SetSymbolView: View {
    let setCode: String
    var size: CGFloat = 32
    var color: Color? = nil

    var body: some View {
        Group {
            if let image = Self.logoImage(for: setCode) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "rectangle.stack.fill")
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(color ?? Theme.secondaryText)
                    .padding(size * 0.15)
            }
        }
        .frame(width: size * 1.2, height: size * 1.2)
    }

    /// Process-wide cache. NSCache evicts under memory pressure, so we don't
    /// risk holding 600+ PNGs in RAM forever — but for a Home grid scroll
    /// we want to avoid hitting the filesystem on every tile re-render.
    private static let cache = NSCache<NSString, UIImage>()

    /// Resolve a set-code → PNG. Tries asset catalog first (in case logos get
    /// migrated to Assets.xcassets later), then the bundle's `set-logos`
    /// folder reference produced by the pipeline.
    static func logoImage(for setCode: String) -> UIImage? {
        let key = setCode as NSString
        if let cached = cache.object(forKey: key) { return cached }

        if let img = UIImage(named: "set-logos/\(setCode)") ?? UIImage(named: setCode) {
            cache.setObject(img, forKey: key)
            return img
        }
        // Bundled/ folder reference — Xcode preserves the directory tree.
        if let url = Bundle.main.url(forResource: setCode, withExtension: "png", subdirectory: "set-logos")
            ?? Bundle.main.url(forResource: setCode, withExtension: "png"),
           let img = UIImage(contentsOfFile: url.path)
        {
            cache.setObject(img, forKey: key)
            return img
        }
        return nil
    }
}
