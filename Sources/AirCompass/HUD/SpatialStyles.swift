import AirCompassCore
import SwiftUI

// Mode B — spatial. Devices sit at their smoothed room bearing, quantized
// into 4/6/8 sectors, each with a monospaced `092° · E` badge.

/// Ring labels (cardinals, degree marks) step aside for a device sitting on
/// top of them rather than being drawn under its orb.
@MainActor
private func ringLabelOpacity(_ bearing: Double, _ nodes: [CompassNodeModel]) -> Double {
    nodes.contains { AngleMath.distance(AngleMath.radians($0.displayAzimuthDegrees), AngleMath.radians(bearing)) < AngleMath.radians(20) } ? 0 : 1
}

/// N/E/S/W letters around `center`.
private struct Cardinals: View {
    var center: CGPoint
    var radius: CGFloat
    var size: CGFloat = 11
    var nodes: [CompassNodeModel] = []

    var body: some View {
        ForEach(Array(["N", "E", "S", "W"].enumerated()), id: \.offset) { index, label in
            Text(label)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .foregroundStyle(index == 0 ? CompassPalette.accent : .white.opacity(0.62))
                .opacity(ringLabelOpacity(Double(index) * 90, nodes))
                .position(HUDGeometry.point(bearing: Double(index) * 90, radius: radius, center: center))
        }
        .animation(.easeOut(duration: 0.2), value: nodes.map(\.displayAzimuthDegrees))
    }
}

/// Spatial device orbs placed at their display bearing. Devices in the lower
/// part of the dial hang their labels inward so they stay on the glass.
private struct SpatialNodes: View {
    let model: CompassHUDModel
    var center: CGPoint
    var radius: (CompassNodeModel) -> CGFloat

    var body: some View {
        ForEach(model.nodes) { node in
            DeviceOrb(node: node, tint: model.tint, diameter: 40, bearing: BearingFormat.badge(node.labelDegrees),
                      labelsAbove: cos(AngleMath.radians(node.displayAzimuthDegrees)) < -0.5)
                .zIndex(node.scale)
                .position(HUDGeometry.point(bearing: node.displayAzimuthDegrees, radius: radius(node), center: center))
        }
    }
}

/// Receiving: pulses from the sender's bearing.
@MainActor @ViewBuilder
private func incoming(_ model: CompassHUDModel, center: CGPoint, radius: CGFloat) -> some View {
    if model.mode == .receiving, let azimuth = model.transfer?.peerAzimuthDegrees {
        IncomingPulse(azimuthDegrees: azimuth, radius: radius, center: center)
    }
}

// MARK: - B1 Liquid Glass Metaball Compass

/// Refractive glass dial with fine ticks; a molten glass bridge stretches from
/// the "X files" orb and snaps into the targeted device as you pull.
struct LiquidCompassStyle: View {
    let model: CompassHUDModel
    let stage: CGSize

    static let plate: CGFloat = 350
    private let nodeRadius: CGFloat = 116

    var body: some View {
        let c = CGPoint(x: stage.width / 2, y: Self.plate / 2)
        ZStack {
            Canvas { ctx, _ in drawDial(ctx, c) }
            Cardinals(center: c, radius: 143, nodes: model.nodes)

            if let vector = model.vector {
                LiquidBlobs(blobs: bridge(vector: vector, center: c), blur: 12, tint: model.tint)
            }

            incoming(model, center: c, radius: nodeRadius)

            FileCore(model: model, diameter: 84, showsCaption: true)
                .position(c)

            SpatialNodes(model: model, center: c) { _ in nodeRadius }
        }
        // The bridge fuses with the file core and the target orb it touches.
        .liquidGlassContainer("compass")
        .frame(width: stage.width, height: stage.height)
        .animation(HUDPalette.track, value: model.nodes)
        .animation(HUDPalette.track, value: model.activeSector)
    }

