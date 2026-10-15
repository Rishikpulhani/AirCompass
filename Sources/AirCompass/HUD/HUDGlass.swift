import AirCompassCore
import AppKit
import SwiftUI

// MARK: - Palette and geometry

enum HUDPalette {
    /// 1.2 pt refractive rim: bright top-left, cyan mid-arc, faint bottom-right.
    static let rim = LinearGradient(
        stops: [
            .init(color: .white.opacity(0.68), location: 0),
            .init(color: .cyan.opacity(0.28), location: 0.5),
            .init(color: .white.opacity(0.14), location: 1),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let hairline = Color.white.opacity(0.12)
    static let morph = Animation.spring(response: 0.36, dampingFraction: 0.80)
    static let track = Animation.interactiveSpring(response: 0.22, dampingFraction: 0.78)
}

enum HUDGeometry {
    /// Point at a compass bearing (0° = up, clockwise) around `center`.
    static func point(bearing degrees: Double, radius: CGFloat, center: CGPoint) -> CGPoint {
        point(radians: AngleMath.radians(degrees), radius: radius, center: center)
    }

    static func point(radians a: Double, radius: CGFloat, center: CGPoint) -> CGPoint {
        CGPoint(x: center.x + CGFloat(sin(a)) * radius, y: center.y - CGFloat(cos(a)) * radius)
    }

    /// SwiftUI arc angle for a compass bearing (SwiftUI 0 = +x, clockwise on screen).
    static func arcAngle(bearing degrees: Double) -> Angle { .degrees(degrees - 90) }

    /// Annular wedge between two radii, centered on `bearing`.
    static func wedge(center: CGPoint, bearing: Double, halfWidth: Double, inner: CGFloat, outer: CGFloat) -> Path {
        var p = Path()
        p.addArc(center: center, radius: outer, startAngle: arcAngle(bearing: bearing - halfWidth),
                 endAngle: arcAngle(bearing: bearing + halfWidth), clockwise: false)
        p.addArc(center: center, radius: inner, startAngle: arcAngle(bearing: bearing + halfWidth),
                 endAngle: arcAngle(bearing: bearing - halfWidth), clockwise: true)
        p.closeSubpath()
        return p
    }

    /// Pull progress toward the commit radius, 0…1.
    static func pull(_ vector: GestureVector?) -> Double {
        guard let vector else { return 0 }
        return min(max(vector.r / ThreeFingerGestureRecognizer.Configuration().commitRadius, 0), 1)
    }
}

// MARK: - Glass

/// User-tunable glass look (Glass Appearance meter).
struct GlassAppearance: Codable, Equatable {
    /// Smoky backing behind the glass: 0 = fully clear, 1 = heavily backed.
    var background: Double = 0
    /// Apple's frosted (`.regular`) glass instead of `.clear`.
    var frosted = false
    /// Apple's system glass, or Caustic-style optical refraction.
    var engine: GlassEngine = .system
    /// Lens controls for the optical engine (Glass Lab).
    var optics = OpticsParams()

    var isOptical: Bool { engine == .optical }

    var backing: Color { .black.opacity(min(max(background, 0), 1) * 0.62) }

    @available(macOS 26, *)
    func glass(tint: Color?) -> Glass {
        (frosted ? Glass.regular : Glass.clear).tint(tint?.opacity(0.22))
    }
}

extension EnvironmentValues {
    @Entry var glassAppearance = GlassAppearance()
}

/// NSVisualEffectView bridge: blurs whatever is behind the window.
struct GlassBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .vibrantDark)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Transparent liquid glass for any shape.
///
/// On macOS 26+ this is Apple's own Liquid Glass in its `.clear` variant
/// (lensing, specular edge and adaptive shadow come from the system), so the
/// desktop shows through untouched. Glass inside a `GlassEffectContainer`
/// melts into neighbouring glass like a liquid. Older systems get a hand-built
/// approximation: behind-window blur, glaze, gloss and a refractive rim.
struct LiquidGlass<S: GlassShapeGeometry>: View {
    var shape: S
    var glaze: Double = 0.06
    var rimWidth: CGFloat = 1.2
    var shadow = true
    /// Faint tint for highlighted glass (e.g. the targeted device).
    var tint: Color?
    /// Takes the meter's smoky backing. Off for shapes built from many
    /// overlapping pieces (liquid bridge, tether), where it would stack up.
    var backed = true
    @Environment(\.glassAppearance) private var appearance

    private var backing: Color { backed ? appearance.backing : .clear }

    var body: some View {
        if appearance.isOptical {
            // Drawn by the optical renderer; this only reports where.
            Color.clear.background(GlassShapeReporter(radii: shape.cornerRadii(in:), tint: tint, backed: backed))
        } else if #available(macOS 26, *) {
            shape.fill(backing)
                .glassEffect(appearance.glass(tint: tint), in: shape)
        } else {
            legacy
        }
    }

