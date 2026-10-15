import Foundation

// MARK: - Modes and styles

/// Which family of HUD is drawn.
public enum HUDFamily: String, Sendable {
    /// Mode A: devices on an even layout; no bearings, ticks or cardinals.
    case uniform
    /// Mode B: devices at their measured room bearing.
    case spatial
}

/// User choice between the two families.
public enum TrackingMode: String, CaseIterable, Codable, Sendable {
    case auto
    case nonDirectional
    case spatial

    public var title: String {
        switch self {
        case .auto: "Auto (Spatial when Companion Active, Uniform otherwise)"
        case .nonDirectional: "Always Non-Directional (Mode A)"
        case .spatial: "Always Spatial Compass (Mode B)"
        }
    }

    /// Auto shows the spatial compass only when every nearby device has a real
    /// position, so a device without one is never hidden or drawn at a made-up
    /// bearing.
    public func resolve(peers: [PeerDevice]) -> HUDFamily {
        switch self {
        case .nonDirectional: .uniform
        case .spatial: .spatial
        case .auto: !peers.isEmpty && peers.allSatisfy(\.hasPosition) ? .spatial : .uniform
        }
    }
}

public enum NonDirectionalStyle: String, CaseIterable, Codable, Sendable {
    case orbitalHalo
    case dynamicIslandCapsule
    case notchHalfArc

    public var title: String {
        switch self {
        case .orbitalHalo: "Orbital Glass Halo"
        case .dynamicIslandCapsule: "Dynamic Island Capsule"
        case .notchHalfArc: "Top-Center 180° Notch Fan"
        }
    }

    public var code: String { "A\((Self.allCases.firstIndex(of: self) ?? 0) + 1)" }
}

public enum SpatialCompassStyle: String, CaseIterable, Codable, Sendable {
    case liquidGlassCompass
    case chronoSectorDial
    case sonarHorizonRadar

    public var title: String {
        switch self {
        case .liquidGlassCompass: "Liquid Glass Metaball Compass"
        case .chronoSectorDial: "Precision Chrono Sector Wheel"
        case .sonarHorizonRadar: "Spatial Sonar Horizon Radar"
        }
    }

    public var code: String { "B\((Self.allCases.firstIndex(of: self) ?? 0) + 1)" }
}

/// One of the six concrete HUD looks.
public enum HUDStyle: Hashable, Sendable {
    case uniform(NonDirectionalStyle)
    case spatial(SpatialCompassStyle)

    public static let allCases: [HUDStyle] =
        NonDirectionalStyle.allCases.map(HUDStyle.uniform) + SpatialCompassStyle.allCases.map(HUDStyle.spatial)

    public var family: HUDFamily {
        switch self {
        case .uniform: .uniform
        case .spatial: .spatial
        }
    }

    public var code: String {
        switch self {
        case let .uniform(style): style.code
        case let .spatial(style): style.code
        }
    }

    public var title: String {
        switch self {
        case let .uniform(style): style.title
        case let .spatial(style): style.title
        }
    }
}

// MARK: - Mode A layout

/// Even layouts for the non-directional styles, and Dock magnification that
/// maps the 3-finger drag onto each layout.
public enum UniformLayout {
    /// Sideways pull (normalized trackpad units) that reaches the end of the
    /// capsule row.
    public static let rowReach = 0.10

    /// Orbital halo: K devices evenly around the full circle (degrees, 0 = up).
    public static func orbitAngles(count: Int) -> [Double] {
        switch count {
        case ...0: []
        case 1: [0]
        case 2: [270, 90]
        default: (0..<count).map { Double($0) * 360 / Double(count) }
        }
    }

    /// Notch fan: K devices along the lower semicircle, West → South → East,
    /// each centered in an equal slice so none sit on the flat top edge.
    public static func arcAngles(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        let step = 180 / Double(count)
        return (0..<count).map { 270 - (Double($0) + 0.5) * step }
    }

    /// Capsule: K devices in a balanced row, positions in [-1, 1].
    public static func rowPositions(count: Int) -> [Double] {
        switch count {
        case ...0: []
        case 1: [0]
        default: (0..<count).map { -1 + 2 * Double($0) / Double(count - 1) }
        }
    }

    /// Drag direction projected onto the fan (degrees in [90, 270]); pointing
    /// up into the notch clamps to the nearest end of the fan.
    public static func arcPointer(theta: Double) -> Double {
        let bearing = AngleMath.normalizeDegrees(AngleMath.degrees(theta))
        if (90...270).contains(bearing) { return bearing }
        return bearing < 90 ? 90 : 270
    }

