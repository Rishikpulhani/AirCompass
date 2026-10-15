import SwiftUI

/// One device drawn on the compass ring.
public struct CompassNodeModel: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: DeviceKind
    /// Where the node sits on the ring (degrees, 0 = top).
    public var displayAzimuthDegrees: Double
    /// Value shown on the degree badge (the true bearing).
    public var labelDegrees: Double
    public var scale: Double
    public var isTarget: Bool
    public var isSimulated: Bool
    public var subtitle: String?
    /// Slot in a horizontal row layout, in [-1, 1] (capsule style).
    public var rowPosition: Double = 0
    /// Measured distance, when known (sonar style).
    public var distanceMeters: Double?

    public init(id: String, name: String, kind: DeviceKind, displayAzimuthDegrees: Double, labelDegrees: Double,
                scale: Double = 1, isTarget: Bool = false, isSimulated: Bool = false, subtitle: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.displayAzimuthDegrees = displayAzimuthDegrees
        self.labelDegrees = labelDegrees
        self.scale = scale
        self.isTarget = isTarget
        self.isSimulated = isSimulated
        self.subtitle = subtitle
    }

    public init(peer: PeerDevice, scale: Double = 1, isTarget: Bool = false) {
        self.init(id: peer.id, name: peer.name, kind: peer.deviceKind,
                  displayAzimuthDegrees: peer.displayAzimuthDegrees, labelDegrees: peer.smoothedAzimuthDegrees,
                  scale: scale, isTarget: isTarget, isSimulated: peer.isSimulated)
        distanceMeters = peer.distanceMeters
    }
}

public enum CompassPalette {
    public static let accent = Color(red: 0.25, green: 0.85, blue: 1.0)
    public static let armed = Color(red: 0.30, green: 1.0, blue: 0.62)
    public static let ring = Color.white.opacity(0.16)
    public static let tick = Color.white.opacity(0.35)
    public static let label = Color.white.opacity(0.85)
}

/// Converts a compass bearing to a point (0° = up, clockwise).
@inlinable
func compassPoint(_ radians: Double, radius: CGFloat, center: CGPoint) -> CGPoint {
    CGPoint(x: center.x + CGFloat(sin(radians)) * radius, y: center.y - CGFloat(cos(radians)) * radius)
}

/// Precision radial compass: degree ticks, cardinals, sector dividers, active
/// wedge, drag tether, and device nodes with Dock magnification.
public struct CompassRadarView<Center: View>: View {
    public var sectorMode: SectorMode
    public var nodes: [CompassNodeModel]
    /// Drag vector to draw as a tether (nil when idle).
    public var vector: GestureVector?
    public var isArmed: Bool
    public var activeSector: Int?
    /// Pull distance that maps to the full inner radius.
    public var tetherFullScale: Double
    public var center: Center

    public init(sectorMode: SectorMode, nodes: [CompassNodeModel], vector: GestureVector? = nil, isArmed: Bool = false,
                activeSector: Int? = nil, tetherFullScale: Double = 0.2, @ViewBuilder center: () -> Center) {
        self.sectorMode = sectorMode
        self.nodes = nodes
        self.vector = vector
        self.isArmed = isArmed
        self.activeSector = activeSector
        self.tetherFullScale = tetherFullScale
        self.center = center()
    }

    public var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let ringRadius = size * 0.36
            let nodeRadius = size * 0.36

