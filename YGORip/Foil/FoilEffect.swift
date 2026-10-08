import SwiftUI

/// Applies the foil color shader only. Use this when you need to insert
/// overlay views (e.g. a "NEW" badge) between the shader pass and the 3D
/// rotation — those overlays will then rotate *with* the card without being
/// tinted by the foil shader.
struct FoilShaderModifier: ViewModifier {
    let treatment: FoilTreatment
    let motion: FoilMotionProvider
    var intensity: Float = 1.0

    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { size = geo.size }
                        .onChange(of: geo.size) { _, new in size = new }
                }
            }
            .colorEffect(shader())
    }

    /// Always `cardShimmer`, never a second function — `.colorEffect` is a
    /// single render node, and SwiftUI updates it in place when the view it's
    /// attached to keeps its structural position. Returning a shader with a
    /// *different argument count* from the previous render makes
    /// `ShaderVectorData.updating(rbShader:)` reconcile the old argument
    /// vector against the new `RBShader`, walk past its last argument, and
    /// `abort` in `RB::precondition_failure`.
    ///
    /// Cards occupy the same position in the hierarchy during a reveal and in
    /// card inspect, so an unfoiled card followed by a foiled one crossed a
    /// 0-argument → 5-argument boundary. This was the top App Store crash in
    /// PokeRip, which shares this file; it is fixed here pre-emptively.
    ///
    /// `.none` is expressed as zeroed parameters instead. That's pixel-exact,
    /// not an approximation: with all three at zero the sheen and sparkle
    /// layers are zero and `fs_colorDodge(base, 0)` is `base / 1.0`.
    private func shader() -> Shader {
        let p = Self.params(for: treatment)
        // Zeroed params make tilt irrelevant for `.none`, and reading
        // `motion.tilt` would subscribe every unfoiled card to the 60 Hz
        // motion updates for nothing.
        let tilt = treatment == .none ? .zero : motion.tilt
        return ShaderLibrary.cardShimmer(
            .float2(Float(size.width), Float(size.height)),
            .float2(Float(tilt.width), Float(tilt.height)),
            .float(p.sheen * intensity),
            .float(p.rainbow * intensity),
            .float(p.sparkle * intensity)
        )
    }

    private struct Params {
        let sheen: Float
        let rainbow: Float
        let sparkle: Float
    }

    private static func params(for treatment: FoilTreatment) -> Params {
        switch treatment {
        case .none:         return Params(sheen: 0,    rainbow: 0,    sparkle: 0)
        case .subtle:       return Params(sheen: 0.5,  rainbow: 0.15, sparkle: 0.08)
        case .holo:         return Params(sheen: 0.7,  rainbow: 0.25, sparkle: 0.25)
        case .illustration: return Params(sheen: 0.9,  rainbow: 0.4,  sparkle: 0.45)
        case .secret:       return Params(sheen: 1.0,  rainbow: 0.55, sparkle: 0.65)
        }
    }
}

/// Applies tilt-driven 3D rotation + a matching drop shadow. Apply this *after*
/// any badges or overlays you want to rotate with the card.
struct FoilRotationModifier: ViewModifier {
    let motion: FoilMotionProvider
    var degrees: Double = 8

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(
                .degrees(Double(motion.tilt.height) * degrees),
                axis: (x: -1, y: 0, z: 0),
                perspective: 0.6
            )
            .rotation3DEffect(
                .degrees(Double(motion.tilt.width) * degrees),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.6
            )
            .shadow(
                color: .black.opacity(0.4),
                radius: 12,
                x: CGFloat(-motion.tilt.width) * 6,
                y: CGFloat(-motion.tilt.height) * 6 + 8
            )
    }
}

/// Pre-compile the foil shaders so the first card render doesn't hitch.
/// Called once from `YGORipApp` at launch. iOS 18+ only.
@MainActor
func compileFoilShaders() async {
    let shaders: [Shader] = [
        ShaderLibrary.cardShimmer(
            .float2(100, 100),
            .float2(0, 0),
            .float(0.5),
            .float(0.25),
            .float(0.1)
        ),
    ]
    for shader in shaders {
        try? await shader.compile(as: .colorEffect)
    }
}

extension View {
    /// Shader only — no rotation. Pair with `.foilRotation(...)` if you need
    /// to insert overlays between the two passes.
    func foilShader(
        treatment: FoilTreatment,
        motion: FoilMotionProvider,
        intensity: Float = 1.0
    ) -> some View {
        modifier(FoilShaderModifier(treatment: treatment, motion: motion, intensity: intensity))
    }

    /// Rotation + tilt shadow only.
    func foilRotation(
        motion: FoilMotionProvider,
        degrees: Double = 8
    ) -> some View {
        modifier(FoilRotationModifier(motion: motion, degrees: degrees))
    }

    /// Convenience: shader + rotation in one shot. Use when there's nothing
    /// to insert between them.
    func foilEffect(
        treatment: FoilTreatment,
        motion: FoilMotionProvider,
        intensity: Float = 1.0,
        rotationDegrees: Double = 8
    ) -> some View {
        foilShader(treatment: treatment, motion: motion, intensity: intensity)
            .foilRotation(motion: motion, degrees: rotationDegrees)
    }
}
