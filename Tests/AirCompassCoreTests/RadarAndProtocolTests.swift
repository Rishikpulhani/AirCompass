@testable import AirCompassCore
import Foundation
import Testing

private func peer(_ id: String, _ degrees: Double) -> PeerDevice {
    var p = PeerDevice(id: id, name: id, deviceKind: .iPhone, azimuthDegrees: degrees, hasPosition: true)
    p.smoothedAzimuthDegrees = degrees
    return p
}

struct CircularEMATests {
    @Test func wrapsThroughNorthNotSouth() {
        var ema = CircularEMA(alpha: 0.28)
        #expect(abs(ema.update(355) - 355) < 1e-9)
        for _ in 0..<40 {
            let v = ema.update(5)
            // Every intermediate value stays within the short arc 355°…5°.
            #expect(AngleMath.distance(AngleMath.radians(v), 0) <= AngleMath.radians(5.0001))
        }
        #expect(abs(AngleMath.signedDifferenceDegrees(ema.value!, 5)) < 0.01)
    }

    @Test func firstStepWeightsByAlpha() {
        var ema = CircularEMA(alpha: 0.28)
        ema.update(355)
        let v = ema.update(5)
        // Unit-vector blend of 355° and 5° at α = 0.28 lands just past 357.8°.
        #expect(abs(AngleMath.signedDifferenceDegrees(v, 357.8)) < 0.1)
    }

    @Test func reverseDirectionAlsoWraps() {
        var ema = CircularEMA(alpha: 0.5)
        ema.update(5)
        let v = ema.update(355)
        #expect(abs(AngleMath.signedDifferenceDegrees(v, 0)) < 1e-6)
    }
}

struct SectorDegreeTests {
    @Test(arguments: [
        (SectorMode.four, 0.0, 0), (.four, 89.0, 1), (.four, 225.1, 3), (.four, 359.0, 0),
        (.six, 59.0, 1), (.six, 150.1, 3), (.six, 331.0, 0),
        (.eight, 44.0, 1), (.eight, 200.0, 4), (.eight, 290.0, 6),
    ])
    func quantizesDegrees(mode: SectorMode, degrees: Double, expected: Int) {
        #expect(mode.sector(forDegrees: degrees) == expected)
    }

    @Test func centersAndWidths() {
        #expect(SectorMode.six.widthDegrees == 60)
        #expect(SectorMode.eight.centerDegrees(of: 3) == 135)
    }
}

struct RadarLayoutTests {
    @Test func lonePeerKeepsTrueBearing() {
        var peers = [peer("a", 73)]
        RadarLayout.apply(to: &peers, mode: .four)
        #expect(peers[0].assignedSector == 1)
        #expect(peers[0].displayAzimuthDegrees == 73)
    }

    @Test func twoPeersInOneSectorFanOutSymmetrically() {
        var peers = [peer("phone", 100), peer("pad", 80)]
        RadarLayout.apply(to: &peers, mode: .four)
        #expect(peers.allSatisfy { $0.assignedSector == 1 })
        // Ordered by true bearing: pad (80°) left of phone (100°), ±14° about 90°.
        #expect(abs(peers[1].displayAzimuthDegrees - 76) < 1e-9)
        #expect(abs(peers[0].displayAzimuthDegrees - 104) < 1e-9)
    }

    @Test func clusterAcrossNorthStaysAroundZero() {
        var peers = [peer("a", 350), peer("b", 10)]
        RadarLayout.apply(to: &peers, mode: .four)
        #expect(peers.allSatisfy { $0.assignedSector == 0 })
        #expect(abs(peers[0].displayAzimuthDegrees - 346) < 1e-9)
        #expect(abs(peers[1].displayAzimuthDegrees - 14) < 1e-9)
    }

    @Test func crowdedNarrowSectorShrinksSpacing() {
        var peers = [peer("a", 85), peer("b", 90), peer("c", 95)]
        RadarLayout.apply(to: &peers, mode: .eight) // 45° sectors, center 90°
        let display = peers.map(\.displayAzimuthDegrees).sorted()
        // Spacing = min(28, 45·0.8/2) = 18°.
        #expect(display.map { ($0 * 1e6).rounded() / 1e6 } == [72, 90, 108])
    }