            ZStack {
                Canvas { ctx, _ in
                    drawDial(in: ctx, center: c, radius: ringRadius)
                }
                cardinals(center: c, radius: ringRadius * 0.80)

                if let vector {
                    tether(vector: vector, center: c, maxRadius: ringRadius * 0.92)
                }

                center
                    .position(c)

                ForEach(nodes) { node in
                    CompassNodeView(node: node, accent: isArmed && node.isTarget ? CompassPalette.armed : CompassPalette.accent)
                        .scaleEffect(node.scale)
                        .zIndex(node.scale)
                        .position(compassPoint(AngleMath.radians(node.displayAzimuthDegrees), radius: nodeRadius, center: c))
                }
            }
            .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.78), value: nodes)
            .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.78), value: activeSector)
        }
    }

    private func drawDial(in ctx: GraphicsContext, center c: CGPoint, radius: CGFloat) {
        let width = sectorMode.width

        // Active sector wedge.
        if let activeSector {
            let mid = sectorMode.center(of: activeSector)
            var wedge = Path()
            wedge.move(to: c)
            // SwiftUI angles: 0 = +x, clockwise in flipped coordinates; compass 0 = up.
            wedge.addArc(center: c, radius: radius,
                         startAngle: .radians(mid - width / 2 - .pi / 2),
                         endAngle: .radians(mid + width / 2 - .pi / 2), clockwise: false)
            wedge.closeSubpath()
            let color = isArmed ? CompassPalette.armed : CompassPalette.accent
            ctx.fill(wedge, with: .radialGradient(
                Gradient(colors: [color.opacity(0.05), color.opacity(isArmed ? 0.38 : 0.24)]),
                center: c, startRadius: 0, endRadius: radius))
        }

        // Rings.
        let outer = Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
        ctx.stroke(outer, with: .color(CompassPalette.ring), lineWidth: 1.2)
        let inner = radius * 0.55
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2)),
                   with: .color(Color.white.opacity(0.07)), lineWidth: 1)

        // Ticks every 15°, longer on 45° and cardinals.
        for deg in stride(from: 0, to: 360, by: 15) {
            let a = AngleMath.radians(Double(deg))
            let len: CGFloat = deg % 90 == 0 ? 12 : (deg % 45 == 0 ? 8 : 5)
            var tick = Path()
            tick.move(to: compassPoint(a, radius: radius - len, center: c))
            tick.addLine(to: compassPoint(a, radius: radius, center: c))
            ctx.stroke(tick, with: .color(deg % 90 == 0 ? CompassPalette.label : CompassPalette.tick), lineWidth: deg % 90 == 0 ? 1.6 : 1)
        }

        // Glowing sector boundaries.
        for k in 0..<sectorMode.rawValue {
            let a = sectorMode.center(of: k) + width / 2
            var line = Path()
            line.move(to: compassPoint(a, radius: radius * 0.18, center: c))
            line.addLine(to: compassPoint(a, radius: radius * 1.02, center: c))
            var glow = ctx
            glow.addFilter(.blur(radius: 3))
            glow.stroke(line, with: .color(CompassPalette.accent.opacity(0.35)), lineWidth: 3)
            ctx.stroke(line, with: .color(CompassPalette.accent.opacity(0.55)), lineWidth: 0.8)
        }
    }

    private func cardinals(center c: CGPoint, radius: CGFloat) -> some View {
        ZStack {
            ForEach(Array(["N", "E", "S", "W"].enumerated()), id: \.offset) { index, label in
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(index == 0 ? CompassPalette.accent : CompassPalette.label.opacity(0.7))
                    .position(compassPoint(Double(index) * .pi / 2, radius: radius, center: c))
            }
        }
    }

    private func tether(vector: GestureVector, center c: CGPoint, maxRadius: CGFloat) -> some View {
        let fraction = min(max(vector.r / tetherFullScale, 0), 1)
        let tip = compassPoint(vector.theta, radius: maxRadius * CGFloat(fraction), center: c)
        let color = isArmed ? CompassPalette.armed : CompassPalette.accent
        return ZStack {
            Path { p in
                p.move(to: c)
                p.addLine(to: tip)
            }
            .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: isArmed ? 3 : 2, lineCap: .round))
            .shadow(color: color, radius: isArmed ? 8 : 4)

            Circle()
                .fill(RadialGradient(colors: [.white, color, color.opacity(0)], center: .center, startRadius: 0, endRadius: 14))
                .frame(width: 28, height: 28)
                .position(tip)
                .shadow(color: color, radius: 10)
        }
        .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.8), value: vector.theta)
    }
}

extension CompassRadarView where Center == EmptyView {
    public init(sectorMode: SectorMode, nodes: [CompassNodeModel], vector: GestureVector? = nil,
                isArmed: Bool = false, activeSector: Int? = nil) {
        self.init(sectorMode: sectorMode, nodes: nodes, vector: vector, isArmed: isArmed,
                  activeSector: activeSector) { EmptyView() }
    }
}

/// Glass orb + SF Symbol + name pill + degree badge.
public struct CompassNodeView: View {
    public var node: CompassNodeModel
    public var accent: Color

    public init(node: CompassNodeModel, accent: Color = CompassPalette.accent) {
        self.node = node
        self.accent = accent
    }

    public var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(Circle().fill(RadialGradient(
                        colors: [accent.opacity(node.isTarget ? 0.55 : 0.18), .clear],
                        center: .center, startRadius: 0, endRadius: 22)))
                    .overlay(Circle().strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1))
                    .shadow(color: node.isTarget ? accent.opacity(0.9) : .black.opacity(0.4), radius: node.isTarget ? 10 : 4)
                Image(systemName: node.kind.symbolName)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.hierarchical)
                if node.isSimulated {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(accent)
                        .offset(x: 14, y: -14)
                }
            }
            .frame(width: 40, height: 40)

            Text(node.name)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.black.opacity(0.45)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                .foregroundStyle(.white)
                .fixedSize()

            Text("\(Int(node.labelDegrees.rounded()) % 360)°")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
        }
    }
}

/// Circular progress ring used on both HUDs.
public struct TransferRing: View {
    public var fraction: Double
    public var color: Color
    public var lineWidth: CGFloat

    public init(fraction: Double, color: Color = CompassPalette.accent, lineWidth: CGFloat = 4) {
        self.fraction = fraction
        self.color = color
        self.lineWidth = lineWidth
    }

    public var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color, radius: 6)
                .animation(.easeOut(duration: 0.15), value: fraction)
        }
    }
}