    private var legacy: some View {
        ZStack {
            GlassBackground().clipShape(shape)
            shape.fill(.ultraThinMaterial).opacity(appearance.frosted ? 1 : 0.55)
            shape.fill(backing)
            shape.fill(Color.white.opacity(glaze))
            shape.fill(LinearGradient(colors: [.white.opacity(0.10), .clear], startPoint: .top, endPoint: .center))
            // Stroke twice the width and clip, so the rim sits fully inside the edge.
            shape.stroke(HUDPalette.rim, lineWidth: rimWidth * 2).clipShape(shape)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(shadow ? 0.20 : 0), radius: 22, y: 10)
    }
}

private struct LiquidGlassModifier<S: GlassShapeGeometry>: ViewModifier {
    var shape: S
    var tint: Color?
    var glaze: Double
    var rimWidth: CGFloat
    var merges: Bool
    var legible: Bool
    @Environment(\.glassAppearance) private var appearance

    func body(content: Content) -> some View {
        if appearance.isOptical {
            content.background(GlassShapeReporter(radii: shape.cornerRadii(in:), merges: merges, tint: tint, legible: legible))
        } else if #available(macOS 26, *) {
            content
                .background(shape.fill(appearance.backing))
                .glassEffect(appearance.glass(tint: tint), in: shape)
        } else {
            content.background(LiquidGlass(shape: shape, glaze: glaze, rimWidth: rimWidth, shadow: false, tint: tint))
        }
    }
}

enum SystemGlass {
    /// Apple's Liquid Glass (`glassEffect`) is available.
    static var isAvailable: Bool {
        if #available(macOS 26, *) { true } else { false }
    }
}

extension View {
    /// Makes this view's own content sit in liquid glass of `shape`. Content
    /// must carry the glass itself (not sit beside a glass background) so a
    /// `GlassEffectContainer` keeps it drawn on top of the merged glass.
    /// `merges: false` keeps this glass separate inside a merging container
    /// (e.g. a name pill hanging just under its orb).
    /// `legible` marks glass that carries text (frosted a little in optical mode).
    func liquidGlass<S: GlassShapeGeometry>(_ shape: S, tint: Color? = nil, glaze: Double = 0.06, rimWidth: CGFloat = 1.2,
                                            merges: Bool = true, legible: Bool = false) -> some View {
        modifier(LiquidGlassModifier(shape: shape, tint: tint, glaze: glaze, rimWidth: rimWidth, merges: merges, legible: legible))
    }

    /// Glass inside melts into touching glass like a liquid (macOS 26+).
    /// `id` names the liquid body for the optical renderer.
    @ViewBuilder
    func liquidGlassContainer(_ id: String, spacing: CGFloat = 0) -> some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { environment(\.glassMergeGroup, id) }
        } else {
            environment(\.glassMergeGroup, id)
        }
    }
}

// MARK: - Device orb

/// Glass orb with the device symbol; name pill and (Mode B only) bearing
/// badge hang below without moving the orb's center. Magnification resizes
/// the orb for real (no bitmap scaling), so symbols and text stay crisp.
struct DeviceOrb: View {
    var node: CompassNodeModel
    var tint: Color
    var diameter: CGFloat = 42
    var showsName = true
    /// e.g. "092° · E"; nil in Mode A.
    var bearing: String?
    /// Hang the labels above the orb (toward a dial's center) instead of below,
    /// so devices low on a dial keep their labels inside the glass.
    var labelsAbove = false

    private var size: CGFloat { diameter * CGFloat(node.scale) }
    /// Labels grow a little with the orb, like the Dock's tooltip emphasis.
    private var labelScale: CGFloat { 1 + (CGFloat(node.scale) - 1) * 0.25 }

    var body: some View {
        orb.overlay(alignment: labelsAbove ? .bottom : .top) {
            if showsName || bearing != nil {
                VStack(spacing: 2) {
                    if showsName { namePill }
                    if let bearing {
                        Text(bearing)
                            .font(.system(size: 8.5 * labelScale, weight: .bold, design: .monospaced))
                            .foregroundStyle(tint)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                    }
                }
                .fixedSize()
                .offset(y: labelsAbove ? -(size + 4) : size + 4)
            }
        }
    }

