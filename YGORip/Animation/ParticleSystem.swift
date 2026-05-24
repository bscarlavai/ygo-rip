import SwiftUI

/// Lightweight particle for reveal effects — sparkles, bursts, twinkles.
/// State is computed from `birth` + elapsed time so each frame is deterministic.
struct RevealParticle: Identifiable {
    let id = UUID()
    let origin: CGPoint
    let velocity: CGVector
    let color: Color
    let size: CGFloat
    let rotation: Angle
    let rotationVelocity: Double  // radians per second
    let birth: Date
    let lifespan: TimeInterval

    func progress(at now: Date) -> Double {
        min(now.timeIntervalSince(birth) / lifespan, 1)
    }

    func position(at now: Date) -> CGPoint {
        let elapsed = now.timeIntervalSince(birth)
        // Slight gravity drag — particles arc downward over time
        let gravity: CGFloat = 80
        return CGPoint(
            x: origin.x + velocity.dx * elapsed,
            y: origin.y + velocity.dy * elapsed + gravity * elapsed * elapsed * 0.5
        )
    }

    func currentRotation(at now: Date) -> Double {
        rotation.radians + rotationVelocity * now.timeIntervalSince(birth)
    }

    func isAlive(at now: Date) -> Bool {
        progress(at: now) < 1.0
    }
}

// MARK: - Sparkle Path

/// 4-pointed sparkle / star shape.
func sparkleStarPath(at center: CGPoint, size: CGFloat, rotation: Double) -> Path {
    Path { path in
        let points = 4
        let outer = size
        let inner = size * 0.32
        for i in 0..<(points * 2) {
            let angle = Double(i) * .pi / Double(points) + rotation - .pi / 2
            let r = i.isMultiple(of: 2) ? outer : inner
            let x = center.x + r * CGFloat(cos(angle))
            let y = center.y + r * CGFloat(sin(angle))
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        path.closeSubpath()
    }
}

// MARK: - One-shot Burst

/// Spawns a burst of sparkle particles outward from the view's center
/// when `trigger` changes. Particles fly out, arc with gravity, then fade.
struct ParticleBurst: View {
    let trigger: Int
    let count: Int
    let colors: [Color]
    let speedRange: ClosedRange<CGFloat>
    let lifespanRange: ClosedRange<TimeInterval>
    let sizeRange: ClosedRange<CGFloat>

    @State private var particles: [RevealParticle] = []
    @State private var lastTrigger: Int = .min
    @State private var areaSize: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { context in
                Canvas { ctx, _ in
                    let now = context.date
                    for p in particles {
                        guard p.isAlive(at: now) else { continue }
                        let progress = p.progress(at: now)
                        // Fade in fast, fade out slowly
                        let fade = progress < 0.1
                            ? progress * 10
                            : 1 - ((progress - 0.1) / 0.9)
                        let pos = p.position(at: now)
                        let rot = p.currentRotation(at: now)
                        let path = sparkleStarPath(at: pos, size: p.size, rotation: rot)
                        ctx.fill(path, with: .color(p.color.opacity(fade)))
                    }
                }
            }
            .onAppear { areaSize = geo.size }
            .onChange(of: geo.size) { _, new in areaSize = new }
            .onChange(of: trigger) { _, new in
                if new != lastTrigger {
                    lastTrigger = new
                    spawn(in: geo.size)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func spawn(in size: CGSize) {
        guard size != .zero else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let now = Date()
        var newParticles: [RevealParticle] = []
        for _ in 0..<count {
            let angle = Double.random(in: 0...(2 * .pi))
            let speed = CGFloat.random(in: speedRange)
            let v = CGVector(
                dx: cos(angle) * Double(speed),
                dy: sin(angle) * Double(speed)
            )
            newParticles.append(RevealParticle(
                origin: center,
                velocity: v,
                color: colors.randomElement() ?? .white,
                size: CGFloat.random(in: sizeRange),
                rotation: .radians(Double.random(in: 0...(2 * .pi))),
                rotationVelocity: Double.random(in: -3...3),
                birth: now,
                lifespan: TimeInterval.random(in: lifespanRange)
            ))
        }
        particles = newParticles
    }
}

// MARK: - Continuous Twinkles

/// Spawns sparkles randomly across an area at a target rate while `isActive`.
/// Each twinkle fades in and out over its lifespan.
struct ContinuousTwinkles: View {
    let isActive: Bool
    let rate: Double  // particles per second
    let colors: [Color]
    let sizeRange: ClosedRange<CGFloat>
    let lifespanRange: ClosedRange<TimeInterval>

    @State private var particles: [RevealParticle] = []
    @State private var spawnTask: Task<Void, Never>?
    @State private var areaSize: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { context in
                Canvas { ctx, _ in
                    let now = context.date
                    for p in particles {
                        guard p.isAlive(at: now) else { continue }
                        let progress = p.progress(at: now)
                        // Twinkle in/out: peak at midpoint
                        let twinkle = sin(progress * .pi)
                        let pos = p.position(at: now)
                        let rot = p.currentRotation(at: now)
                        let path = sparkleStarPath(at: pos, size: p.size, rotation: rot)
                        ctx.fill(path, with: .color(p.color.opacity(twinkle * 0.85)))
                    }
                }
            }
            .onAppear {
                areaSize = geo.size
                if isActive { startSpawning() }
            }
            .onChange(of: geo.size) { _, new in areaSize = new }
            .onChange(of: isActive) { _, active in
                if active {
                    startSpawning()
                } else {
                    spawnTask?.cancel()
                    spawnTask = nil
                }
            }
            .onDisappear {
                spawnTask?.cancel()
                spawnTask = nil
            }
            .allowsHitTesting(false)
        }
    }

    private func startSpawning() {
        spawnTask?.cancel()
        let intervalNanos = UInt64(1_000_000_000 / rate)
        spawnTask = Task { @MainActor in
            while !Task.isCancelled {
                spawnOne()
                pruneDead()
                try? await Task.sleep(nanoseconds: intervalNanos)
            }
        }
    }

    @MainActor
    private func spawnOne() {
        guard areaSize != .zero else { return }
        let particle = RevealParticle(
            origin: CGPoint(
                x: CGFloat.random(in: 0...areaSize.width),
                y: CGFloat.random(in: 0...areaSize.height)
            ),
            velocity: .zero,
            color: colors.randomElement() ?? .white,
            size: CGFloat.random(in: sizeRange),
            rotation: .radians(Double.random(in: 0...(2 * .pi))),
            rotationVelocity: 0,
            birth: Date(),
            lifespan: TimeInterval.random(in: lifespanRange)
        )
        particles.append(particle)
    }

    @MainActor
    private func pruneDead() {
        let now = Date()
        particles.removeAll { !$0.isAlive(at: now) }
    }
}

// MARK: - Rotating Light Rays

/// Slowly rotating conic gradient — a halo of light rays behind a card.
/// Masked with a radial fade so rays naturally fall off at the edges of
/// the bounding frame instead of clipping to a sharp rectangle.
struct LightRays: View {
    let color: Color
    let intensity: Double  // 0...1

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let rotation = Angle.degrees(elapsed.truncatingRemainder(dividingBy: 30) * 12)  // 30s per full turn
            AngularGradient(
                stops: rayStops(),
                center: .center,
                angle: rotation
            )
            .blur(radius: 6)
            .mask(radialFade)
            .blendMode(.plusLighter)
            .opacity(intensity)
        }
        .allowsHitTesting(false)
    }

    /// Radial mask: bright at center, fading to clear at edges.
    private var radialFade: some View {
        GeometryReader { geo in
            let radius = min(geo.size.width, geo.size.height) / 2
            RadialGradient(
                stops: [
                    .init(color: .white, location: 0.0),
                    .init(color: .white.opacity(0.85), location: 0.35),
                    .init(color: .white.opacity(0.4), location: 0.65),
                    .init(color: .clear, location: 1.0),
                ],
                center: .center,
                startRadius: 0,
                endRadius: radius
            )
        }
    }

    private func rayStops() -> [Gradient.Stop] {
        var stops: [Gradient.Stop] = []
        let rays = 8
        for i in 0..<rays {
            let pos = Double(i) / Double(rays)
            stops.append(.init(color: color.opacity(0.0), location: pos))
            stops.append(.init(color: color.opacity(0.55), location: pos + 0.025))
            stops.append(.init(color: color.opacity(0.0), location: pos + 0.05))
        }
        stops.append(.init(color: color.opacity(0.0), location: 1.0))
        return stops
    }
}