    private func drawDial(_ ctx: GraphicsContext, _ c: CGPoint) {
        let sectors = model.sectorMode
        if let sector = model.activeSector {
            let wedge = HUDGeometry.wedge(center: c, bearing: sectors.centerDegrees(of: sector),
                                          halfWidth: sectors.widthDegrees / 2, inner: 46, outer: 160)
            ctx.fill(wedge, with: .radialGradient(Gradient(colors: [model.tint.opacity(0.03), model.tint.opacity(model.isArmed ? 0.26 : 0.16)]),
                                                  center: c, startRadius: 46, endRadius: 160))
        }
        // Fine ticks every 6°, majors every 30°.
        for deg in stride(from: 0, to: 360, by: 6) {
            let major = deg % 30 == 0
            var tick = Path()
            tick.move(to: HUDGeometry.point(bearing: Double(deg), radius: major ? 154 : 159, center: c))
            tick.addLine(to: HUDGeometry.point(bearing: Double(deg), radius: 165, center: c))
            ctx.stroke(tick, with: .color(.white.opacity(major ? 0.62 : 0.30)), lineWidth: major ? 1 : 0.5)
        }
        // Faint sector dividers.
        for k in 0..<sectors.rawValue {
            let bearing = sectors.centerDegrees(of: k) + sectors.widthDegrees / 2
            var line = Path()
            line.move(to: HUDGeometry.point(bearing: bearing, radius: 52, center: c))
            line.addLine(to: HUDGeometry.point(bearing: bearing, radius: 150, center: c))
            ctx.stroke(line, with: .color(CompassPalette.accent.opacity(0.22)), lineWidth: 0.6)
        }
    }

    /// Blobs from the core toward the drag; past ~55 % of the commit pull the
    /// tip glides onto the target orb and swells to swallow it.
    private func bridge(vector: GestureVector, center c: CGPoint) -> [MetaballLayer.Blob] {
        let pull = HUDGeometry.pull(vector)
        var tip = HUDGeometry.point(radians: vector.theta, radius: 44 + (nodeRadius - 44) * CGFloat(pull), center: c)
        var tipRadius = 14 + 6 * CGFloat(pull)
        if let target = model.targetNode {
            let snap = smoothstep((pull - 0.55) / 0.45)
            let p = HUDGeometry.point(bearing: target.displayAzimuthDegrees, radius: nodeRadius, center: c)
            tip = CGPoint(x: tip.x + (p.x - tip.x) * snap, y: tip.y + (p.y - tip.y) * snap)
            tipRadius += (20 * CGFloat(target.scale) + 6 - tipRadius) * snap
        }
        var blobs: [MetaballLayer.Blob] = [.init(center: c, radius: 40)]
        let steps = 14
        for i in 1..<steps {
            let s = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: c.x + (tip.x - c.x) * s, y: c.y + (tip.y - c.y) * s)
            // Thins toward the middle, then bulges into the tip like a drip.
            blobs.append(.init(center: p, radius: 13 - 5 * sin(.pi * s) + 4 * s * s))
        }
        blobs.append(.init(center: tip, radius: tipRadius))
        return blobs
    }

    private func smoothstep(_ x: Double) -> CGFloat {
        let t = min(max(x, 0), 1)
        return CGFloat(t * t * (3 - 2 * t))
    }
}

// MARK: - B2 Precision Chrono Sector Wheel

/// Chronograph-style instrument: a glass bezel ring with fine graduations and
/// sector dividers; the pointed-at wedge lights up and a hand locks on.
struct ChronoDialStyle: View {
    let model: CompassHUDModel
    let stage: CGSize

    static let plate: CGFloat = 350
    private let bezelInner: CGFloat = 138
    private let bezelOuter: CGFloat = 175
    private let nodeRadius: CGFloat = 100

