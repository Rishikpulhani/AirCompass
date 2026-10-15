import Foundation

/// Angle helpers shared by the gesture recognizer, radar engine and HUD.
///
/// Convention throughout AirCompass: angles are compass bearings in radians,
/// 0 = North (fingers pushed toward the top edge of the trackpad / straight
/// ahead behind the display), increasing clockwise (π/2 = East).
public enum AngleMath {
    public static let twoPi = 2 * Double.pi

    /// Wraps any angle into [0, 2π).
    @inlinable
    public static func normalize(_ angle: Double) -> Double {
        let wrapped = angle.truncatingRemainder(dividingBy: twoPi)
        return wrapped < 0 ? wrapped + twoPi : wrapped
    }

    /// Compass bearing of a displacement vector. `dy` positive = North.
    /// Implements θ = atan2(Δx, Δy) mod 2π from the spec.
    @inlinable
    public static func bearing(dx: Double, dy: Double) -> Double {
        normalize(atan2(dx, dy))
    }

    /// Shortest unsigned angular distance between two bearings, in [0, π].
    /// δ = |atan2(sin(a − b), cos(a − b))|
    @inlinable
    public static func distance(_ a: Double, _ b: Double) -> Double {
        abs(atan2(sin(a - b), cos(a - b)))
    }

    @inlinable public static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
    @inlinable public static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
}

/// Number of equal angular sectors on the compass.
public enum SectorMode: Int, CaseIterable, Codable, Sendable {
    case four = 4
    case six = 6
    case eight = 8

    /// Sector width Δφ in radians.
    public var width: Double { AngleMath.twoPi / Double(rawValue) }

    /// Center bearing φ_k = k · Δφ.
    public func center(of sector: Int) -> Double { Double(sector) * width }

    /// k = ⌊((β + Δφ/2) mod 2π) / Δφ⌋, so sector 0 is centered on North.
    public func sector(for bearing: Double) -> Int {
        let shifted = AngleMath.normalize(bearing + width / 2)
        // min() guards against floating-point landing exactly on 2π.
        return min(Int(shifted / width), rawValue - 1)
    }
}
