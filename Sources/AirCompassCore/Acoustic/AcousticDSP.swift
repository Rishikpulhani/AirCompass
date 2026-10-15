import Accelerate
import Foundation

/// Linear frequency sweep used as the ranging ping. 17–20 kHz is near the top
/// of human hearing, still reproduced by laptop speakers and captured at 48 kHz.
public struct ChirpSpec: Codable, Sendable, Equatable {
    public var startHz: Double
    public var endHz: Double
    public var durationSeconds: Double
    public var amplitude: Double

    public static let standard = ChirpSpec(startHz: 17_000, endHz: 20_000, durationSeconds: 0.012, amplitude: 0.9)

    public init(startHz: Double, endHz: Double, durationSeconds: Double, amplitude: Double) {
        self.startHz = startHz
        self.endHz = endHz
        self.durationSeconds = durationSeconds
        self.amplitude = amplitude
    }
}

/// Which side of the emitter's screen the listener is on. Two speakers can
/// tell left from right but not front from back, so the user picks this once.
public enum AcousticHemisphere: String, Codable, Sendable, CaseIterable {
    /// North half: beyond the emitter's display, away from its user.
    case beyondScreen
    /// South half: on the emitter user's side of the display.
    case userSide

    public var title: String {
        switch self {
        case .beyondScreen: "Beyond the Mac's screen"
        case .userSide: "On the Mac user's side"
        }
    }
}

public struct AcousticEstimate: Sendable, Equatable {
    /// Angle off the emitter's forward axis; positive = East (right).
    public var lateralDegrees: Double
    /// distance(right speaker) − distance(left speaker), metres.
    public var pathDifferenceMeters: Double
    /// Weaker of the two correlation peaks divided by the noise floor.
    public var confidence: Double
}

/// Signal processing for stereo-chirp direction finding.
///
/// The emitter plays the chirp from its left speaker, then (after a fixed gap)
/// from its right speaker. A listener off to the right hears the right chirp
/// slightly early relative to the gap; that offset Δt gives the path
/// difference d = c·Δt and the lateral angle asin(−d / speakerSpacing).
public enum AcousticDSP {
    public static let speedOfSound = 343.0
    public static let minimumConfidence = 5.0

