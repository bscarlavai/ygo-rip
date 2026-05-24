import SwiftUI
import Observation

@Observable
@MainActor
final class FoilMotionProvider {
    var tilt: CGSize = .zero

    enum Source: Equatable { case auto, drag, device }

    private var task: Task<Void, Never>?

    func start(source: Source) {
        stop()
        switch source {
        case .auto:
            startIdleAnimation()
        case .device:
            startDeviceMotion()
        case .drag:
            break
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func setDragTilt(_ tilt: CGSize) {
        self.tilt = tilt
    }

    private func startIdleAnimation() {
        task = Task { @MainActor [weak self] in
            let start = Date()
            while !Task.isCancelled {
                let t = Date().timeIntervalSince(start)
                let x = sin(t * 0.7) * 0.6
                let y = sin(t * 1.1) * 0.4
                self?.tilt = CGSize(width: x, height: y)
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    private func startDeviceMotion() {
        let gyro = GyroService.shared
        guard gyro.isAvailable else {
            // Simulator or device without motion — fall back to the idle sweep.
            startIdleAnimation()
            return
        }
        gyro.start()
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tilt = CGSize(width: gyro.roll, height: gyro.pitch)
                try? await Task.sleep(nanoseconds: 33_000_000)  // ~30 Hz matches GyroService
            }
        }
    }
}