    private var orb: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [tint.opacity(node.isTarget ? 0.40 : 0.0), .clear],
                                         center: .center, startRadius: 0, endRadius: size * 0.62))
            if node.isTarget {
                Circle().strokeBorder(tint.opacity(0.85), lineWidth: 1.3)
            }
            Image(systemName: node.kind.symbolName)
                .font(.system(size: size * 0.40, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            if node.isSimulated {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(tint)
                    .offset(x: size * 0.34, y: -size * 0.34)
            }
        }
        .frame(width: size, height: size)
        .liquidGlass(Circle(), tint: node.isTarget ? tint : nil, glaze: node.isTarget ? 0.12 : 0.06)
        .shadow(color: node.isTarget ? tint.opacity(0.75) : .black.opacity(0.22), radius: node.isTarget ? 12 : 6, y: node.isTarget ? 0 : 3)
    }

    private var namePill: some View {
        Text(node.name)
            .font(.system(size: 9.5 * labelScale, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .shadow(color: .black.opacity(0.45), radius: 1.5)
            .liquidGlass(Capsule(), rimWidth: 0.8, merges: false)
    }
}

// MARK: - File core

/// The glass core holding the dragged files (or the incoming transfer).
struct FileCore: View {
    let model: CompassHUDModel
    var diameter: CGFloat = 84
    /// Writes "3 files" under the icon instead of a count bubble.
    var showsCaption = false

    var body: some View {
        let tint = model.tint
        let count = model.fileCount
        ZStack {
            Circle().fill(RadialGradient(colors: [tint.opacity(model.vector != nil ? 0.24 : 0.08), .clear],
                                         center: .center, startRadius: 0, endRadius: diameter * 0.55))

            if let transfer = model.transfer {
                TransferRing(fraction: transfer.fraction, color: ringColor(transfer), lineWidth: 3.5)
                    .frame(width: diameter + 8, height: diameter + 8)
            }

            VStack(spacing: 3) {
                icon(size: diameter * (showsCaption && count > 0 ? 0.40 : 0.50))
                if showsCaption, count > 0, model.transfer == nil {
                    Text(count == 1 ? "1 file" : "\(count) files")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }

            if count > 1, !showsCaption {
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(tint))
                    .offset(x: diameter * 0.32, y: -diameter * 0.32)
            }
        }
        .frame(width: diameter, height: diameter)
        .liquidGlass(Circle(), glaze: 0.08)
        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: model.transfer?.state)
    }

    @ViewBuilder
    private func icon(size: CGFloat) -> some View {
        Group {
            if case .completed = model.transfer?.state {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(CompassPalette.armed)
            } else if case .failed = model.transfer?.state {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: size * 0.7))
                    .foregroundStyle(.orange)
            } else if let thumb = model.thumbnail {
                Image(nsImage: thumb).resizable().scaledToFit().frame(width: size, height: size)
            } else if let icon = model.fileIcon {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: size, height: size)
            } else {
                Image(systemName: model.mode == .receiving ? "arrow.down.circle" : "square.on.square.dashed")
                    .font(.system(size: size * 0.55, weight: .medium))
                    .foregroundStyle(model.tint)
            }
        }
        .transition(.scale.combined(with: .opacity))
    }

    private func ringColor(_ transfer: TransferProgress) -> Color {
        switch transfer.state {
        case .completed: CompassPalette.armed
        case .failed: .orange
        default: CompassPalette.accent
        }
    }
}

// MARK: - Frosted tether

/// Translucent frosted pill stretching from the core toward the drag.
struct FrostedTether: View {
    var vector: GestureVector
    var armed: Bool
    var maxLength: CGFloat
    var width: CGFloat = 16
    @Environment(\.glassAppearance) private var appearance
    @Environment(\.glassMergeGroup) private var mergeGroup

    var body: some View {
        let length = maxLength * CGFloat(HUDGeometry.pull(vector))
        let tint = armed ? CompassPalette.armed : CompassPalette.accent
        ZStack {
            LiquidGlass(shape: Capsule(), rimWidth: 1, shadow: false, tint: tint, backed: false)
                .overlay(Capsule().fill(LinearGradient(colors: [tint.opacity(armed ? 0.45 : 0.25), .clear],
                                                       startPoint: .top, endPoint: .bottom)))
                .frame(width: width, height: length + width)
                .offset(y: -length / 2)
            Circle()
                .fill(RadialGradient(colors: [.white, tint, tint.opacity(0)], center: .center, startRadius: 0, endRadius: 13))
                .frame(width: 26, height: 26)
                .offset(y: -length)
                .shadow(color: tint, radius: armed ? 12 : 7)
        }
        .rotationEffect(.radians(vector.theta))
        .background {
            // Rotated glass can't report through its own (unrotated) frame,
            // so the optical capsule is described explicitly: this layout
            // frame is centered on the core and unaffected by the rotation.
            if appearance.isOptical {
                GeometryReader { proxy in
                    let c = CGPoint(x: proxy.frame(in: .named(HUDSpace.name)).midX, y: proxy.frame(in: .named(HUDSpace.name)).midY)
                    let center = HUDGeometry.point(radians: vector.theta, radius: length / 2, center: c)
                    Color.clear.preference(key: GlassShapesKey.self, value: [
                        GlassShapeInfo(frame: CGRect(x: center.x - width / 2, y: center.y - (length + width) / 2,
                                                     width: width, height: length + width),
                                       radii: SIMD4(repeating: Float(width / 2)), rotation: Float(vector.theta),
                                       mergeGroup: mergeGroup, backed: false),
                    ])
                }
            }
        }
        .animation(.interactiveSpring(response: 0.16, dampingFraction: 0.82), value: vector.theta)
    }
}

