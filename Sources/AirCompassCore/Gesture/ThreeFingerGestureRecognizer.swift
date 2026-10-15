import Foundation

/// Pure, framework-free 3-finger drag state machine.
///
/// Feed it one `TouchFrame` per sensor frame; it returns at most one
/// `GestureEvent`. It holds no locks and does no I/O, so it can run directly on
/// the MultitouchSupport callback thread and be unit-tested deterministically.
public struct ThreeFingerGestureRecognizer: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// Pull distance (trackpad-height units) needed to arm a send.
        public var commitRadius: Double = 0.12
        /// Armed state drops only once `r` falls below `commitRadius * disarmRatio`,
        /// so haptics don't chatter at the boundary.
        public var disarmRatio: Double = 0.85
        /// Three contacts must persist this long before the gesture begins. Filters
        /// the transient "3" seen while a hand lands four fingers.
        public var settleDuration: TimeInterval = 0.035
        /// Number of fingers that defines the gesture.
        public var fingerCount: Int = 3

        public init() {}
    }

    private enum State: Sendable, Equatable {
        case idle
        /// Saw the right finger count; waiting for it to stay stable.
        case settling(since: TimeInterval)
        case tracking(origin: TouchPoint, began: TimeInterval, last: GestureVector, armed: Bool)
        /// Gesture finished (or was vetoed); ignore input until fingers drop
        /// below `fingerCount`, so a 4→3 lift doesn't retrigger.
        case waitingForRelease
    }

    public var configuration: Configuration
    public var sectorMode: SectorMode
    private var state: State = .idle

    public init(configuration: Configuration = .init(), sectorMode: SectorMode = .four) {
        self.configuration = configuration
        self.sectorMode = sectorMode
    }

    /// Externally visible phase, mainly for debugging and tests.
    public var phase: GesturePhase {
        switch state {
        case .idle, .settling, .waitingForRelease: .idle
        case let .tracking(_, _, last, armed): .tracking(last, armed: armed)
        }
    }

    /// True while the recognizer cares about frames from the current device.
    public var isEngaged: Bool { state != .idle }

    public mutating func process(_ frame: TouchFrame) -> GestureEvent? {
        let count = frame.contacts.count
        let target = configuration.fingerCount

        switch state {
        case .idle:
            if count == target {
                state = .settling(since: frame.timestamp)
                // Allow an immediate begin when settling is disabled.
                return configuration.settleDuration <= 0 ? process(frame) : nil
            }
            return nil

        case let .settling(since):
            guard count == target else {
                state = count > target ? .waitingForRelease : .idle
                return nil
            }
            guard frame.timestamp - since >= configuration.settleDuration else { return nil }
            let origin = Self.centroid(of: frame.contacts)
            state = .tracking(origin: origin, began: frame.timestamp, last: .zero, armed: false)
            return .began(origin: origin)

        case let .tracking(origin, began, last, armed):
            if count > target {
                state = .waitingForRelease
                return .cancelled(.extraFingers)
            }
            if count < target {
                // Fingers lifting. Use the last full 3-finger vector, because the
                // centroid jumps as soon as the first finger leaves.
                state = count == 0 ? .idle : .waitingForRelease
                guard armed else { return .cancelled(.releasedBelowThreshold) }
                return .committed(GestureCommit(
                    vector: last,
                    sector: sectorMode.sector(for: last.theta),
                    sectorMode: sectorMode,
                    duration: frame.timestamp - began
                ))
            }

            let c = Self.centroid(of: frame.contacts)
            let vector = GestureVector(dx: (c.x - origin.x) * frame.aspectRatio, dy: c.y - origin.y)
            let nowArmed = armed
                ? vector.r >= configuration.commitRadius * configuration.disarmRatio
                : vector.r >= configuration.commitRadius
            state = .tracking(origin: origin, began: began, last: vector, armed: nowArmed)
            return .changed(vector, armed: nowArmed)

        case .waitingForRelease:
            if count < target { state = .idle }
            return nil
        }
    }

    /// Host veto. Returns `.cancelled(.suppressed)` if a gesture was in flight.
    public mutating func suppress() -> GestureEvent? {
        switch state {
        case .tracking:
            state = .waitingForRelease
            return .cancelled(.suppressed)
        case .settling:
            state = .waitingForRelease
            return nil
        case .idle, .waitingForRelease:
            return nil
        }
    }

    /// Resets to idle, reporting a cancellation if a gesture was in flight.
    public mutating func reset() -> GestureEvent? {
        defer { state = .idle }
        if case .tracking = state { return .cancelled(.sourceStopped) }
        return nil
    }

    static func centroid(of contacts: [TouchContact]) -> TouchPoint {
        guard !contacts.isEmpty else { return TouchPoint(x: 0, y: 0) }
        var sx = 0.0, sy = 0.0
        for c in contacts {
            sx += c.x
            sy += c.y
        }
        let n = Double(contacts.count)
        return TouchPoint(x: sx / n, y: sy / n)
    }
}
