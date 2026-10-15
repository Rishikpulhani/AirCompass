import AppKit
import CoreVideo
import Metal
import MetalKit
import os
import SwiftUI

/// Transparent Metal layer covering the HUD panel. Each frame it bends the
/// captured backdrop through every reported glass shape; outside the shapes
/// it draws nothing, so the real desktop shows through untouched.
struct OpticalGlassLayer: NSViewRepresentable {
    var shapes: [GlassShapeInfo]
    var appearance: GlassAppearance
    var active: Bool

    func makeCoordinator() -> OpticalGlassRenderer { OpticalGlassRenderer() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.layer?.isOpaque = false
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.shapes = shapes
        context.coordinator.appearance = appearance
        view.isPaused = !active
    }
}

/// Holds a frame's texture until the GPU has finished reading it.
private final class RetainedTexture: @unchecked Sendable {
    let texture: CVMetalTexture
    init(texture: CVMetalTexture) { self.texture = texture }
}

// MARK: - GPU layouts (must match the Metal structs below)

private struct ShaderUniforms {
    var viewSize: SIMD2<Float>
    var scale: Float
    var groupCount: UInt32
    var bevel: Float, dome: Float, capBand: Float, thickness: Float
    var strength: Float, magnify: Float, aberration: Float, lightAngle: Float
    var rim: Float, backlight: Float, frost: Float, ior: Float
    var hasBackdrop: Float
    var pad0: Float = 0
    /// Captured area in panel points (origin, size).
    var srcOrigin: SIMD2<Float> = .zero
    var srcSize: SIMD2<Float> = .one
    var pad1: SIMD2<Float> = .zero
}

private struct ShaderShape {
    var center: SIMD2<Float>
    var halfSize: SIMD2<Float>
    var radii: SIMD4<Float>
    var rotation: Float
    var pad: SIMD3<Float> = .zero
}

private struct ShaderGroup {
    var bounds: SIMD4<Float>
    var tint: SIMD4<Float>
    var start: UInt32
    var count: UInt32
    var backing: Float
    var blend: Float
    var frost: Float
    var pad0: Float = 0, pad1: Float = 0, pad2: Float = 0
}

@MainActor
final class OpticalGlassRenderer: NSObject, MTKViewDelegate {
    let device = MTLCreateSystemDefaultDevice()
    var shapes: [GlassShapeInfo] = []
    var appearance = GlassAppearance()

    private let queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    private static let log = Logger(subsystem: "com.aircompass.AirCompass", category: "Optics")
    /// Liquid neck width where merged glass meets, pt.
    private static let blend: Float = 14
    /// setFragmentBytes is capped at 4 KB.
    private static let maxShapes = 80

