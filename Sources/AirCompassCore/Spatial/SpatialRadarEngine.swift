import Foundation
import Observation

/// Tracks every nearby peer's position around this device.
///
/// Positions arrive as `PositionUpdateFrame`s (acoustic, manual dial, motion)
/// or from simulation. Each bearing runs through a circular EMA, is quantized
/// to a sector, and peers sharing a sector are fanned out for display.
@MainActor
@Observable
public final class SpatialRadarEngine {
    public var sectorMode: SectorMode {
        didSet { relayout() }
    }

    /// Sorted by name for stable menus.
    public private(set) var peers: [PeerDevice] = []
    public private(set) var isOrbiting = false

    @ObservationIgnored private var filters: [String: CircularEMA] = [:]
    @ObservationIgnored private var acousticFilters: [String: AcousticBearingFilter] = [:]
    @ObservationIgnored private var orbitTask: Task<Void, Never>?
    @ObservationIgnored public var emaAlpha = 0.28

    public init(sectorMode: SectorMode = .four) {
        self.sectorMode = sectorMode
    }

    public func peer(_ id: String) -> PeerDevice? { peers.first { $0.id == id } }

    public var positionedPeers: [PeerDevice] { peers.filter(\.hasPosition) }

    // MARK: - Membership

    public func upsertPeer(id: String, name: String, kind: DeviceKind, isSimulated: Bool = false) {
        if let i = peers.firstIndex(where: { $0.id == id }) {
            peers[i].name = name
            peers[i].deviceKind = kind
            peers[i].isConnected = true
        } else {
            peers.append(PeerDevice(id: id, name: name, deviceKind: kind, isSimulated: isSimulated,
                                    positionSource: isSimulated ? .simulated : .unknown))
        }
        relayout()
    }

    public func removePeer(id: String) {
        peers.removeAll { $0.id == id }
        filters[id] = nil
        acousticFilters[id] = nil
        relayout()
    }

    // MARK: - Positions

    public func updatePosition(
        id: String,
        azimuthDegrees: Double,
        distanceMeters: Double? = nil,
        source: PositionSource,
        smooth: Bool = true
    ) {
        guard let i = peers.firstIndex(where: { $0.id == id }) else { return }
        let raw = AngleMath.normalizeDegrees(azimuthDegrees)

        // A switch of source (e.g. manual → acoustic) shouldn't glide from a stale angle.
        if peers[i].positionSource != source || !smooth {
            filters[id]?.reset()
            acousticFilters[id]?.reset()
        }
        let smoothed: Double
        if source == .acoustic {
            // Sparse fixes: fast blend + confirmed jumps instead of a slow EMA.
            var filter = acousticFilters[id] ?? AcousticBearingFilter()
            smoothed = filter.update(raw)
            acousticFilters[id] = filter
        } else {
            var filter = filters[id] ?? CircularEMA(alpha: emaAlpha)
            smoothed = filter.update(raw)
            filters[id] = filter
        }

        peers[i].rawAzimuthDegrees = raw
        peers[i].smoothedAzimuthDegrees = smoothed
        peers[i].positionSource = source
        peers[i].hasPosition = true
        if let distanceMeters { peers[i].distanceMeters = distanceMeters }
        relayout()
    }

    public func apply(_ frame: PositionUpdateFrame) {
        updatePosition(id: frame.peerID, azimuthDegrees: frame.azimuthDegrees,
                       distanceMeters: frame.distanceMeters, source: frame.source)
    }

    private func relayout() {
        RadarLayout.apply(to: &peers, mode: sectorMode)
        peers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Magnification

    public func scales(theta: Double, r: Double) -> [String: Double] {
        DockMagnification.scales(for: peers, theta: theta, r: r, mode: sectorMode)
    }

    public func target(theta: Double, r: Double, sector: Int? = nil) -> PeerDevice? {
        DockMagnification.target(in: peers, scales: scales(theta: theta, r: r), sector: sector)
    }

    // MARK: - Simulation

    public static let simulatedPhoneID = "sim-iphone"
    public static let simulatedPadID = "sim-ipad"

    public var hasSimulatedPeers: Bool { peers.contains(where: \.isSimulated) }

    public func seedSimulatedPeers() {
        upsertPeer(id: Self.simulatedPhoneID, name: "Simulated iPhone", kind: .iPhone, isSimulated: true)
        upsertPeer(id: Self.simulatedPadID, name: "Simulated iPad", kind: .iPad, isSimulated: true)
        updatePosition(id: Self.simulatedPhoneID, azimuthDegrees: 80, distanceMeters: 1.2, source: .simulated, smooth: false)
        updatePosition(id: Self.simulatedPadID, azimuthDegrees: 275, distanceMeters: 2.0, source: .simulated, smooth: false)
    }

    public func removeSimulatedPeers() {
        stopOrbiting()
        for peer in peers where peer.isSimulated { removePeer(id: peer.id) }
    }

    /// Moves simulated peers around the ring at different speeds so they cross
    /// sectors and occasionally share one.
    public func startOrbiting() {
        guard orbitTask == nil else { return }
        if !hasSimulatedPeers { seedSimulatedPeers() }
        isOrbiting = true
        orbitTask = Task { [weak self] in
            let start = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self else { return }
                let t = Date().timeIntervalSince(start)
                self.updatePosition(id: Self.simulatedPhoneID, azimuthDegrees: 80 + t * 18, source: .simulated)
                self.updatePosition(id: Self.simulatedPadID, azimuthDegrees: 275 - t * 11, source: .simulated)
            }
        }
    }

    public func stopOrbiting() {
        orbitTask?.cancel()
        orbitTask = nil
        isOrbiting = false
    }
}
