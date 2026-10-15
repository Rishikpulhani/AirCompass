@testable import AirCompassCore
import Foundation
import Testing

private func frame(_ t: Double, _ points: [(Double, Double)], aspect: Double = 1) -> TouchFrame {
    TouchFrame(
        timestamp: t,
        contacts: points.enumerated().map { TouchContact(id: Int32($0.offset), x: $0.element.0, y: $0.element.1) },
        aspectRatio: aspect
    )
}

/// Three fingers centered on (cx, cy).
private func three(_ t: Double, _ cx: Double, _ cy: Double, aspect: Double = 1) -> TouchFrame {
    frame(t, [(cx - 0.1, cy), (cx, cy + 0.02), (cx + 0.1, cy)], aspect: aspect)
}

private func began(_ r: inout ThreeFingerGestureRecognizer, at cx: Double = 0.5, _ cy: Double = 0.5) {
    #expect(r.process(three(0.000, cx, cy)) == nil)
    guard case .began = r.process(three(0.050, cx, cy)) else {
        Issue.record("expected .began")
        return
    }
}

struct AngleMathTests {
    @Test func bearingConvention() {
        #expect(AngleMath.bearing(dx: 0, dy: 1) == 0)
        #expect(abs(AngleMath.bearing(dx: 1, dy: 0) - .pi / 2) < 1e-12)
        #expect(abs(AngleMath.bearing(dx: 0, dy: -1) - .pi) < 1e-12)
        #expect(abs(AngleMath.bearing(dx: -1, dy: 0) - 3 * .pi / 2) < 1e-12)
    }

    @Test func shortestDistanceWraps() {
        #expect(abs(AngleMath.distance(AngleMath.radians(350), AngleMath.radians(10)) - AngleMath.radians(20)) < 1e-12)
        #expect(abs(AngleMath.distance(0, .pi) - .pi) < 1e-12)
    }

    @Test(arguments: [
        (SectorMode.four, 0.0, 0), (.four, 44.9, 0), (.four, 45.1, 1), (.four, 315.1, 0), (.four, 180, 2),
        (.six, 29.9, 0), (.six, 30.1, 1), (.six, 240, 4), (.six, 270, 5),
        (.eight, 22.4, 0), (.eight, 22.6, 1), (.eight, 337.6, 0), (.eight, 359.999, 0),
    ])
    func sectorQuantization(count: SectorMode, degrees: Double, expected: Int) {
        #expect(count.sector(for: AngleMath.radians(degrees)) == expected)
    }
}

struct ThreeFingerGestureRecognizerTests {
    @Test func settlesBeforeBeginning() {
        var r = ThreeFingerGestureRecognizer()
        #expect(r.process(three(0.00, 0.5, 0.5)) == nil)
        #expect(r.process(three(0.01, 0.5, 0.5)) == nil)
        #expect(r.process(three(0.04, 0.5, 0.5)) == .began(origin: TouchPoint(x: 0.5, y: 0.5 + 0.02 / 3)))
    }

    @Test func transientThreeOnWayToFourIsIgnored() {
        var r = ThreeFingerGestureRecognizer()
        _ = r.process(three(0.00, 0.5, 0.5))
        let four = frame(0.01, [(0.2, 0.5), (0.4, 0.5), (0.6, 0.5), (0.8, 0.5)])
        #expect(r.process(four) == nil)
        // Lifting back to three (end of a 4-finger swipe) must not start a gesture.
        #expect(r.process(three(0.10, 0.5, 0.5)) == nil)
        #expect(r.process(three(0.20, 0.5, 0.5)) == nil)
        #expect(r.phase == .idle)
    }

    @Test func dragEastProducesNinetyDegrees() throws {
        var r = ThreeFingerGestureRecognizer()
        began(&r)
        guard case let .changed(v, armed) = r.process(three(0.06, 0.55, 0.5)) else {
            Issue.record("expected .changed"); return
        }
        #expect(abs(v.r - 0.05) < 1e-9)
        #expect(abs(v.theta - .pi / 2) < 1e-9)
        #expect(!armed)
    }