    override init() {
        // Must equal the Metal structs' sizes (float3 is 16-byte aligned there).
        assert(MemoryLayout<ShaderUniforms>.stride == 96)
        assert(MemoryLayout<ShaderShape>.stride == 64)
        assert(MemoryLayout<ShaderGroup>.stride == 64)
        queue = device?.makeCommandQueue()
        pipeline = device.flatMap(Self.makePipeline)
        super.init()
        if let device { CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache) }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline, let queue, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }
        defer {
            encoder.endEncoding()
            buffer.present(drawable)
            buffer.commit()
        }

        let (gpuShapes, groups) = Self.pack(shapes, backing: Float(appearance.background) * 0.62, frost: Float(appearance.optics.frost))
        guard !groups.isEmpty else { return }

        let backdrop = OpticalGlassEngine.shared.isReady ? OpticalGlassEngine.shared.capture.latest.flatMap(texture) : nil
        let o = appearance.optics
        var uniforms = ShaderUniforms(
            viewSize: SIMD2(Float(view.bounds.width), Float(view.bounds.height)),
            scale: Float(view.window?.backingScaleFactor ?? 2),
            groupCount: UInt32(groups.count),
            bevel: Float(o.bevel), dome: Float(o.dome), capBand: Float(o.capBand), thickness: Float(o.thickness),
            strength: Float(o.strength), magnify: Float(o.magnify), aberration: Float(o.aberration), lightAngle: Float(o.lightAngle),
            rim: Float(o.rim), backlight: Float(o.backlight), frost: Float(o.frost), ior: 1.5,
            hasBackdrop: backdrop == nil ? 0 : 1
        )
        if let rect = OpticalGlassEngine.shared.captureRect(in: view.window) {
            uniforms.srcOrigin = SIMD2(Float(rect.minX), Float(rect.minY))
            uniforms.srcSize = SIMD2(Float(rect.width), Float(rect.height))
        } else {
            uniforms.srcSize = uniforms.viewSize
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
        gpuShapes.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        groups.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
        if let backdrop { encoder.setFragmentTexture(CVMetalTextureGetTexture(backdrop), index: 0) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // Keep the IOSurface-backed texture alive until the GPU is done with it.
        if let backdrop {
            let retained = RetainedTexture(texture: backdrop)
            buffer.addCompletedHandler { _ in withExtendedLifetime(retained) {} }
        }
    }

    private func texture(_ pixels: CVPixelBuffer) -> CVMetalTexture? {
        guard let textureCache else { return nil }
        var texture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixels, nil, .bgra8Unorm,
                                                  CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels), 0, &texture)
        return texture
    }

    /// Shapes grouped for the shader: shapes sharing a merge key become one
    /// liquid body, drawn where its first shape sits in the stacking order.
    private static func pack(_ shapes: [GlassShapeInfo], backing: Float, frost: Float) -> ([ShaderShape], [ShaderGroup]) {
        var order: [String] = []
        var members: [String: [GlassShapeInfo]] = [:]
        for (i, shape) in shapes.prefix(maxShapes).enumerated() where shape.frame.width > 1 && shape.frame.height > 1 {
            let key = shape.mergeGroup ?? "#\(i)"
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(shape)
        }

        var gpuShapes: [ShaderShape] = []
        var groups: [ShaderGroup] = []
        for key in order {
            guard let list = members[key] else { continue }
            let start = UInt32(gpuShapes.count)
            var bounds = CGRect.null
            var tint = SIMD4<Float>.zero
            for shape in list {
                let f = shape.frame
                gpuShapes.append(ShaderShape(center: SIMD2(Float(f.midX), Float(f.midY)),
                                             halfSize: SIMD2(Float(f.width / 2), Float(f.height / 2)),
                                             radii: shape.radii, rotation: shape.rotation))
                // A rotated shape can reach its half-diagonal in any direction.
                let reach = shape.rotation == 0 ? f : f.insetBy(dx: -f.height / 2, dy: -f.width / 2)
                bounds = bounds.union(reach)
                if shape.tint.w > tint.w { tint = shape.tint }
            }
            bounds = bounds.insetBy(dx: -CGFloat(blend) - 2, dy: -CGFloat(blend) - 2)
            groups.append(ShaderGroup(bounds: SIMD4(Float(bounds.minX), Float(bounds.minY), Float(bounds.maxX), Float(bounds.maxY)),
                                      tint: tint, start: start, count: UInt32(list.count),
                                      backing: list.contains(where: \.legible) ? max(backing, 0.22)
                                          : list.contains(where: \.backed) ? backing : 0,
                                      blend: list.count > 1 ? blend : 0,
                                      frost: list.contains(where: \.legible) ? max(frost, 7) : frost))
        }
        return (gpuShapes, Array(groups.prefix(maxShapes)))
    }

    private static func makePipeline(_ device: MTLDevice) -> MTLRenderPipelineState? {
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "glass_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "glass_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            log.error("Optical glass shader failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

// MARK: - Shader

/// Caustic's optics per pixel: SDF shape → squircle bezel height → Snell's-law
/// displacement through `thickness` of glass, blended toward a dome, scaled by
/// `magnify`, split by `aberration`, softened by `frost`, then a Fresnel rim
/// lit from `lightAngle` with `backlight` on the far edge.
private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 position [[position]]; };

vertex VOut glass_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

struct Uniforms {
    float2 viewSize; float scale; uint groupCount;
    float bevel; float dome; float capBand; float thickness;
    float strength; float magnify; float aberration; float lightAngle;
    float rim; float backlight; float frost; float ior;
    float hasBackdrop; float pad0; float2 srcOrigin; float2 srcSize; float2 pad1;
};
struct Shape { float2 center; float2 halfSize; float4 radii; float rotation; float3 pad; };
struct Group { float4 bounds; float4 tint; uint start; uint count; float backing; float blend;
               float frost; float pad0; float pad1; float pad2; };

// Rounded box with per-corner radii (tl, tr, br, bl), y pointing down.
static float roundBox(float2 p, float2 b, float4 r) {
    float rr = p.x > 0.0 ? (p.y > 0.0 ? r.z : r.y) : (p.y > 0.0 ? r.w : r.x);
    rr = min(rr, min(b.x, b.y));
    float2 q = abs(p) - b + rr;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - rr;
}

static float shapeSDF(constant Shape &s, float2 p) {
    float2 d = p - s.center;
    float c = cos(s.rotation), sn = sin(s.rotation);
    d = float2(d.x * c + d.y * sn, -d.x * sn + d.y * c);
    return roundBox(d, s.halfSize, s.radii);
}

static float smin(float a, float b, float k) {
    if (k <= 0.0) return min(a, b);
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

static float groupSDF(constant Shape *shapes, Group g, float2 p) {
    float d = 1e9;
    for (uint i = 0; i < g.count; i++) {
        float di = shapeSDF(shapes[g.start + i], p);
        d = i == 0 ? di : smin(d, di, g.blend);
    }
    return d;
}

static uint nearestShape(constant Shape *shapes, Group g, float2 p) {
    uint best = g.start; float bd = 1e9;
    for (uint i = 0; i < g.count; i++) {
        float di = shapeSDF(shapes[g.start + i], p);
        if (di < bd) { bd = di; best = g.start + i; }
    }
    return best;
}

// Caustic's default bezel: a squircle height profile, 1 = full height.
static float squircle(float t) {
    float u = 1.0 - clamp(t, 0.0, 1.0);
    return sqrt(sqrt(max(0.0, 1.0 - u * u * u * u)));
}

// Sideways shift of a ray crossing `thickness` of glass at surface tilt `tilt`.
static float refractShift(float tilt, float eta, float thickness) {
    float s2 = eta * sin(tilt);
    if (abs(s2) >= 1.0) return 0.0;
    return thickness * tan(tilt - asin(s2));
}

static float3 sampleFrost(texture2d<float> tex, sampler smp, float2 pt, float frost, constant Uniforms &u) {
    float2 uv = (pt - u.srcOrigin) / u.srcSize;
    if (frost <= 0.05) return tex.sample(smp, uv).rgb;
    float2 grain = float2(frost * 1.41421356) / u.srcSize;
    float3 sum = 0.0; float w = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float k = (x == 0 ? 2.0 : 1.0) * (y == 0 ? 2.0 : 1.0);
            sum += tex.sample(smp, uv + float2(x, y) * grain).rgb * k;
            w += k;
        }
    }
    return sum / w;
}