    @Test func peersWithoutPositionAreIgnored() {
        var peers = [peer("a", 10), PeerDevice(id: "b", name: "b", deviceKind: .iPad)]
        RadarLayout.apply(to: &peers, mode: .four)
        #expect(peers[0].displayAzimuthDegrees == 10)
    }
}

struct DockMagnificationTests {
    let spread = DockMagnification.spread(for: .four)

    @Test func peakAtExactAlignmentAndFullPull() {
        #expect(abs(DockMagnification.scale(theta: 1, r: 0.2, phi: 1, spread: spread) - 1.82) < 1e-12)
    }

    @Test func noMagnificationWithoutPull() {
        #expect(DockMagnification.scale(theta: 1, r: 0, phi: 1, spread: spread) == 1)
    }

    @Test func zeroOutsideSpread() {
        #expect(DockMagnification.scale(theta: 0, r: 1, phi: spread * 1.01, spread: spread) == 1)
        #expect(abs(DockMagnification.scale(theta: 0, r: 1, phi: spread, spread: spread) - 1) < 1e-12)
    }

    @Test func halfwayValues() {
        // cos²(π/4) = 0.5 → 1 + 0.82·0.5
        #expect(abs(DockMagnification.scale(theta: 0, r: 1, phi: spread / 2, spread: spread) - 1.41) < 1e-12)
        // α = 0.5 at r = r_active / 2
        #expect(abs(DockMagnification.scale(theta: 0, r: 0.05, phi: 0, spread: spread, activeRadius: 0.1) - 1.41) < 1e-12)
    }

    @Test func wrapsAcrossNorth() {
        let a = DockMagnification.scale(theta: AngleMath.radians(355), r: 1, phi: AngleMath.radians(5), spread: spread)
        let b = DockMagnification.scale(theta: AngleMath.radians(5), r: 1, phi: AngleMath.radians(15), spread: spread)
        #expect(abs(a - b) < 1e-12)
    }

    @Test func targetIsMostMagnifiedInSector() {
        var peers = [peer("phone", 100), peer("pad", 80), peer("mac", 270)]
        RadarLayout.apply(to: &peers, mode: .four)
        let theta = AngleMath.radians(100)
        let scales = DockMagnification.scales(for: peers, theta: theta, r: 0.2, mode: .four)
        #expect(DockMagnification.target(in: peers, scales: scales, sector: 1)?.id == "phone")
        #expect(DockMagnification.target(in: peers, scales: scales, sector: 3) == nil)
    }
}

struct WireProtocolTests {
    static let frames: [WireFrame] = [
        .hello(PeerHelloFrame(peerID: "A", name: "rishik’s MacBook Air", kind: .mac, wantsAcousticProbes: true, sectorMode: .six)),
        .position(PositionUpdateFrame(peerID: "B", azimuthDegrees: 123.5, distanceMeters: 1.2, source: .acoustic, confidence: 9)),
        .gestureMirror(GestureMirrorFrame(senderID: "A", r: 0.14, theta: 1.2, isActive: true, isArmed: true, isCommitted: false,
                                          targetPeerID: "B", fileNames: ["a.pdf"], peerScales: ["B": 1.7], sectorMode: .four)),
        .transferHeader(TransferHeaderFrame(transferID: UUID(), senderID: "A", senderName: "Mac", senderKind: .mac,
                                            senderRelativeAzimuthDegrees: 90, files: [TransferFileInfo(name: "x", size: 3, sha256: "ab")],
                                            thumbnail: Data([1, 2, 3]))),
        .transferChunk(TransferChunkFrame(transferID: UUID(), fileIndex: 7, offset: 0x1_0000_0001, data: Data((0..<300).map { UInt8($0 % 256) }))),
        .transferAck(TransferAckFrame(transferID: UUID(), status: .completed, bytesReceived: 42)),
        .acousticProbe(AcousticProbeFrame(probeID: UUID(), emitterID: "A", leadInSeconds: 0.5, slotGapSeconds: 0.06,
                                          chirp: .standard, speakerSpacingMeters: 0.27)),
        .acousticProbeRequest(AcousticProbeRequestFrame(peerID: "B")),
    ]

    @Test(arguments: frames)
    func roundTrips(frame: WireFrame) throws {
        var decoder = FrameDecoder()
        decoder.append(try FrameCodec.encode(frame))
        #expect(try decoder.next() == frame)
        #expect(try decoder.next() == nil)
    }

