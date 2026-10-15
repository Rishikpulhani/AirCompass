import AirCompassCore
import SwiftUI

// Mode A — non-directional. Devices sit on an even layout; there are no
// ticks, cardinals or degree numbers, so nothing suggests a real direction.

// MARK: - Metaball layer

/// Blur + alpha-threshold "goo": blobs that come close melt into one shape.
/// With `band`, only a thin contour is kept, which draws the glass rim.
struct MetaballLayer: View {
    struct Blob {
        var center: CGPoint
        var radius: CGFloat
    }

    var blobs: [Blob]
    /// Shapes that join the goo but are cut out afterwards (e.g. the capsule).
    var anchor: Path?
    var blur: CGFloat = 10
    /// Upper alpha bound; < 1 keeps only a rim band.
    var band: Double = 1
    var color: Color = .white

    var body: some View {
        Canvas { ctx, _ in
            ctx.drawLayer { goo in
                goo.addFilter(.alphaThreshold(min: 0.5, max: band, color: color))
                goo.addFilter(.blur(radius: blur))
                goo.drawLayer { layer in
                    if let anchor { layer.fill(anchor, with: .color(.white)) }
                    for blob in blobs {
                        let r = blob.radius
                        layer.fill(Path(ellipseIn: CGRect(x: blob.center.x - r, y: blob.center.y - r, width: r * 2, height: r * 2)),
                                   with: .color(.white))
                    }
                }
            }
            if let anchor {
                ctx.blendMode = .destinationOut
                ctx.fill(anchor, with: .color(.black))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Liquid glass filling a metaball shape, with a refractive rim band.
struct MetaballGlass: View {
    var blobs: [MetaballLayer.Blob]
    var anchor: Path?
    var blur: CGFloat = 10
    var tint: Color

    var body: some View {
        ZStack {
            GlassBackground()
            Color.white.opacity(0.06)
            LinearGradient(colors: [tint.opacity(0.42), .white.opacity(0.10)], startPoint: .top, endPoint: .bottom)
        }
        .mask(MetaballLayer(blobs: blobs, anchor: anchor, blur: blur))
        .overlay(MetaballLayer(blobs: blobs, anchor: anchor, blur: blur, band: 0.62, color: .white.opacity(0.55)))
        .shadow(color: tint.opacity(0.35), radius: 10)
    }
}

/// Liquid glass blobs. With system glass each blob is a glass circle that
/// melts into touching glass of the enclosing `liquidGlassContainer`;
/// otherwise the blur/threshold metaball approximation.
struct LiquidBlobs: View {
    var blobs: [MetaballLayer.Blob]
    var blur: CGFloat = 10
    var tint: Color
    @Environment(\.glassAppearance) private var appearance

    var body: some View {
        if SystemGlass.isAvailable || appearance.isOptical {
            ZStack {
                ForEach(blobs.indices, id: \.self) { i in
                    let blob = blobs[i]
                    LiquidGlass(shape: Circle(), shadow: false, tint: tint, backed: false)
                        .frame(width: blob.radius * 2, height: blob.radius * 2)
                        .position(blob.center)
                }
            }
            .allowsHitTesting(false)
        } else {
            MetaballGlass(blobs: blobs, blur: blur, tint: tint)
        }
    }
}

// MARK: - A1 Orbital Glass Halo

/// 320 pt glass halo; devices evenly spaced on an unmarked orbit; a frosted
/// pill tether stretches from the file core toward the drag.
struct OrbitalHaloStyle: View {
    let model: CompassHUDModel
    let stage: CGSize

    static let plate: CGFloat = 320
    private let orbit: CGFloat = 122

    var body: some View {
        let c = CGPoint(x: stage.width / 2, y: Self.plate / 2)
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [model.tint.opacity(model.vector == nil ? 0.06 : 0.14), .clear],
                                     center: .center, startRadius: 0, endRadius: 150))
                .frame(width: 300, height: 300)
                .position(c)

            OrbitTrack(radius: orbit, center: c, tint: model.tint, live: model.mode != .hidden,
                       highlight: model.targetNode.map { ($0.displayAzimuthDegrees, 360 / Double(max(model.nodes.count, 1))) })

            if let vector = model.vector {
                FrostedTether(vector: vector, armed: model.isArmed, maxLength: orbit - 34)
                    .position(c)
            }

            FileCore(model: model, diameter: 86)
                .position(c)

            ForEach(model.nodes) { node in
                DeviceOrb(node: node, tint: model.tint)
                    .zIndex(node.scale)
                    .position(HUDGeometry.point(bearing: node.displayAzimuthDegrees, radius: orbit, center: c))
            }
        }
        // The tether melts out of the file core like a drawn-out droplet.
        .liquidGlassContainer("halo")
        .frame(width: stage.width, height: stage.height)
        .animation(HUDPalette.track, value: model.nodes)
    }
}

/// Hairline orbit with a slow light glint travelling around it, and a lit arc
/// under the targeted device.
private struct OrbitTrack: View {
    var radius: CGFloat
    var center: CGPoint
    var tint: Color
    var live: Bool
    /// (bearing, slot width) of the targeted device.
    var highlight: (Double, Double)?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !live)) { timeline in
            Canvas { ctx, _ in
                let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                ctx.stroke(ring, with: .color(HUDPalette.hairline), lineWidth: 0.6)

                let t = timeline.date.timeIntervalSinceReferenceDate
                let glint = Angle.degrees((t * 40).truncatingRemainder(dividingBy: 360))
                ctx.stroke(ring, with: .conicGradient(
                    Gradient(stops: [.init(color: .clear, location: 0), .init(color: .white.opacity(0.35), location: 0.08),
                                     .init(color: .clear, location: 0.16), .init(color: .clear, location: 1)]),
                    center: center, angle: glint), lineWidth: 1)

                if let highlight {
                    let (bearing, slot) = highlight
                    var arc = Path()
                    let half = min(slot * 0.35, 40)
                    arc.addArc(center: center, radius: radius, startAngle: HUDGeometry.arcAngle(bearing: bearing - half),
                               endAngle: HUDGeometry.arcAngle(bearing: bearing + half), clockwise: false)
                    var glow = ctx
                    glow.addFilter(.blur(radius: 4))
                    glow.stroke(arc, with: .color(tint.opacity(0.7)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    ctx.stroke(arc, with: .color(tint), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - A2 Dynamic Island Capsule

/// A glass pill tucked under the notch. Devices sit in a row; sideways drag
/// picks one, pulling inflates it and it drips out of the capsule as a liquid
/// glass droplet.
struct IslandCapsuleStyle: View {
    let model: CompassHUDModel
    let stage: CGSize

    static let plate = CGSize(width: 420, height: 68)
    @Environment(\.glassAppearance) private var appearance
    private let orb: CGFloat = 40
    /// How far a fully magnified orb drops below the capsule's centerline.
    private let drop: CGFloat = 62

    private var capsule: CGRect {
        CGRect(x: (stage.width - Self.plate.width) / 2, y: 0, width: Self.plate.width, height: Self.plate.height)
    }

    private var lane: (mid: CGFloat, half: CGFloat) {
        let lo = capsule.minX + 112, hi = capsule.maxX - 56
        return ((lo + hi) / 2, (hi - lo) / 2)
    }

    private func position(_ node: CompassNodeModel) -> CGPoint {
        let lift = min(max((node.scale - 1) / (DockMagnification.maxScale - 1), 0), 1)
        let spread = model.nodes.count > 1 ? lane.half : 0
        return CGPoint(x: lane.mid + CGFloat(node.rowPosition) * spread, y: capsule.midY + CGFloat(lift) * drop)
    }

    var body: some View {
        let anchor = Path(roundedRect: capsule, cornerRadius: capsule.height / 2, style: .continuous)
        ZStack {
            if SystemGlass.isAvailable || appearance.isOptical {
                // The capsule and every orb are system glass in one container:
                // an orb pulled down out of the capsule stays fused to it by a
                // liquid neck, exactly like Dynamic Island.
                LiquidGlass(shape: Capsule())
                    .frame(width: capsule.width, height: capsule.height)
                    .position(x: capsule.midX, y: capsule.midY)
            } else {
                MetaballGlass(
                    blobs: model.nodes.map { .init(center: position($0), radius: orb / 2 * CGFloat($0.scale) + 2) },
                    anchor: anchor, blur: 10, tint: model.tint
                )
            }

            pointerGlow

            FileCore(model: model, diameter: 50)
                .position(x: capsule.minX + 36, y: capsule.midY)

            if model.nodes.isEmpty {
                Text("Looking for devices…")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .position(x: lane.mid, y: capsule.midY)
            }

            ForEach(model.nodes) { node in
                DeviceOrb(node: node, tint: model.tint, diameter: orb, showsName: node.scale > 1.3)
                    .zIndex(node.scale)
                    .position(position(node))
            }
        }
        .liquidGlassContainer("island")
        .frame(width: stage.width, height: stage.height)
        .animation(HUDPalette.track, value: model.nodes)
    }

    /// A small light under the capsule's lower edge that follows the sideways
    /// drag until a device takes over by dripping out.
    @ViewBuilder
    private var pointerGlow: some View {
        if let vector = model.vector, model.targetNode == nil {
            let x = lane.mid + CGFloat(UniformLayout.rowPointer(theta: vector.theta, r: vector.r)) * lane.half
            Capsule()
                .fill(model.tint)
                .frame(width: 28, height: 3)
                .shadow(color: model.tint, radius: 6)
                .opacity(0.4 + 0.6 * HUDGeometry.pull(vector))
                .position(x: x, y: capsule.maxY - 6)
                .animation(.interactiveSpring(response: 0.16, dampingFraction: 0.85), value: x)
        }
    }
}

// MARK: - A3 Top-Center 180° Notch Fan

/// An inverted glass protractor hanging from the notch. Devices fan out along
/// the lower arc; a soft glass spotlight sweeps toward the drag.
struct NotchFanStyle: View {
    let model: CompassHUDModel
    let stage: CGSize

    static let plate = CGSize(width: 360, height: 195)
    static let topRadius: CGFloat = 14
    private let deviceRadius: CGFloat = 126

    var body: some View {
        // The lower arc's center sits on the plate's top band.
        let o = CGPoint(x: stage.width / 2, y: Self.plate.height - Self.plate.width / 2)
        let count = max(model.nodes.count, 1)
        ZStack {
            Canvas { ctx, _ in
                // Concentric hairline arcs and faint ribs between device slots.
                for (r, alpha) in [(60.0, 0.08), (deviceRadius, 0.12), (168, 0.08)] {
                    var arc = Path()
                    arc.addArc(center: o, radius: r, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
                    ctx.stroke(arc, with: .color(.white.opacity(alpha)), lineWidth: 0.6)
                }
                for k in 1..<count {
                    let bearing = 270 - Double(k) * 180 / Double(count)
                    var rib = Path()
                    rib.move(to: HUDGeometry.point(bearing: bearing, radius: 62, center: o))
                    rib.addLine(to: HUDGeometry.point(bearing: bearing, radius: 166, center: o))
                    ctx.stroke(rib, with: .color(.white.opacity(0.05)), lineWidth: 0.6)
                }
            }

            if let vector = model.vector {
                spotlight(vector: vector, origin: o, count: count)
            }

            FileCore(model: model, diameter: 56)
                .position(x: o.x, y: o.y + 32)

            ForEach(model.nodes) { node in
                DeviceOrb(node: node, tint: model.tint)
                    .zIndex(node.scale)
                    .position(HUDGeometry.point(bearing: node.displayAzimuthDegrees, radius: deviceRadius, center: o))
            }
        }
        .frame(width: stage.width, height: stage.height)
        .animation(HUDPalette.track, value: model.nodes)
    }

    private func spotlight(vector: GestureVector, origin o: CGPoint, count: Int) -> some View {
        let bearing = UniformLayout.arcPointer(theta: vector.theta)
        let pull = HUDGeometry.pull(vector)
        let reach = 172 * CGFloat(0.35 + 0.65 * pull)
        let beam = HUDGeometry.wedge(center: o, bearing: bearing, halfWidth: min(90 / Double(count), 24), inner: 34, outer: reach)
        let tint = model.tint
        return ZStack {
            beam.fill(RadialGradient(colors: [tint.opacity(0.42), tint.opacity(0.10), .clear],
                                     center: UnitPoint(x: o.x / stage.width, y: o.y / stage.height),
                                     startRadius: 30, endRadius: 180))
                .blur(radius: 5)
            beam.fill(Color.white.opacity(0.05))
            beam.stroke(tint.opacity(0.35), lineWidth: 0.6)
        }
        .animation(.interactiveSpring(response: 0.16, dampingFraction: 0.85), value: bearing)
        .allowsHitTesting(false)
    }
}