    var body: some View {
        let c = CGPoint(x: stage.width / 2, y: Self.plate / 2)
        ZStack {
            // Second, inner glass ring.
            Circle()
                .stroke(Color.white.opacity(0.045), lineWidth: bezelOuter - bezelInner)
                .frame(width: bezelOuter + bezelInner, height: bezelOuter + bezelInner)
                .position(c)
            Circle()
                .stroke(HUDPalette.rim, lineWidth: 1)
                .frame(width: bezelInner * 2, height: bezelInner * 2)
                .position(c)

            Canvas { ctx, _ in drawDial(ctx, c) }

            ForEach([0, 90, 180, 270], id: \.self) { deg in
                Text("\(deg)°")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(deg == 0 ? CompassPalette.accent : .white.opacity(0.75))
                    .opacity(ringLabelOpacity(Double(deg), model.nodes))
                    .position(HUDGeometry.point(bearing: Double(deg), radius: 151, center: c))
            }
            .animation(.easeOut(duration: 0.2), value: model.nodes.map(\.displayAzimuthDegrees))

            if let angle = handAngle {
                ChronoHand(angleDegrees: angle, length: 170, tint: model.tint, locked: model.targetNode != nil)
                    .position(c)
                    .transition(.opacity)
            }

            incoming(model, center: c, radius: nodeRadius)

            FileCore(model: model, diameter: 72)
                .position(c)

            if let target = model.targetNode {
                LockReticle(tint: model.tint, diameter: 40 * target.scale + 14)
                    .position(HUDGeometry.point(bearing: target.displayAzimuthDegrees, radius: nodeRadius, center: c))
            }

            SpatialNodes(model: model, center: c) { _ in nodeRadius }
        }
        .frame(width: stage.width, height: stage.height)
        .animation(HUDPalette.track, value: model.nodes)
        .animation(.easeOut(duration: 0.18), value: model.activeSector)
    }

    /// Hand follows the target when there is one, otherwise the raw drag.
    private var handAngle: Double? {
        if let target = model.targetNode { return target.displayAzimuthDegrees }
        if let vector = model.vector, vector.r > 0.01 { return AngleMath.degrees(vector.theta) }
        return nil
    }

    private func drawDial(_ ctx: GraphicsContext, _ c: CGPoint) {
        let sectors = model.sectorMode
        if let sector = model.activeSector {
            let mid = sectors.centerDegrees(of: sector), half = sectors.widthDegrees / 2
            let ring = HUDGeometry.wedge(center: c, bearing: mid, halfWidth: half, inner: bezelInner, outer: bezelOuter - 1)
            let from = HUDGeometry.point(bearing: mid - half, radius: bezelOuter, center: c)
            let to = HUDGeometry.point(bearing: mid + half, radius: bezelOuter, center: c)
            let sweep = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [CompassPalette.accent.opacity(0.55), CompassPalette.armed.opacity(model.isArmed ? 0.75 : 0.45)]),
                startPoint: from, endPoint: to)
            var glow = ctx
            glow.addFilter(.blur(radius: 6))
            glow.fill(ring, with: sweep)
            ctx.fill(ring, with: sweep)
            ctx.fill(HUDGeometry.wedge(center: c, bearing: mid, halfWidth: half, inner: 40, outer: bezelInner),
                     with: .radialGradient(Gradient(colors: [.clear, model.tint.opacity(0.12)]), center: c, startRadius: 40, endRadius: bezelInner))
        }

        // Bezel graduations: 2° fine, 10° medium, 30° long.
        for deg in stride(from: 0, to: 360, by: 2) {
            let (len, width, alpha): (CGFloat, CGFloat, Double) =
                deg % 30 == 0 ? (10, 1.1, 0.75) : deg % 10 == 0 ? (6.5, 0.8, 0.45) : (3.5, 0.5, 0.22)
            var tick = Path()
            tick.move(to: HUDGeometry.point(bearing: Double(deg), radius: 172 - len, center: c))
            tick.addLine(to: HUDGeometry.point(bearing: Double(deg), radius: 172, center: c))
            ctx.stroke(tick, with: .color(.white.opacity(alpha)), lineWidth: width)
        }

        // Sector dividers: crisp across the bezel, dashed inside.
        for k in 0..<sectors.rawValue {
            let bearing = sectors.centerDegrees(of: k) + sectors.widthDegrees / 2
            var crisp = Path()
            crisp.move(to: HUDGeometry.point(bearing: bearing, radius: bezelInner, center: c))
            crisp.addLine(to: HUDGeometry.point(bearing: bearing, radius: bezelOuter - 2, center: c))
            ctx.stroke(crisp, with: .color(CompassPalette.accent.opacity(0.7)), lineWidth: 0.8)
            var inner = Path()
            inner.move(to: HUDGeometry.point(bearing: bearing, radius: 44, center: c))
            inner.addLine(to: HUDGeometry.point(bearing: bearing, radius: bezelInner, center: c))
            ctx.stroke(inner, with: .color(.white.opacity(0.08)), style: StrokeStyle(lineWidth: 0.6, dash: [2, 4]))
        }
    }
}

