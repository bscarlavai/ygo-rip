import SwiftUI

/// Tiled foil pattern on the pack body. mtg-rip used the set's Keyrune glyph
/// here — YGO has no glyph font so we tile a generic rune (a small diamond)
/// in the pack accent color. The set's actual identity comes from the
/// embossed pack-logo PNG in the center, not the tiled micro-pattern.
///
/// Apply with `.blendMode(.screen)` (or `.plusLighter`) + low opacity to
/// lift the pattern out of the dark base color.
struct SetSymbolPattern: View {
    let setCode: String
    var color: Color = .white
    var glyphSize: CGFloat = 14
    var spacing: CGFloat = 24

    var body: some View {
        Canvas { ctx, size in
            let resolved = ctx.resolve(
                Text("◆")
                    .font(.system(size: glyphSize, weight: .semibold))
                    .foregroundStyle(color)
            )
            let cols = Int(size.width / spacing) + 2
            let rows = Int(size.height / spacing) + 2
            for col in 0...cols {
                for row in 0...rows {
                    let stagger = col.isMultiple(of: 2) ? spacing / 2 : 0
                    let x = CGFloat(col) * spacing
                    let y = CGFloat(row) * spacing + stagger
                    ctx.draw(resolved, at: CGPoint(x: x, y: y), anchor: .center)
                }
            }
        }
    }
}
