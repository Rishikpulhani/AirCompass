import CoreMotion
import Foundation

/// Device-motion tracking for two purposes:
/// - **Movement detection** (sound mode): when the device is picked up or
///   carried, ask the Mac to chirp right away instead of waiting for its timer.
/// - **Yaw tracking** (motion mode): after calibration, rotating the device
///   shifts its bearing. This measures *rotation*, not movement around the room.
@MainActor
final class MotionHeadingTracker {
    private let manager = CMMotionManager()
    private var referenceYaw: Double?
    private var referenceBearing = 0.0
    private var lastMovement: TimeInterval = 0

    var onBearing: ((Double) -> Void)?
    /// Fired at most every `movementInterval` seconds while the device moves.
    var onMovement: (() -> Void)?
    var movementInterval: TimeInterval = 0.5

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        let frame: CMAttitudeReferenceFrame = CMMotionManager.availableAttitudeReferenceFrames()
            .contains(.xMagneticNorthZVertical) ? .xMagneticNorthZVertical : .xArbitraryZVertical
        manager.startDeviceMotionUpdates(using: frame, to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let a = motion.userAcceleration, r = motion.rotationRate
            let accel = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            let spin = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
            let yaw = motion.attitude.yaw
            MainActor.assumeIsolated { self?.handle(yaw: yaw, acceleration: accel, rotation: spin, time: motion.timestamp) }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    /// Declares the current orientation to correspond to `bearing`.
    func calibrate(currentBearing bearing: Double) {
        referenceYaw = nil
        referenceBearing = bearing
    }

    private func handle(yaw: Double, acceleration: Double, rotation: Double, time: TimeInterval) {
        // ~0.04 g or a deliberate turn counts as "being moved".
        if acceleration > 0.04 || rotation > 0.6, time - lastMovement >= movementInterval {
            lastMovement = time
            onMovement?()
        }

        guard let reference = referenceYaw else {
            referenceYaw = yaw
            return
        }
        // Yaw grows counter-clockwise; compass bearings grow clockwise.
        let delta = (yaw - reference) * 180 / .pi
        onBearing?(referenceBearing - delta)
    }
}