/// Thin chronograph hand with a counterweight tail and a lume tip. Rotates
/// along the shortest path with a slightly springy, mechanical settle.
private struct ChronoHand: View {
    var angleDegrees: Double
    var length: CGFloat
    var tint: Color
    var locked: Bool
    @State private var shown: Double?

    var body: some View {
        let angle = shown ?? angleDegrees
        ZStack {
            // Tail.
            Capsule().fill(Color.white.opacity(0.55)).frame(width: 3, height: 26).offset(y: 13)
            // Shaft.
            Capsule().fill(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                .frame(width: 1.6, height: length)
                .offset(y: -length / 2)
            // Lume tip across the bezel.
            Capsule().fill(tint).frame(width: 3, height: 30).offset(y: -length + 15)
                .shadow(color: tint, radius: locked ? 8 : 4)
        }
        .rotationEffect(.degrees(angle))
        .onAppear { shown = angleDegrees }
        .onChange(of: angleDegrees) { _, new in
            let current = shown ?? new
            withAnimation(.spring(response: 0.28, dampingFraction: 0.62)) {
                shown = current + AngleMath.signedDifferenceDegrees(new, current)
            }
        }
    }
}

/// Bracket marks that close around the locked device.
private struct LockReticle: View {
    var tint: Color
    var diameter: CGFloat

    var body: some View {
        ZStack {
            ForEach(0..<4) { k in
                Circle()
                    .trim(from: 0.04, to: 0.16)
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(Double(k) * 90))
            }
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: tint, radius: 4)
        .transition(.scale(scale: 1.4).combined(with: .opacity))
    }
}

// MARK: - B3 Spatial Sonar Horizon Radar

/// Glass radar with 0.5 m / 1.5 m / 3 m+ rings and crosshairs. Devices sit at
/// bearing and distance; dragging casts a spotlight cone and sonar ripples
/// travel out to the target.
struct SonarRadarStyle: View {
    let model: CompassHUDModel
    let stage: CGSize

    static let plate: CGFloat = 350
    private let radarRadius: CGFloat = 140

    var body: some View {
        let c = CGPoint(x: stage.width / 2, y: Self.plate / 2)
        ZStack {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: model.mode == .hidden)) { timeline in
                Canvas { ctx, _ in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    drawGrid(ctx, c)
                    if let vector = model.vector {
                        drawCone(ctx, c, vector: vector)
                        drawRipples(ctx, c, vector: vector, time: t)
                    } else {
                        drawSweep(ctx, c, time: t)
                    }
                }
            }
            Cardinals(center: c, radius: radarRadius + 14, size: 10, nodes: model.nodes)
            ForEach(Array(zip(SonarLayout.ringFractions, ["0.5 m", "1.5 m", "3 m+"])), id: \.1) { fraction, label in
                Text(label)
                    .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .position(HUDGeometry.point(bearing: 14, radius: radarRadius * CGFloat(fraction) - 7, center: c))
            }

            incoming(model, center: c, radius: radarRadius)

            FileCore(model: model, diameter: 70)
                .position(c)

