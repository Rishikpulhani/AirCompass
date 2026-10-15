import Foundation

/// A single finger contact, in normalized trackpad space ([0,1] × [0,1],
/// origin bottom-left, +y toward the top edge of the trackpad).
public struct TouchContact: Sendable, Equatable {
    public var id: Int32
    public var x: Double
    public var y: Double

    public init(id: Int32, x: Double, y: Double) {
        self.id = id
        self.x = x
        self.y = y
    }
}

/// All active contacts reported by one device for one sensor frame.
public struct TouchFrame: Sendable, Equatable {
    public var timestamp: TimeInterval
    public var contacts: [TouchContact]
    /// Physical width / height of the sensor surface. Used to scale Δx so a
    /// diagonal swipe yields a geometrically correct bearing. 1.0 = no correction.
    public var aspectRatio: Double

    public init(timestamp: TimeInterval, contacts: [TouchContact], aspectRatio: Double = 1.0) {
        self.timestamp = timestamp
        self.contacts = contacts
        self.aspectRatio = aspectRatio
    }
}

public struct TouchPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Polar drag vector measured from the initial 3-finger centroid.
/// `r` is in trackpad-height units; `theta` is a compass bearing in radians.
public struct GestureVector: Sendable, Equatable {
    public var r: Double
    public var theta: Double

    public static let zero = GestureVector(r: 0, theta: 0)

    public init(r: Double, theta: Double) {
        self.r = r
        self.theta = theta
    }

    public init(dx: Double, dy: Double) {
        self.r = (dx * dx + dy * dy).squareRoot()
        self.theta = AngleMath.bearing(dx: dx, dy: dy)
    }
}

/// Final result of a gesture that crossed the commit radius and was released.
public struct GestureCommit: Sendable, Equatable {
    public var vector: GestureVector
    /// Sector index under the sector count active when the gesture committed.
    public var sector: Int
    public var sectorMode: SectorMode
    public var duration: TimeInterval
}

public enum GestureCancelReason: Sendable, Equatable {
    /// Fingers lifted before reaching `r_commit`.
    case releasedBelowThreshold
    /// A fourth finger joined — almost certainly a system gesture.
    case extraFingers
    /// The host app vetoed the gesture (e.g. no Finder selection).
    case suppressed
    /// The input source was stopped mid-gesture.
    case sourceStopped
}

/// The recognizer's state machine:
/// `idle → tracking(r, θ) → committed(sector) | cancelled`.
public enum GesturePhase: Sendable, Equatable {
    case idle
    case tracking(GestureVector, armed: Bool)
    case committed(GestureCommit)
    case cancelled(GestureCancelReason)
}

/// Events emitted to the app layer. Delivered on the main actor by input sources.
public enum GestureEvent: Sendable, Equatable {
    /// Three fingers settled on the trackpad. The host should decide quickly
    /// (e.g. via Finder selection) whether to keep or suppress the gesture.
    case began(origin: TouchPoint)
    /// Live drag update. `armed` flips when `r` crosses `r_commit` (with hysteresis).
    case changed(GestureVector, armed: Bool)
    case committed(GestureCommit)
    case cancelled(GestureCancelReason)
}

/// Common interface for the MultitouchSupport hook and the pointer fallback.
@MainActor
public protocol GestureInputSource: AnyObject {
    var onEvent: ((GestureEvent) -> Void)? { get set }
    var sectorMode: SectorMode { get set }
    var isRunning: Bool { get }

    func start() throws
    func stop()
    /// Abandons the current gesture without emitting further events until all
    /// fingers lift. Used when Finder has no selection so system gestures win.
    func suppressCurrentGesture()
}