    /// Horizontal drag projected onto the capsule row, in [-1, 1].
    public static func rowPointer(theta: Double, r: Double) -> Double {
        min(max(r * sin(theta) / rowReach, -1), 1)
    }

    /// Dock magnification for each slot (same order as the layout arrays).
    /// The bell spreads over one full slot spacing so neighbours swell
    /// slightly, like the Dock.
    public static func scales(
        style: NonDirectionalStyle,
        count: Int,
        theta: Double,
        r: Double,
        activeRadius: Double = DockMagnification.defaultActiveRadius
    ) -> [Double] {
        guard count > 0 else { return [] }
        let strength = min(max(r / activeRadius, 0), 1)
        func bell(_ delta: Double, spread: Double) -> Double {
            let c = cos(.pi / 2 * min(1, delta / spread))
            return 1 + strength * (DockMagnification.maxScale - 1) * max(0, c * c)
        }

        switch style {
        case .orbitalHalo:
            let spread = count == 1 ? Double.pi : 2 * .pi / Double(count)
            return orbitAngles(count: count).map {
                bell(AngleMath.distance(theta, AngleMath.radians($0)), spread: spread)
            }
        case .notchHalfArc:
            let pointer = arcPointer(theta: theta)
            let spread = 180 / Double(count)
            return arcAngles(count: count).map { bell(abs(pointer - $0), spread: spread) }
        case .dynamicIslandCapsule:
            let pointer = rowPointer(theta: theta, r: r)
            let spread = count == 1 ? 2 : 2 / Double(count - 1)
            return rowPositions(count: count).map { bell(abs(pointer - $0), spread: spread) }
        }
    }

    /// Index of the most magnified slot, or nil when nothing is magnified.
    public static func targetIndex(scales: [Double]) -> Int? {
        guard let best = scales.indices.max(by: { scales[$0] < scales[$1] }), scales[best] > 1.0001 else { return nil }
        return best
    }

    /// HUD nodes for `peers` in this style. Bearings are layout positions,
    /// not measurements, so `labelDegrees` is never shown in Mode A.
    public static func nodes(
        for peers: [PeerDevice],
        style: NonDirectionalStyle,
        scales: [Double]? = nil,
        targetIndex: Int? = nil
    ) -> [CompassNodeModel] {
        let angles: [Double] = switch style {
        case .orbitalHalo: orbitAngles(count: peers.count)
        case .notchHalfArc: arcAngles(count: peers.count)
        case .dynamicIslandCapsule: Array(repeating: 180, count: peers.count)
        }
        let rows = rowPositions(count: peers.count)
        return peers.enumerated().map { i, peer in
            var node = CompassNodeModel(peer: peer, scale: scales?[i] ?? 1, isTarget: i == targetIndex)
            node.displayAzimuthDegrees = angles[i]
            node.rowPosition = rows[i]
            return node
        }
    }
}

// MARK: - Sonar distance rings

public enum SonarLayout {
    /// Labelled rings: 0.5 m, 1.5 m, 3 m+.
    public static let ringDistances = [0.5, 1.5, 3.0]
    public static let ringFractions = [1.0 / 3, 2.0 / 3, 1.0]

    /// Radius as a fraction of the radar, piecewise-linear through the rings.
    /// Unknown distance sits on the outer ring.
    public static func radiusFraction(distanceMeters: Double?) -> Double {
        guard let d = distanceMeters, d.isFinite, d >= 0 else { return 1 }
        let stops: [(Double, Double)] = [(0, 0.12)] + zip(ringDistances, ringFractions).map { ($0, $1) }
        for (lower, upper) in zip(stops, stops.dropFirst()) where d <= upper.0 {
            let t = (d - lower.0) / (upper.0 - lower.0)
            return lower.1 + t * (upper.1 - lower.1)
        }
        return 1
    }
}

// MARK: - Bearing text

public enum BearingFormat {
    private static let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

    /// Nearest of the eight compass points.
    public static func cardinal(_ degrees: Double) -> String {
        points[Int((AngleMath.normalizeDegrees(degrees) / 45).rounded()) % 8]
    }

    /// Monospaced badge text, e.g. `092° · E`.
    public static func badge(_ degrees: Double) -> String {
        let whole = Int(AngleMath.normalizeDegrees(degrees).rounded()) % 360
        return String(format: "%03d° · %@", whole, cardinal(degrees))
    }
}
