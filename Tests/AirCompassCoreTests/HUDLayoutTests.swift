@testable import AirCompassCore
import Foundation
import Testing

private func device(_ id: String, _ degrees: Double? = nil, distance: Double? = nil) -> PeerDevice {
    var p = PeerDevice(id: id, name: id, deviceKind: .iPad, azimuthDegrees: degrees ?? 0,
                       distanceMeters: distance, hasPosition: degrees != nil)
    p.smoothedAzimuthDegrees = degrees ?? 0
    return p
}

private func rad(_ degrees: Double) -> Double { AngleMath.radians(degrees) }

struct TrackingModeTests {
    @Test func autoNeedsEveryDevicePositioned() {
        #expect(TrackingMode.auto.resolve(peers: []) == .uniform)
        #expect(TrackingMode.auto.resolve(peers: [device("a", 90)]) == .spatial)
        #expect(TrackingMode.auto.resolve(peers: [device("a", 90), device("b")]) == .uniform)
        #expect(TrackingMode.nonDirectional.resolve(peers: [device("a", 90)]) == .uniform)
        #expect(TrackingMode.spatial.resolve(peers: [device("b")]) == .spatial)
    }

    @Test func sixStylesWithCodes() {
        #expect(HUDStyle.allCases.map(\.code) == ["A1", "A2", "A3", "B1", "B2", "B3"])
        #expect(HUDStyle.allCases.filter { $0.family == .uniform }.count == 3)
    }
}

struct OrbitalHaloLayoutTests {
    @Test func evenAngles() {
        #expect(UniformLayout.orbitAngles(count: 0) == [])
        #expect(UniformLayout.orbitAngles(count: 1) == [0])
        #expect(UniformLayout.orbitAngles(count: 2) == [270, 90])
        #expect(UniformLayout.orbitAngles(count: 3) == [0, 120, 240])
        #expect(UniformLayout.orbitAngles(count: 4) == [0, 90, 180, 270])
    }

    @Test func pointingAtASlotMagnifiesIt() {
        let scales = UniformLayout.scales(style: .orbitalHalo, count: 4, theta: rad(90), r: 0.2)
        #expect(abs(scales[1] - DockMagnification.maxScale) < 1e-9)
        #expect(scales[3] == 1)
        #expect(UniformLayout.targetIndex(scales: scales) == 1)
    }

    @Test func noPullNoTarget() {
        let scales = UniformLayout.scales(style: .orbitalHalo, count: 3, theta: 0, r: 0)
        #expect(scales.allSatisfy { $0 == 1 })
        #expect(UniformLayout.targetIndex(scales: scales) == nil)
    }

    @Test func nodesIgnoreMeasuredBearings() {
        // Positioned or not, devices land on the even layout.
        let nodes = UniformLayout.nodes(for: [device("a", 45), device("b")], style: .orbitalHalo)
        #expect(nodes.map(\.displayAzimuthDegrees) == [270, 90])
    }
}

struct IslandCapsuleLayoutTests {
    @Test func balancedRow() {
        #expect(UniformLayout.rowPositions(count: 1) == [0])
        #expect(UniformLayout.rowPositions(count: 2) == [-1, 1])
        #expect(UniformLayout.rowPositions(count: 3) == [-1, 0, 1])
    }

    @Test func horizontalDragPicksSlot() {
        // Right and slightly down: rightmost of three.
        let right = UniformLayout.scales(style: .dynamicIslandCapsule, count: 3, theta: rad(100), r: 0.15)
        #expect(UniformLayout.targetIndex(scales: right) == 2)
        // Straight down: the middle one.
        let down = UniformLayout.scales(style: .dynamicIslandCapsule, count: 3, theta: rad(180), r: 0.15)
        #expect(UniformLayout.targetIndex(scales: down) == 1)
        // Left: the first.
        let left = UniformLayout.scales(style: .dynamicIslandCapsule, count: 3, theta: rad(250), r: 0.15)
        #expect(UniformLayout.targetIndex(scales: left) == 0)
    }

    @Test func pointerClampsToRow() {
        #expect(UniformLayout.rowPointer(theta: rad(90), r: 1) == 1)
        #expect(UniformLayout.rowPointer(theta: rad(270), r: 1) == -1)
        #expect(abs(UniformLayout.rowPointer(theta: rad(90), r: UniformLayout.rowReach / 2) - 0.5) < 1e-9)
    }

    @Test func nodesCarryRowPositions() {
        let nodes = UniformLayout.nodes(for: [device("a"), device("b"), device("c")], style: .dynamicIslandCapsule)
        #expect(nodes.map(\.rowPosition) == [-1, 0, 1])
    }
}

struct NotchFanLayoutTests {
    @Test func fanSpansLowerSemicircle() {
        #expect(UniformLayout.arcAngles(count: 1) == [180])
        #expect(UniformLayout.arcAngles(count: 2) == [225, 135])
        #expect(UniformLayout.arcAngles(count: 3) == [240, 180, 120])
        for angle in UniformLayout.arcAngles(count: 7) {
            #expect(angle > 90 && angle < 270)
        }
    }

    @Test func upwardDragClampsToFanEnds() {
        #expect(UniformLayout.arcPointer(theta: rad(30)) == 90)
        #expect(UniformLayout.arcPointer(theta: rad(330)) == 270)
        #expect(abs(UniformLayout.arcPointer(theta: rad(200)) - 200) < 1e-9)
    }

    @Test func diagonalDragTargetsSlot() {
        let scales = UniformLayout.scales(style: .notchHalfArc, count: 3, theta: rad(120), r: 0.2)
        #expect(UniformLayout.targetIndex(scales: scales) == 2)
        let left = UniformLayout.scales(style: .notchHalfArc, count: 3, theta: rad(300), r: 0.2)
        #expect(UniformLayout.targetIndex(scales: left) == 0)
    }
}

struct SpatialStyleLayoutTests {
    // B1 and B2 place nodes on the ring at the radar's display bearing.
    @Test func compassNodesUseDisplayBearing() {
        var peers = [device("a", 92), device("b", 200)]
        RadarLayout.apply(to: &peers, mode: .four)
        let nodes = peers.map { CompassNodeModel(peer: $0) }
        #expect(nodes.map(\.displayAzimuthDegrees) == [92, 200])
        #expect(nodes.map(\.labelDegrees) == [92, 200])
    }

    // B3 adds distance rings.
    @Test func sonarRadiusFollowsRings() {
        #expect(SonarLayout.radiusFraction(distanceMeters: nil) == 1)
        #expect(abs(SonarLayout.radiusFraction(distanceMeters: 0.5) - 1.0 / 3) < 1e-9)
        #expect(abs(SonarLayout.radiusFraction(distanceMeters: 1.5) - 2.0 / 3) < 1e-9)
        #expect(SonarLayout.radiusFraction(distanceMeters: 3) == 1)
        #expect(SonarLayout.radiusFraction(distanceMeters: 12) == 1)
        let one = SonarLayout.radiusFraction(distanceMeters: 1.0)
        #expect(one > 1.0 / 3 && one < 2.0 / 3)
        #expect(CompassNodeModel(peer: device("a", 10, distance: 1.2)).distanceMeters == 1.2)
    }

    @Test func bearingBadges() {
        #expect(BearingFormat.badge(92) == "092° · E")
        #expect(BearingFormat.badge(359.7) == "000° · N")
        #expect(BearingFormat.badge(225) == "225° · SW")
        #expect(BearingFormat.cardinal(-45) == "NW")
    }
}