// MARK: - Incoming pulse

/// Pulses travelling from the sender's bearing into the center (Mode B).
struct IncomingPulse: View {
    let azimuthDegrees: Double
    let radius: CGFloat
    let center: CGPoint

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, _ in
                let t = timeline.date.timeIntervalSinceReferenceDate
                for k in 0..<3 {
                    let phase = (t * 0.9 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                    let p = HUDGeometry.point(bearing: azimuthDegrees, radius: radius * (1 - phase), center: center)
                    let r = 6 + 10 * phase
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                             with: .color(CompassPalette.armed.opacity(0.55 * (1 - phase))))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Status pill

struct StatusPill: View {
    let model: CompassHUDModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(model.tint)
            Text(text)
                .shadow(color: .black.opacity(0.4), radius: 1.5)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.opacity)
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .liquidGlass(Capsule(), legible: true)
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        .fixedSize()
        .animation(.easeOut(duration: 0.15), value: text)
    }

    private var symbol: String {
        switch model.mode {
        case .receiving: "arrow.down.forward.circle"
        case .sending where model.transfer != nil: "paperplane.fill"
        default: model.isArmed ? "scope" : "hand.draw"
        }
    }

    private var text: String {
        if let message = model.message { return message }
        if let transfer = model.transfer {
            let pct = Int((transfer.fraction * 100).rounded())
            let names = transfer.files.count == 1 ? transfer.files[0].name : "\(transfer.files.count) files"
            switch (transfer.direction, transfer.state) {
            case (.incoming, .completed): return "Received \(names) from \(transfer.peerName)"
            case (.outgoing, .completed): return "Sent \(names) to \(transfer.peerName)"
            case let (_, .failed(reason)): return "Failed: \(reason)"
            case (.incoming, _): return "\(transfer.peerName) → \(names)  \(pct)%"
            case (.outgoing, _): return "Sending \(names) → \(transfer.peerName)  \(pct)%"
            }
        }
        if model.mode == .preview, model.vector == nil {
            return model.nodes.isEmpty ? "No devices yet — seed simulated peers from the menu" : "Preview — drag 3 fingers"
        }
        if let target = model.targetName {
            return model.isArmed ? "Release to send to \(target)" : "Pull further toward \(target)"
        }
        return model.nodes.isEmpty ? "No nearby devices" : "Drag toward a device"
    }
}

// MARK: - Style switcher (preview only)

/// Tiny glass pill for live-cycling A1…B3 while previewing.
struct StyleSwitcher: View {
    let current: HUDStyle
    let glass: GlassAppearance
    let select: (HUDStyle) -> Void
    let setGlass: (GlassAppearance) -> Void
    var openLab: (() -> Void)?
    @Namespace private var selection

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(NonDirectionalStyle.allCases, id: \.self) { chip(.uniform($0)) }
                Capsule().fill(Color.white.opacity(0.2)).frame(width: 1, height: 14).padding(.horizontal, 5)
                ForEach(SpatialCompassStyle.allCases, id: \.self) { chip(.spatial($0)) }
            }
            Text("\(current.family == .uniform ? "Non-Directional" : "Spatial") · \(current.title)")
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .contentTransition(.opacity)
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 0.5).padding(.vertical, 4)
            GlassControls(appearance: glass, onChange: setGlass, onOpenLab: openLab)
                .padding(.horizontal, 6)
                .padding(.bottom, 3)
        }
        .padding(.horizontal, 7)
        .padding(.top, 6)
        .padding(.bottom, 5)
        .liquidGlass(RoundedRectangle(cornerRadius: 17, style: .continuous), legible: true)
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        .fixedSize()
        .animation(HUDPalette.morph, value: current)
    }

    private func chip(_ style: HUDStyle) -> some View {
        let isSelected = style == current
        let tint = style.family == .uniform ? CompassPalette.accent : CompassPalette.armed
        return Button { select(style) } label: {
            Text(style.code)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(isSelected ? .white : .white.opacity(0.5))
                .frame(width: 34, height: 22)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(tint.opacity(0.32))
                            .overlay(Capsule().strokeBorder(HUDPalette.rim, lineWidth: 1))
                            .matchedGeometryEffect(id: "selected", in: selection)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