    @Test func aspectRatioScalesHorizontalTravel() {
        var r = ThreeFingerGestureRecognizer()
        #expect(r.process(three(0.00, 0.5, 0.5, aspect: 1.6)) == nil)
        _ = r.process(three(0.05, 0.5, 0.5, aspect: 1.6))
        // Equal normalized Δx and Δy on a 1.6:1 pad is physically ~58°, not 45°.
        guard case let .changed(v, _) = r.process(three(0.06, 0.55, 0.55, aspect: 1.6)) else {
            Issue.record("expected .changed"); return
        }
        #expect(abs(AngleMath.degrees(v.theta) - AngleMath.degrees(atan2(1.6, 1))) < 1e-6)
    }

    @Test func releaseAboveThresholdCommitsLastThreeFingerVector() {
        var r = ThreeFingerGestureRecognizer(sectorMode: .four)
        began(&r)
        _ = r.process(three(0.10, 0.5, 0.30)) // pull South, r = 0.2
        // First finger lifts: centroid jumps, but the commit uses the prior vector.
        let event = r.process(frame(0.12, [(0.9, 0.9), (0.9, 0.9)]))
        guard case let .committed(commit) = event else {
            Issue.record("expected .committed, got \(String(describing: event))"); return
        }
        #expect(commit.sector == 2)
        #expect(abs(commit.vector.r - 0.2) < 1e-9)
        #expect(abs(commit.duration - 0.07) < 1e-9)
        #expect(r.process(frame(0.13, [(0.9, 0.9)])) == nil)
        #expect(r.process(frame(0.14, [])) == nil)
        #expect(r.phase == .idle)
    }

    @Test func releaseBelowThresholdCancels() {
        var r = ThreeFingerGestureRecognizer()
        began(&r)
        _ = r.process(three(0.10, 0.52, 0.5))
        #expect(r.process(frame(0.12, [])) == .cancelled(.releasedBelowThreshold))
    }

    @Test func armingHasHysteresis() {
        var config = ThreeFingerGestureRecognizer.Configuration()
        config.commitRadius = 0.10
        config.disarmRatio = 0.8
        var r = ThreeFingerGestureRecognizer(configuration: config)
        began(&r)
        if case let .changed(_, armed) = r.process(three(0.1, 0.5, 0.5 + 0.11)) { #expect(armed) } else { Issue.record("expected .changed") }
        // 0.09 is below commit radius but above the 0.08 disarm line: stays armed.
        if case let .changed(_, armed) = r.process(three(0.2, 0.5, 0.5 + 0.09)) { #expect(armed) }
        if case let .changed(_, armed) = r.process(three(0.3, 0.5, 0.5 + 0.07)) { #expect(!armed) }
    }

    @Test func fourthFingerCancels() {
        var r = ThreeFingerGestureRecognizer()
        began(&r)
        let four = frame(0.1, [(0.2, 0.5), (0.4, 0.5), (0.6, 0.5), (0.8, 0.5)])
        #expect(r.process(four) == .cancelled(.extraFingers))
        #expect(r.process(three(0.2, 0.5, 0.5)) == nil)
        #expect(r.process(three(0.3, 0.5, 0.5)) == nil)
    }

    @Test func suppressionIgnoresRestOfGesture() {
        var r = ThreeFingerGestureRecognizer()
        began(&r)
        #expect(r.suppress() == .cancelled(.suppressed))
        #expect(r.process(three(0.1, 0.5, 0.9)) == nil)
        #expect(r.process(frame(0.2, [])) == nil)
        // A fresh touch starts a new gesture.
        began(&r)
    }
}

struct MultitouchFrameworkTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/System/Library/PrivateFrameworks/MultitouchSupport.framework")))
    func requiredSymbolsResolve() throws {
        let fw = try MultitouchFramework.shared.get()
        #expect(fw.isBuiltIn != nil)
        #expect(fw.surfaceDimensions != nil)
    }
}
