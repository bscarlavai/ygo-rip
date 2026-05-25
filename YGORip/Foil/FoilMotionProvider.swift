import SwiftUI
import Observation

@Observable
@MainActor
final class FoilMotionProvider {
    var tilt: CGSize = .zero

    enum Source: Equatable { case auto, drag, device }

    private var task: Task<Void, Never>?
    private var currentSource: Source?

    /// Bumped on every start/stop. Each driver Task captures its epoch and
    /// only writes `tilt` if the live epoch still matches — protects against
    /// stale writes from a Task that woke from `Task.sleep` AFTER `stop()`
    /// cancelled it. Swift's cooperative cancellation only takes effect at
    /// the next `try await Task.checkCancellation` / `Task.sleep` throw, so
    /// `try? await Task.sleep` swallows the cancellation and the loop body
    /// runs one more time, racing with whoever just called `start()`.
    private var epoch: Int = 0

    func start(source: Source) {
        stop()
        currentSource = source
        switch source {
        case .auto:   startIdleAnimation(epoch: epoch)
        case .device: startDeviceMotion(epoch: epoch)
        case .drag:   break
        }
    }

    func stop() {
        epoch &+= 1
        task?.cancel()
        task = nil
        // When leaving `.device`, halt the CoreMotion stream too — otherwise
        // CMMotionManager keeps firing its callback at ~30Hz, each
        // dispatching a `Task { @MainActor }` to write pitch/roll. If the
        // FoilMotionProvider consumer is gone (e.g. switched to `.drag`),
        // those Tasks accumulate on the main actor with nothing to drain
        // them. Long press-and-hold drags hit this regularly.
        if currentSource == .device {
            GyroService.shared.stop()
        }
        currentSource = nil
    }

    func setDragTilt(_ tilt: CGSize) {
        self.tilt = tilt
    }

    private func startIdleAnimation(epoch capturedEpoch: Int) {
        task = Task { @MainActor [weak self] in
            let start = Date()
            while !Task.isCancelled {
                guard let self, self.epoch == capturedEpoch else { return }
                let t = Date().timeIntervalSince(start)
                let x = sin(t * 0.7) * 0.6
                let y = sin(t * 1.1) * 0.4
                self.tilt = CGSize(width: x, height: y)
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    private func startDeviceMotion(epoch capturedEpoch: Int) {
        let gyro = GyroService.shared
        guard gyro.isAvailable else {
            // Simulator or device without motion — fall back to the idle sweep.
            startIdleAnimation(epoch: capturedEpoch)
            return
        }
        gyro.start()
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.epoch == capturedEpoch else { return }
                self.tilt = CGSize(width: gyro.roll, height: gyro.pitch)
                try? await Task.sleep(nanoseconds: 33_000_000)  // ~30 Hz matches GyroService
            }
        }
    }
}