    public static func chirp(_ spec: ChirpSpec, sampleRate: Double) -> [Float] {
        let n = max(1, Int(spec.durationSeconds * sampleRate))
        let t1 = spec.durationSeconds
        let k = (spec.endHz - spec.startHz) / t1
        return (0..<n).map { i in
            let t = Double(i) / sampleRate
            let phase = 2 * Double.pi * (spec.startHz * t + 0.5 * k * t * t)
            let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(max(n - 1, 1)))
            return Float(spec.amplitude * window * sin(phase))
        }
    }

    /// |cross-correlation| of `signal` with `template`, one value per lag.
    public static func correlationMagnitude(_ signal: [Float], _ template: [Float]) -> [Float] {
        guard signal.count >= template.count, !template.isEmpty else { return [] }
        let outCount = signal.count - template.count + 1
        var out = [Float](repeating: 0, count: outCount)
        signal.withUnsafeBufferPointer { s in
            template.withUnsafeBufferPointer { t in
                out.withUnsafeMutableBufferPointer { o in
                    // With a positive filter stride vDSP_conv computes correlation.
                    vDSP_conv(s.baseAddress!, 1, t.baseAddress!, 1, o.baseAddress!, 1,
                              vDSP_Length(outCount), vDSP_Length(template.count))
                }
            }
        }
        vDSP_vabs(out, 1, &out, 1, vDSP_Length(outCount))
        return out
    }

    public static func estimate(
        samples: [Float],
        sampleRate: Double,
        chirp spec: ChirpSpec,
        slotGapSeconds: Double,
        speakerSpacingMeters: Double
    ) -> AcousticEstimate? {
        let template = chirp(spec, sampleRate: sampleRate)
        let corr = correlationMagnitude(samples, template)
        guard corr.count > 16 else { return nil }

        let noise = max(noiseFloor(corr), 1e-9)
        let gap = slotGapSeconds * sampleRate
        let maxLag = Int(speakerSpacingMeters / speedOfSound * sampleRate) + 8
        let earlyWindow = Int(0.002 * sampleRate)

        guard let strongest = argmax(corr, in: 0..<corr.count) else { return nil }

        // The strongest peak is one of the two chirps. Try it as left and as
        // right and keep whichever pairing finds the stronger partner.
        func partner(near expected: Double) -> Int? {
            let center = Int(expected.rounded())
            let lo = max(0, center - maxLag), hi = min(corr.count, center + maxLag + 1)
            return lo < hi ? argmax(corr, in: lo..<hi) : nil
        }
        let asLeft = partner(near: Double(strongest) + gap).map { (left: strongest, right: $0) }
        let asRight = partner(near: Double(strongest) - gap).map { (left: $0, right: strongest) }
        let pairs = [asLeft, asRight].compactMap { $0 }
        guard var pair = pairs.max(by: { min(corr[$0.left], corr[$0.right]) < min(corr[$1.left], corr[$1.right]) })
        else { return nil }

        // Reflections can be louder than the direct path; prefer the earliest
        // strong arrival shortly before each peak.
        pair.left = earliestArrival(corr, peak: pair.left, window: earlyWindow)
        pair.right = earliestArrival(corr, peak: pair.right, window: earlyWindow)

        let confidence = Double(min(corr[pair.left], corr[pair.right])) / Double(noise)
        guard confidence >= minimumConfidence else { return nil }

        let tLeft = Double(pair.left) + parabolicOffset(corr, pair.left)
        let tRight = Double(pair.right) + parabolicOffset(corr, pair.right)
        let deltaSamples = (tRight - tLeft) - gap
        let pathDifference = deltaSamples / sampleRate * speedOfSound
        let ratio = min(max(-pathDifference / speakerSpacingMeters, -1), 1)
        return AcousticEstimate(
            lateralDegrees: AngleMath.degrees(asin(ratio)),
            pathDifferenceMeters: pathDifference,
            confidence: confidence
        )
    }

    /// Converts a lateral angle plus the user-chosen hemisphere to a bearing.
    public static func bearing(lateralDegrees: Double, hemisphere: AcousticHemisphere) -> Double {
        switch hemisphere {
        case .beyondScreen: AngleMath.normalizeDegrees(lateralDegrees)
        case .userSide: AngleMath.normalizeDegrees(180 - lateralDegrees)
        }
    }

    // MARK: Helpers

    static func argmax(_ values: [Float], in range: Range<Int>) -> Int? {
        guard !range.isEmpty else { return nil }
        var best = range.lowerBound
        for i in range where values[i] > values[best] { best = i }
        return best
    }

    /// Median of a strided subsample: robust to the two chirp peaks.
    static func noiseFloor(_ values: [Float]) -> Float {
        let stride = max(1, values.count / 4096)
        var sample = Swift.stride(from: 0, to: values.count, by: stride).map { values[$0] }
        sample.sort()
        return sample[sample.count / 2]
    }

    static func earliestArrival(_ corr: [Float], peak: Int, window: Int) -> Int {
        let threshold = corr[peak] * 0.5
        let lo = max(1, peak - window)
        guard lo < peak else { return peak }
        for i in lo..<peak where corr[i] >= threshold && corr[i] >= corr[i - 1] && corr[i] >= corr[i + 1] {
            return i
        }
        return peak
    }

    /// Sub-sample peak refinement by fitting a parabola through three points.
    static func parabolicOffset(_ corr: [Float], _ i: Int) -> Double {
        guard i > 0, i < corr.count - 1 else { return 0 }
        let a = Double(corr[i - 1]), b = Double(corr[i]), c = Double(corr[i + 1])
        let denom = a - 2 * b + c
        guard abs(denom) > 1e-12 else { return 0 }
        return min(max(0.5 * (a - c) / denom, -0.5), 0.5)
    }

    /// Builds the stereo emission: lead-in silence, left chirp on channel 0,
    /// right chirp on channel 1 one slot later, then a short tail.
    public static func stereoProbe(_ probe: AcousticProbeFrame, sampleRate: Double) -> (left: [Float], right: [Float]) {
        let tone = chirp(probe.chirp, sampleRate: sampleRate)
        let leftStart = Int(probe.leadInSeconds * sampleRate)
        let rightStart = leftStart + Int((probe.slotGapSeconds * sampleRate).rounded())
        let total = rightStart + tone.count + Int(0.05 * sampleRate)
        var left = [Float](repeating: 0, count: total)
        var right = [Float](repeating: 0, count: total)
        left.replaceSubrange(leftStart..<(leftStart + tone.count), with: tone)
        right.replaceSubrange(rightStart..<(rightStart + tone.count), with: tone)
        return (left, right)
    }
}
