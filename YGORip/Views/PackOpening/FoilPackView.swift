import SwiftUI

/// The sealed pack visual — dark era-tinted body with a tiled foil watermark
/// (generic diamond rune since YGO has no per-set glyph font), noise grain,
/// photographic crinkle/seal shadows from the BlankFoilPack source asset, top
/// accent stripe, embossed center symbol, and bottom card-count pill.
///
/// YGO packs are dominantly dark with the era's identity color reserved for
/// foil details — the pack body stays dark and the era palette appears in
/// the surface pattern, accent stripe, embossed logo, and pill rim, rather
/// than in a vibrant per-set body gradient.
struct FoilPackView: View {
    let set: SetModel
    let palette: PackPalette

    /// Native aspect ratio of the BlankFoilPack source asset.
    static let aspectRatio: CGFloat = 0.573

    var body: some View {
        CachedPackBody(set: set, palette: palette)
            .aspectRatio(Self.aspectRatio, contentMode: .fit)
            .padding(.horizontal, Theme.spacingMD)
            .shadow(color: palette.deep.opacity(0.5), radius: 22, y: 14)
    }
}

/// Stable, cached pack composition. Extracted as its own View struct so
/// SwiftUI's view identity tracking keeps the `drawingGroup()` texture
/// cached across re-renders — the static composition is rasterized once.
private struct CachedPackBody: View {
    let set: SetModel
    let palette: PackPalette

    var body: some View {
        ZStack {
            // 1. Body — era-colored gradient: mid (the era's accent color)
            //    at corners, body (darker anchor) in the middle. `mid` is
            //    the palette schema's accent slot.
            LinearGradient(
                stops: [
                    .init(color: palette.mid, location: 0.0),
                    .init(color: palette.body, location: 0.50),
                    .init(color: palette.mid, location: 1.0),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .mask { packImage }

            // 2. Surface foil pattern — generic diamond runes tiled in the
            //    era's highlight color, screen-blended so they lift out of
            //    the dark base rather than darkening it (multiply would muddy
            //    the dark body). Branded watermark feel like real-pack foil
            //    printing. mtg-rip used the set's Keyrune glyph here; YGO has
            //    no equivalent font so we tile a neutral shape.
            SetSymbolPattern(setCode: set.apiID, color: palette.highlight)
                .blendMode(.screen)
                .opacity(0.30)
                .mask { packImage }

            // 3. Noise grain — dark multiply, subtle material grain.
            noisePattern
                .blendMode(.multiply)
                .opacity(0.40)
                .mask { packImage }

            // 4. Pack image multiplied — crinkle/fold/seal shadow detail.
            //    Opacity 0.65 because the dark era bodies need an aggressive
            //    multiply to land visible crimp shadows. (We tried
            //    supplementing with .screen for highlight detail, but it
            //    lifted the whole foil sheen, not just the ridges.)
            packImage
                .blendMode(.multiply)
                .opacity(0.65)

            // 5. Static foil highlights — fixed bright bands that read as
            //    permanent reflections on shiny plastic.
            foilHighlights
                .mask { packImage }

            // 6. Pack content layout — top accent stripe, embossed set
            //    symbol, bottom card-count pill.
            packContent
                .mask { packImage }
        }
        .drawingGroup()
    }

    /// Embossed set symbol + bottom card-count pill. Layout uses
    /// proportional spacing (% of rendered pack height) so elements stay
    /// aligned regardless of rendered size.
    private var packContent: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Spacer()

                // Embossed set symbol — TCG logo with a single small shadow
                // so it feels printed onto the pack surface rather than
                // floating above it. Sized proportional to the rendered pack
                // width so it scales gracefully across phone sizes.
                SetSymbolView(set: set, size: geo.size.width * 0.78, color: palette.highlight)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)

                Spacer()

                // Card-count pill — palette.deep capsule with foil rim.
                cardCountPill

                // Reserve bottom crimped-seal area + clearance (17%) so
                // the pill sits well above the crimp.
                Spacer().frame(height: geo.size.height * 0.17)
            }
            // Without this the VStack collapses to the width of its widest
            // child and sits at top-leading of the GeometryReader, which
            // shifts the entire logo+pill stack left of the pack center.
            .frame(width: geo.size.width)
        }
    }

    /// Capsule pill with the pack's card count. Plane-tinted background,
    /// foil rim, subtle low-radius shadow so it reads as flush with the
    /// pack surface rather than floating above it.
    private var cardCountPill: some View {
        Text("\(cardCount) CARDS")
            .font(.system(size: 13, weight: .heavy, design: .rounded))
            .tracking(3)
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 7)
            .background {
                Capsule()
                    .fill(palette.deep)
                    .overlay(
                        Capsule().stroke(palette.foil.opacity(0.5), lineWidth: 0.7)
                    )
            }
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0)
    }

    /// Cards per pack for this set — derived from its PackConfig.
    private var cardCount: Int {
        PackConfig.config(for: set).cardsPerPack
    }

    /// Two static diagonal highlight bands plus a right-edge brightening,
    /// mimicking the way real foil packaging catches studio lighting from
    /// the upper-right.
    private var foilHighlights: some View {
        ZStack {
            // Primary diagonal highlight (upper-left → lower-right).
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.0), location: 0.0),
                    .init(color: .white.opacity(0.0), location: 0.32),
                    .init(color: .white.opacity(0.50), location: 0.48),
                    .init(color: .white.opacity(0.0), location: 0.64),
                    .init(color: .white.opacity(0.0), location: 1.0),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .blendMode(.plusLighter)
            .opacity(0.7)

            // Secondary thinner highlight at a different angle.
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.0), location: 0.0),
                    .init(color: .white.opacity(0.0), location: 0.55),
                    .init(color: .white.opacity(0.30), location: 0.65),
                    .init(color: .white.opacity(0.0), location: 0.75),
                    .init(color: .white.opacity(0.0), location: 1.0),
                ],
                startPoint: .topTrailing,
                endPoint: .bottomLeading
            )
            .blendMode(.plusLighter)
            .opacity(0.5)

            // Right edge brightening — light coming from the right.
            HStack(spacing: 0) {
                Spacer()
                LinearGradient(
                    colors: [.white.opacity(0.0), .white.opacity(0.18)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 40)
            }
            .blendMode(.plusLighter)
        }
    }

    private var packImage: some View {
        Image("BlankFoilPack")
            .resizable()
            .aspectRatio(contentMode: .fit)
    }

    /// Static noise grain via Canvas — dark dots, multiply blend.
    private var noisePattern: some View {
        Canvas { ctx, size in
            let count = 280
            for i in 0..<count {
                let hx = sin(Double(i) * 12.9898) * 43758.5453
                let hy = sin(Double(i) * 78.2330) * 43758.5453
                let ho = sin(Double(i) * 4.7331) * 43758.5453
                let x = CGFloat(hx - hx.rounded(.down)) * size.width
                let y = CGFloat(hy - hy.rounded(.down)) * size.height
                let opacity = (ho - ho.rounded(.down)) * 0.5 + 0.3
                let radius: CGFloat = (i.isMultiple(of: 3)) ? 0.8 : 0.5
                let path = Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2))
                ctx.fill(path, with: .color(.black.opacity(opacity)))
            }
        }
    }
}