    @Test func decodesByteByByteStream() throws {
        var stream = Data()
        for frame in Self.frames { stream.append(try FrameCodec.encode(frame)) }
        var decoder = FrameDecoder()
        var decoded: [WireFrame] = []
        for byte in stream {
            decoder.append(Data([byte]))
            while let f = try decoder.next() { decoded.append(f) }
        }
        #expect(decoded == Self.frames)
    }

    @Test func chunkHeaderIsCompactBinary() throws {
        let chunk = TransferChunkFrame(transferID: UUID(), fileIndex: 0, offset: 0, data: Data(count: WireProtocol.chunkSize))
        let encoded = try FrameCodec.encode(.transferChunk(chunk))
        #expect(encoded.count == 5 + 28 + WireProtocol.chunkSize)
    }

    @Test func skipsUnknownFrameTypes() throws {
        var decoder = FrameDecoder()
        decoder.append(Data([99, 0, 0, 0, 2, 0xAA, 0xBB]))
        let known = WireFrame.acousticProbeRequest(AcousticProbeRequestFrame(peerID: "P"))
        decoder.append(try FrameCodec.encode(known))
        #expect(try decoder.next() == known)
    }

    @Test func rejectsOversizedLength() {
        var decoder = FrameDecoder()
        decoder.append(Data([1, 0xFF, 0xFF, 0xFF, 0xFF]))
        #expect(throws: FrameCodecError.self) { try decoder.next() }
    }
}

struct AcousticDSPTests {
    let rate = 48_000.0
    let gap = 0.06
    let spacing = 0.27

    /// Synthesizes what a listener hears: both chirps with a given extra delay
    /// on the right one, plus deterministic noise.
    func recording(rightDelaySamples: Int, noise: Float = 0.02, leftAt: Int = 9_000) -> [Float] {
        let chirp = AcousticDSP.chirp(.standard, sampleRate: rate)
        var signal = [Float](repeating: 0, count: 24_000)
        var seed: UInt32 = 12345
        for i in signal.indices {
            seed = seed &* 1_103_515_245 &+ 12345
            signal[i] = (Float(seed >> 16) / 32768 - 1) * noise
        }
        let rightAt = leftAt + Int(gap * rate) + rightDelaySamples
        for (i, v) in chirp.enumerated() {
            signal[leftAt + i] += v * 0.3
            signal[rightAt + i] += v * 0.3
        }
        return signal
    }

    func expectedLateral(delaySamples: Int) -> Double {
        let d = Double(delaySamples) / rate * AcousticDSP.speedOfSound
        return AngleMath.degrees(asin(-d / spacing))
    }

    @Test(arguments: [0, -19, 19, -30, 12])
    func recoversLateralAngle(delay: Int) throws {
        let est = try #require(AcousticDSP.estimate(samples: recording(rightDelaySamples: delay), sampleRate: rate,
                                                    chirp: .standard, slotGapSeconds: gap, speakerSpacingMeters: spacing))
        #expect(abs(est.lateralDegrees - expectedLateral(delaySamples: delay)) < 2.5)
        #expect(est.confidence > AcousticDSP.minimumConfidence)
    }

    @Test func rightSideIsEast() throws {
        // Right chirp arrives early → listener is to the right (positive lateral).
        let est = try #require(AcousticDSP.estimate(samples: recording(rightDelaySamples: -19), sampleRate: rate,
                                                    chirp: .standard, slotGapSeconds: gap, speakerSpacingMeters: spacing))
        #expect(est.lateralDegrees > 20)
    }

    @Test func pureNoiseYieldsNoFix() {
        var seed: UInt32 = 99
        let noise = (0..<24_000).map { _ -> Float in
            seed = seed &* 1_103_515_245 &+ 12345
            return (Float(seed >> 16) / 32768 - 1) * 0.05
        }
        #expect(AcousticDSP.estimate(samples: noise, sampleRate: rate, chirp: .standard,
                                     slotGapSeconds: gap, speakerSpacingMeters: spacing) == nil)
    }

    @Test func hemisphereMapsToBearing() {
        #expect(AcousticDSP.bearing(lateralDegrees: 30, hemisphere: .beyondScreen) == 30)
        #expect(AcousticDSP.bearing(lateralDegrees: -30, hemisphere: .beyondScreen) == 330)
        #expect(AcousticDSP.bearing(lateralDegrees: 30, hemisphere: .userSide) == 150)
        #expect(AcousticDSP.bearing(lateralDegrees: -30, hemisphere: .userSide) == 210)
    }

    @Test func stereoProbeLayout() {
        let probe = AcousticProbeFrame(probeID: UUID(), emitterID: "A", leadInSeconds: 0.5, slotGapSeconds: gap,
                                       chirp: .standard, speakerSpacingMeters: spacing)
        let (l, r) = AcousticDSP.stereoProbe(probe, sampleRate: rate)
        #expect(l.count == r.count)
        let firstL = l.firstIndex { $0 != 0 }!, firstR = r.firstIndex { $0 != 0 }!
        #expect(abs((firstR - firstL) - Int(gap * rate)) <= 1)
        #expect(abs(firstL - Int(0.5 * rate)) <= 1)
    }
}