            SpatialNodes(model: model, center: c) { radius(of: $0) }
        }
        .frame(width: stage.width, height: stage.height)
        .animation(HUDPalette.track, value: model.nodes)
    }

    private func radius(of node: CompassNodeModel) -> CGFloat {
        radarRadius * CGFloat(max(SonarLayout.radiusFraction(distanceMeters: node.distanceMeters), 0.38))
    }

    private func drawGrid(_ ctx: GraphicsContext, _ c: CGPoint) {
        for fraction in SonarLayout.ringFractions {
            let r = radarRadius * CGFloat(fraction)
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                       with: .color(.white.opacity(fraction == 1 ? 0.22 : 0.13)), lineWidth: fraction == 1 ? 1 : 0.6)
        }
        var cross = Path()
        cross.move(to: CGPoint(x: c.x - radarRadius, y: c.y))
        cross.addLine(to: CGPoint(x: c.x + radarRadius, y: c.y))
        cross.move(to: CGPoint(x: c.x, y: c.y - radarRadius))
        cross.addLine(to: CGPoint(x: c.x, y: c.y + radarRadius))
        ctx.stroke(cross, with: .color(.white.opacity(0.11)), style: StrokeStyle(lineWidth: 0.6, dash: [2, 4]))
        // Short bearing marks every 30° on the outer ring.
        for deg in stride(from: 0, to: 360, by: 30) {
            var tick = Path()
            tick.move(to: HUDGeometry.point(bearing: Double(deg), radius: radarRadius - 5, center: c))
            tick.addLine(to: HUDGeometry.point(bearing: Double(deg), radius: radarRadius, center: c))
            ctx.stroke(tick, with: .color(.white.opacity(0.4)), lineWidth: 0.8)
        }
    }

    /// Idle: a slow sweep with a fading trail.
    private func drawSweep(_ ctx: GraphicsContext, _ c: CGPoint, time t: Double) {
        let bearing = (t * 72).truncatingRemainder(dividingBy: 360)
        let trail = HUDGeometry.wedge(center: c, bearing: bearing - 22, halfWidth: 22, inner: 0, outer: radarRadius)
        ctx.fill(trail, with: .conicGradient(
            Gradient(stops: [.init(color: .clear, location: 0), .init(color: CompassPalette.accent.opacity(0.20), location: 44.0 / 360),
                             .init(color: .clear, location: 44.0 / 360)]),
            center: c, angle: HUDGeometry.arcAngle(bearing: bearing - 44)))
        var line = Path()
        line.move(to: c)
        line.addLine(to: HUDGeometry.point(bearing: bearing, radius: radarRadius, center: c))
        ctx.stroke(line, with: .color(CompassPalette.accent.opacity(0.45)), lineWidth: 0.8)
    }

    /// Spotlight cone ±180°/N wide toward the drag.
    private func drawCone(_ ctx: GraphicsContext, _ c: CGPoint, vector: GestureVector) {
        let pull = HUDGeometry.pull(vector)
        let reach = radarRadius * CGFloat(0.3 + 0.7 * pull)
        let cone = HUDGeometry.wedge(center: c, bearing: AngleMath.degrees(vector.theta),
                                     halfWidth: 180 / Double(model.sectorMode.rawValue), inner: 0, outer: reach)
        var glow = ctx
        glow.addFilter(.blur(radius: 8))
        glow.fill(cone, with: .radialGradient(Gradient(colors: [model.tint.opacity(0.38), model.tint.opacity(0.04)]),
                                              center: c, startRadius: 20, endRadius: reach))
        ctx.stroke(cone, with: .color(model.tint.opacity(0.4)), lineWidth: 0.7)
    }

    /// Arcs rippling from the core out to the target (or the cone's edge).
    private func drawRipples(_ ctx: GraphicsContext, _ c: CGPoint, vector: GestureVector, time t: Double) {
        let bearing: Double
        let reach: CGFloat
        if let target = model.targetNode {
            bearing = target.displayAzimuthDegrees
            reach = radius(of: target)
        } else {
            bearing = AngleMath.degrees(vector.theta)
            reach = radarRadius * CGFloat(0.3 + 0.7 * HUDGeometry.pull(vector))
        }
        let speed = model.isArmed ? 1.6 : 1.0
        for k in 0..<3 {
            let phase = (t * speed + Double(k) / 3).truncatingRemainder(dividingBy: 1)
            let r = 38 + (reach - 38) * CGFloat(phase)
            var arc = Path()
            arc.addArc(center: c, radius: r, startAngle: HUDGeometry.arcAngle(bearing: bearing - 11),
                       endAngle: HUDGeometry.arcAngle(bearing: bearing + 11), clockwise: false)
            ctx.stroke(arc, with: .color(model.tint.opacity(0.85 * (1 - phase))),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }
}
