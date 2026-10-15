import Foundation

// MARK: - Degree helpers

extension AngleMath {
    /// Wraps any angle in degrees into [0, 360).
    @inlinable
    public static func normalizeDegrees(_ degrees: Double) -> Double {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    /// Signed shortest difference `a − b` in degrees, in (−180, 180].
    @inlinable
    public static func signedDifferenceDegrees(_ a: Double, _ b: Double) -> Double {
        degrees(atan2(sin(radians(a - b)), cos(radians(a - b))))
    }
}

extension SectorMode {
    public var widthDegrees: Double { 360 / Double(rawValue) }
    public func centerDegrees(of sector: Int) -> Double { Double(sector) * widthDegrees }
    public func sector(forDegrees bearing: Double) -> Int { sector(for: AngleMath.radians(bearing)) }

    public var title: String { "\(rawValue) Sectors (\(Int(widthDegrees))°)" }
}

// MARK: - Circular EMA

/// Exponential moving average on the unit circle.
///
/// Averages (sin β, cos β) instead of β itself, so a peer drifting across North
/// (359° → 1°) is smoothed through 0°, never backwards through 180°.
public struct CircularEMA: Sendable, Equatable {
    public var alpha: Double
    private var sinMean = 0.0
    private var cosMean = 0.0
    private var hasValue = false

    public init(alpha: Double = 0.28) {
        self.alpha = alpha
    }

    public var value: Double? {
        hasValue ? AngleMath.normalizeDegrees(AngleMath.degrees(atan2(sinMean, cosMean))) : nil
    }

    @discardableResult
    public mutating func update(_ degrees: Double) -> Double {
        let s = sin(AngleMath.radians(degrees)), c = cos(AngleMath.radians(degrees))
        if hasValue {
            sinMean += alpha * (s - sinMean)
            cosMean += alpha * (c - cosMean)
        } else {
            sinMean = s
            cosMean = c
            hasValue = true
        }
        return value!
    }

    public mutating func reset() {
        hasValue = false
    }
}

// MARK: - Sector layout

public enum RadarLayout {
    /// Spacing between fanned-out peers sharing a sector (±14° for two).
    public static let clusterSpacingDegrees = 28.0

    /// Assigns `assignedSector` from each peer's smoothed bearing, then sets
    /// `displayAzimuthDegrees`. A lone peer is drawn at its true bearing; peers
    /// sharing a sector are spread symmetrically around the sector center
    /// (ordered by true bearing) so each stays individually magnifiable.
    public static func apply(to peers: inout [PeerDevice], mode: SectorMode) {
        var bySector: [Int: [Int]] = [:]
        for i in peers.indices where peers[i].hasPosition {
            peers[i].assignedSector = mode.sector(forDegrees: peers[i].smoothedAzimuthDegrees)
            bySector[peers[i].assignedSector, default: []].append(i)
        }

        for (sector, indices) in bySector {
            guard indices.count > 1 else {
                peers[indices[0]].displayAzimuthDegrees = peers[indices[0]].smoothedAzimuthDegrees
                continue
            }
            let center = mode.centerDegrees(of: sector)
            let ordered = indices.sorted {
                AngleMath.signedDifferenceDegrees(peers[$0].smoothedAzimuthDegrees, center)
                    < AngleMath.signedDifferenceDegrees(peers[$1].smoothedAzimuthDegrees, center)
            }
            let n = Double(ordered.count)
            // Keep the fan inside the sector for crowded 8-sector layouts.
            let spacing = min(clusterSpacingDegrees, mode.widthDegrees * 0.8 / (n - 1))
            for (rank, index) in ordered.enumerated() {
                let offset = (Double(rank) - (n - 1) / 2) * spacing
                peers[index].displayAzimuthDegrees = AngleMath.normalizeDegrees(center + offset)
            }
        }
    }
}

// MARK: - Dock magnification

/// macOS Dock-style cosine bell magnification around the compass ring.
public enum DockMagnification {
    public static let maxScale = 1.82
    /// Pull distance at which magnification reaches full strength.
    public static let defaultActiveRadius = 0.10