@MainActor
struct SpatialRadarEngineTests {
    @Test func positionUpdatesSmoothAndAssignSectors() {
        let engine = SpatialRadarEngine(sectorMode: .four)
        engine.upsertPeer(id: "p", name: "Phone", kind: .iPhone)
        engine.updatePosition(id: "p", azimuthDegrees: 350, source: .manual)
        engine.updatePosition(id: "p", azimuthDegrees: 20, source: .manual)
        let p = engine.peer("p")!
        #expect(p.assignedSector == 0)
        #expect(p.rawAzimuthDegrees == 20)
        #expect(AngleMath.signedDifferenceDegrees(p.smoothedAzimuthDegrees, 350) > 0)
        #expect(AngleMath.signedDifferenceDegrees(p.smoothedAzimuthDegrees, 20) < 0)
    }

    @Test func sectorModeChangeRelayouts() {
        let engine = SpatialRadarEngine(sectorMode: .four)
        engine.upsertPeer(id: "p", name: "Phone", kind: .iPhone)
        engine.updatePosition(id: "p", azimuthDegrees: 50, source: .manual)
        #expect(engine.peer("p")!.assignedSector == 1)
        engine.sectorMode = .eight
        #expect(engine.peer("p")!.assignedSector == 1)
        engine.sectorMode = .six
        #expect(engine.peer("p")!.assignedSector == 1)
    }

    @Test func simulatedPeersSeedAndRemove() {
        let engine = SpatialRadarEngine()
        engine.seedSimulatedPeers()
        #expect(engine.positionedPeers.count == 2)
        engine.removeSimulatedPeers()
        #expect(engine.peers.isEmpty)
    }
}

struct AcousticBearingFilterTests {
    @Test func smallChangesBlendQuickly() {
        var f = AcousticBearingFilter()
        f.update(90)
        #expect(abs(f.update(100) - 96) < 1e-9)   // 60% of the way in one fix
    }

    @Test func singleOutlierIsIgnored() {
        var f = AcousticBearingFilter()
        f.update(90)
        #expect(f.update(270) == 90)
        #expect(abs(f.update(92) - 91.2) < 1e-9)
    }

    @Test func confirmedJumpSnapsImmediately() {
        var f = AcousticBearingFilter()
        f.update(80)
        #expect(f.update(280) == 80)               // held as pending
        #expect(abs(f.update(284) - 282) < 1e-9)   // confirmed: snap, not glide
    }

    @Test func jumpAcrossNorthConfirms() {
        var f = AcousticBearingFilter()
        f.update(120)
        f.update(355)
        #expect(abs(AngleMath.signedDifferenceDegrees(f.update(5), 0)) < 1e-9)
    }
}

@MainActor
struct EngineAcousticTests {
    @Test func acousticMoveSettlesInTwoFixes() {
        let engine = SpatialRadarEngine()
        engine.upsertPeer(id: "p", name: "Phone", kind: .iPhone)
        engine.updatePosition(id: "p", azimuthDegrees: 90, source: .acoustic)
        engine.updatePosition(id: "p", azimuthDegrees: 270, source: .acoustic)
        engine.updatePosition(id: "p", azimuthDegrees: 270, source: .acoustic)
        #expect(engine.peer("p")!.smoothedAzimuthDegrees == 270)
        #expect(engine.peer("p")!.assignedSector == 3)
    }
}