// MARK: - Shimmer Sweep

/// One-shot diagonal shimmer band that sweeps across a view (clip externally).
/// Fires when `trigger` changes, plays once, then idles.
/// Band is centered vertically and oversized so it overhangs both edges
/// of the bounding view after rotation (full top-to-bottom coverage).
struct ShimmerSweep: View {
    let trigger: Int
    let color: Color
    let duration: TimeInterval

    @State private var phase: CGFloat = 0  // 0 = off-screen left, 1 = off-screen right
    @State private var lastTrigger: Int = .min

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let bandWidth = w * 0.55
            let bandHeight = max(w, h) * 2.5
            let totalTravel = w + bandWidth * 2

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: color.opacity(0.0), location: 0.4),
                    .init(color: color.opacity(0.85), location: 0.5),
                    .init(color: color.opacity(0.0), location: 0.6),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: bandWidth, height: bandHeight)
            .rotationEffect(.degrees(20))
            .position(x: -bandWidth + totalTravel * phase, y: h / 2)
            .blendMode(.plusLighter)
            .onChange(of: trigger) { _, new in
                guard new != lastTrigger else { return }
                lastTrigger = new
                phase = 0
                withAnimation(.easeInOut(duration: duration)) {
                    phase = 1
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Continuous Shimmer (looping)

/// Continuously sweeping diagonal shimmer band — for tier 4 cards on display.
/// Band is centered vertically and oversized so it overhangs both edges
/// of the bounding view after rotation (full top-to-bottom coverage).
struct ContinuousShimmer: View {
    let color: Color
    let cycleDuration: TimeInterval

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            GeometryReader { geo in
                let elapsed = context.date.timeIntervalSinceReferenceDate
                let cyclePhase = CGFloat(
                    elapsed.truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
                )
                let w = geo.size.width
                let h = geo.size.height
                let bandWidth = w * 0.5
                let bandHeight = max(w, h) * 2.5
                let totalTravel = w + bandWidth * 2

                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: color.opacity(0.0), location: 0.4),
                        .init(color: color.opacity(0.6), location: 0.5),
                        .init(color: color.opacity(0.0), location: 0.6),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: bandWidth, height: bandHeight)
                .rotationEffect(.degrees(20))
                .position(x: -bandWidth + totalTravel * cyclePhase, y: h / 2)
                .blendMode(.plusLighter)
            }
        }
        .allowsHitTesting(false)
    }
}