    public static func spread(for mode: SectorMode) -> Double { .pi / Double(mode.rawValue) }

    /// S_i(θ, r) = 1 + clamp(r / r_active, 0, 1) · (S_max − 1) · cos²(π/2 · min(1, δ_i / δ_spread))
    /// - Parameters: `theta`, `phi` and `spread` are in radians.
    public static func scale(
        theta: Double,
        r: Double,
        phi: Double,
        spread: Double,
        activeRadius: Double = defaultActiveRadius,
        maxScale: Double = maxScale
    ) -> Double {
        let alpha = min(max(r / activeRadius, 0), 1)
        let delta = AngleMath.distance(theta, phi)
        let bell = cos(.pi / 2 * min(1, delta / spread))
        return 1 + alpha * (maxScale - 1) * max(0, bell * bell)
    }

    /// Scale for every positioned peer, keyed by peer id.
    public static func scales(
        for peers: [PeerDevice],
        theta: Double,
        r: Double,
        mode: SectorMode,
        activeRadius: Double = defaultActiveRadius
    ) -> [String: Double] {
        let spread = spread(for: mode)
        var result: [String: Double] = [:]
        for peer in peers where peer.hasPosition {
            result[peer.id] = scale(
                theta: theta, r: r,
                phi: AngleMath.radians(peer.displayAzimuthDegrees),
                spread: spread, activeRadius: activeRadius
            )
        }
        return result
    }

    /// The peer that would receive files: highest magnification, optionally
    /// restricted to one sector. Nil if nothing is magnified at all.
    public static func target(
        in peers: [PeerDevice],
        scales: [String: Double],
        sector: Int? = nil
    ) -> PeerDevice? {
        peers
            .filter { $0.hasPosition && (sector == nil || $0.assignedSector == sector) }
            .compactMap { peer in scales[peer.id].map { (peer, $0) } }
            .filter { $0.1 > 1.0001 }
            .max { $0.1 < $1.1 }?
            .0
    }
}

// MARK: - Acoustic bearing filter

/// Smoothing for sparse, occasionally wrong acoustic fixes.
///
/// A plain EMA tuned for 60 Hz dial updates takes ~7 fixes (tens of seconds)
/// to follow a moved device. Instead: small changes blend quickly; a large
/// jump is held as "pending" and applied immediately once a second fix
/// confirms it, so a single echo can't fling the node across the room.
public struct AcousticBearingFilter: Sendable, Equatable {
    public var alpha: Double
    public var jumpThresholdDegrees: Double
    public var confirmToleranceDegrees: Double

    public private(set) var value: Double?
    private var pending: Double?

    public init(alpha: Double = 0.6, jumpThresholdDegrees: Double = 25, confirmToleranceDegrees: Double = 15) {
        self.alpha = alpha
        self.jumpThresholdDegrees = jumpThresholdDegrees
        self.confirmToleranceDegrees = confirmToleranceDegrees
    }

    @discardableResult
    public mutating func update(_ degrees: Double) -> Double {
        let reading = AngleMath.normalizeDegrees(degrees)
        guard let current = value else {
            value = reading
            return reading
        }

        let change = AngleMath.signedDifferenceDegrees(reading, current)
        if abs(change) <= jumpThresholdDegrees {
            pending = nil
            value = AngleMath.normalizeDegrees(current + alpha * change)
        } else if let p = pending, abs(AngleMath.signedDifferenceDegrees(reading, p)) <= confirmToleranceDegrees {
            // Two fixes agree on the new place: snap there.
            pending = nil
            value = AngleMath.normalizeDegrees(p + AngleMath.signedDifferenceDegrees(reading, p) / 2)
        } else {
            pending = reading
        }
        return value!
    }

    public mutating func reset() {
        value = nil
        pending = nil
    }
}