fragment float4 glass_fragment(VOut in [[stage_in]],
                               constant Uniforms &u [[buffer(0)]],
                               constant Shape *shapes [[buffer(1)]],
                               constant Group *groups [[buffer(2)]],
                               texture2d<float> backdrop [[texture(0)]]) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float2 p = in.position.xy / u.scale;
    float eta = 1.0 / u.ior;
    float2 light = float2(cos(u.lightAngle * M_PI_F / 180.0), sin(u.lightAngle * M_PI_F / 180.0));
    float4 result = 0.0;

    for (uint gi = 0; gi < u.groupCount; gi++) {
        Group g = groups[gi];
        if (p.x < g.bounds.x || p.y < g.bounds.y || p.x > g.bounds.z || p.y > g.bounds.w) continue;
        float d = groupSDF(shapes, g, p);
        float coverage = clamp(0.5 - d * u.scale, 0.0, 1.0);
        if (coverage <= 0.0) continue;

        constant Shape &s = shapes[nearestShape(shapes, g, p)];
        float halfMin = max(min(s.halfSize.x, s.halfSize.y), 1.0);
        // Caustic's numbers are calibrated on a 250 pt lens; scale per shape.
        float k = clamp(halfMin / 125.0, 0.22, 1.5);
        float dist = max(-d, 0.0);

        float e = 0.5;
        float2 grad = float2(groupSDF(shapes, g, p + float2(e, 0)) - groupSDF(shapes, g, p - float2(e, 0)),
                             groupSDF(shapes, g, p + float2(0, e)) - groupSDF(shapes, g, p - float2(0, e)));
        float2 n = length(grad) > 1e-5 ? normalize(grad) : float2(0.0);

        // Bezel: band in from the rim, wider at capsule ends (cap band).
        float band = max(min(u.bevel * k, halfMin) * (1.0 + (u.capBand - 1.0) * abs(n.x)), 0.5);
        band = min(band, halfMin);
        float t = clamp(dist / band, 0.0, 1.0);
        float t0 = max(t - 0.002, 0.0), t1 = min(t + 0.002, 1.0);
        float slope = (squircle(t1) - squircle(t0)) / max(t1 - t0, 1e-4);
        float tilt = atan(abs(slope));
        float thickness = u.thickness * k;
        float2 bend = n * min(refractShift(tilt, eta, thickness), halfMin);

        // Dome: a spherical bulge over the whole face.
        float2 rel = p - s.center;
        float r = length(rel);
        if (u.dome > 0.0 && r > 1e-3) {
            float domeTilt = atan(r / halfMin * 0.9);
            float2 radial = rel / r;
            bend = mix(bend, radial * min(refractShift(domeTilt, eta, thickness), halfMin), u.dome);
            tilt = mix(tilt, domeTilt, u.dome);
            float2 mixed = mix(n, radial, u.dome);
            if (length(mixed) > 1e-4) n = normalize(mixed);
        }
        bend *= u.strength;
        float reach = length(bend);
        if (reach > halfMin) bend *= halfMin / reach;

        // Magnify about the lens center, then bend.
        float2 at = s.center + rel / max(u.magnify, 0.05) + bend;

        float3 colour;
        if (u.hasBackdrop > 0.5) {
            float2 split = bend * u.aberration;
            float splitPx = length(split) * u.scale;
            if (splitPx > 6.0) split *= 6.0 / splitPx;
            if (splitPx < 0.25) {
                colour = sampleFrost(backdrop, smp, at, g.frost, u);
            } else {
                colour.r = sampleFrost(backdrop, smp, at - split, g.frost, u).r;
                colour.g = sampleFrost(backdrop, smp, at, g.frost, u).g;
                colour.b = sampleFrost(backdrop, smp, at + split, g.frost, u).b;
            }
        } else {
            colour = float3(0.5);
        }

        // Fresnel rim, brightest on the edge facing the light.
        float facing = dot(n, -light);
        float lit = facing > 0.0 ? facing : -facing * u.backlight;
        float edge = exp(-(dist * dist) / (2.0 * 1.6 * 1.6));
        float c = clamp(cos(tilt), 0.0, 1.0);
        float fresnel = 0.04 + 0.96 * pow(1.0 - c, 5.0);
        float spec = u.rim * edge * lit * mix(0.45, 1.0, fresnel);
        float sheen = 0.08 * u.rim * (1.0 - t) * max(facing, 0.0);
        colour += (spec + sheen) * mix(float3(1.0), colour, 0.35);

        colour = mix(colour, g.tint.rgb, g.tint.w);
        colour *= 1.0 - g.backing;
        float alpha = u.hasBackdrop > 0.5 ? 1.0 : 0.10 + spec;
        result = float4(colour * alpha, alpha) * coverage + result * (1.0 - coverage * alpha);
    }
    return result;
}
"""
