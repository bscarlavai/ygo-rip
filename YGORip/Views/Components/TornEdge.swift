import SwiftUI

/// A rectangle with one jagged torn edge.
/// Use `.topHalf` for a shape with a torn bottom edge,
/// `.bottomHalf` for a shape with a torn top edge.
/// Both use the same seed so the edges interlock perfectly.
struct TornEdge: Shape {
    enum Side { case topHalf, bottomHalf }

    let side: Side
    let seed: Int
    let teethCount: Int
    let teethHeight: CGFloat

    init(side: Side, seed: Int = 42, teethCount: Int = 20, teethHeight: CGFloat = 8) {
        self.side = side
        self.seed = seed
        self.teethCount = teethCount
        self.teethHeight = teethHeight
    }

    func path(in rect: CGRect) -> Path {
        var rng = SeededRNG(seed: UInt64(seed))
        let tornY = side == .topHalf ? rect.maxY : rect.minY
        let segmentWidth = rect.width / CGFloat(teethCount)

        var path = Path()

        switch side {
        case .topHalf:
            // Start top-left, go right, down to torn edge, back left
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: tornY))

            // Jagged edge going right to left
            for i in stride(from: teethCount, through: 0, by: -1) {
                let x = rect.minX + segmentWidth * CGFloat(i)
                let jag = CGFloat.random(in: -teethHeight...teethHeight, using: &rng)
                path.addLine(to: CGPoint(x: x, y: tornY + jag))
            }

            path.closeSubpath()

        case .bottomHalf:
            // Start at torn edge left, go right along torn edge, down, back left
            path.move(to: CGPoint(x: rect.minX, y: tornY))

            // Jagged edge going left to right (same seed = same jags)
            for i in 0...teethCount {
                let x = rect.minX + segmentWidth * CGFloat(i)
                let jag = CGFloat.random(in: -teethHeight...teethHeight, using: &rng)
                path.addLine(to: CGPoint(x: x, y: tornY + jag))
            }

            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }

        return path
    }
}

// MARK: - Seeded RNG for reproducible randomness

private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        // xorshift64
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
