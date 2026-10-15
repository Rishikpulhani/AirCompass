import AppKit
import SwiftUI

// Optical glass: real refraction of the desktop behind the HUD, ported from
// Caustic (MIT, github.com/Oxkai/liquid-glass). SwiftUI lays the glass out
// and reports every glass shape here; `OpticalGlassRenderer` bends a live
// capture of the screen under the HUD through those shapes.

/// Caustic's lens controls. Defaults are Caustic's demo values, which are
/// calibrated for a 250 pt lens; each shape scales bevel and thickness by its
/// own size so small orbs and the big dial read as the same material.
struct OpticsParams: Codable, Equatable, Sendable {
    /// Width of the curved rim band, pt.
    var bevel: Double = 34
    /// Blend from pure bezel (0) to a full spherical dome (1).
    var dome: Double = 0.30
    /// How much wider the band is at a capsule's rounded ends.
    var capBand: Double = 1.60
    /// Glass the light crosses, pt: how far the backdrop shifts.
    var thickness: Double = 150
    /// Overall bend multiplier; 1 is physically calibrated.
    var strength: Double = 1.00
    /// Scale of the backdrop seen through the glass; >1 bulges it.
    var magnify: Double = 1.15
    /// Red/blue channel split at the rim, as a fraction of the bend.
    var aberration: Double = 0.070
    /// Light direction in degrees; 0 points right, 90 down.
    var lightAngle: Double = 274
    /// Fresnel rim light, 0…1.
    var rim: Double = 0.85
    /// How much rim light the edge facing away from the light keeps.
    var backlight: Double = 0.45
    /// Blur of the bent backdrop, pt. 0 is perfectly clear.
    var frost: Double = 0
}

enum GlassEngine: String, Codable, Sendable {
    /// Apple's Liquid Glass (system compositor).
    case system
    /// Caustic-style refraction of a captured backdrop (needs Screen Recording).
    case optical
}

/// Coordinate space every glass shape reports in: the whole HUD panel.
enum HUDSpace {
    static let name = "hud"
}

/// One glass shape as the renderer needs it.
struct GlassShapeInfo: Equatable, Sendable {
    /// Unrotated frame in `HUDSpace`, points.
    var frame: CGRect
    /// Corner radii: top-left, top-right, bottom-right, bottom-left.
    var radii: SIMD4<Float>
    /// Clockwise rotation about the frame's center, radians.
    var rotation: Float = 0
    /// Shapes sharing a key melt together like liquid.
    var mergeGroup: String?
    /// Premultiplied-ish tint: rgb plus mix amount in `w`.
    var tint: SIMD4<Float> = .zero
    /// Takes the Background meter's smoky backing.
    var backed = true
    /// UI glass carrying text (status pill, switcher): kept lightly frosted
    /// and backed so labels never sit on top of sharp text behind them.
    var legible = false
}

struct GlassShapesKey: PreferenceKey {
    static let defaultValue: [GlassShapeInfo] = []
    static func reduce(value: inout [GlassShapeInfo], nextValue: () -> [GlassShapeInfo]) {
        value.append(contentsOf: nextValue())
    }
}

extension EnvironmentValues {
    /// Set by `liquidGlassContainer`: glass inside melts together.
    @Entry var glassMergeGroup: String?
}

// MARK: - Shape geometry

/// Shapes the optical renderer can reproduce exactly as a signed distance field.
protocol GlassShapeGeometry: Shape {
    func cornerRadii(in size: CGSize) -> SIMD4<Float>
}

extension Circle: GlassShapeGeometry {
    func cornerRadii(in size: CGSize) -> SIMD4<Float> { SIMD4(repeating: Float(min(size.width, size.height) / 2)) }
}

extension Capsule: GlassShapeGeometry {
    func cornerRadii(in size: CGSize) -> SIMD4<Float> { SIMD4(repeating: Float(min(size.width, size.height) / 2)) }
}

extension RoundedRectangle: GlassShapeGeometry {
    func cornerRadii(in size: CGSize) -> SIMD4<Float> { SIMD4(repeating: Float(cornerSize.width)) }
}

extension UnevenRoundedRectangle: GlassShapeGeometry {
    func cornerRadii(in size: CGSize) -> SIMD4<Float> {
        SIMD4(Float(cornerRadii.topLeading), Float(cornerRadii.topTrailing),
              Float(cornerRadii.bottomTrailing), Float(cornerRadii.bottomLeading))
    }
}

// MARK: - Reporting

/// Invisible background that reports its own frame as a glass shape.
struct GlassShapeReporter: View {
    var radii: (CGSize) -> SIMD4<Float>
    var rotation: Float = 0
    var merges = true
    var tint: Color?
    var backed = true
    var legible = false
    @Environment(\.glassMergeGroup) private var mergeGroup

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: GlassShapesKey.self, value: [
                GlassShapeInfo(frame: proxy.frame(in: .named(HUDSpace.name)), radii: radii(proxy.size),
                               rotation: rotation, mergeGroup: merges ? mergeGroup : nil,
                               tint: tint.map(Self.rgba) ?? .zero, backed: backed, legible: legible),
            ])
        }
        .allowsHitTesting(false)
    }

    private static func rgba(_ color: Color) -> SIMD4<Float> {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return SIMD4(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), 0.16)
    }
}
