import AirCompassCore
import AppKit
import os
import SystemConfiguration

/// Network, radar, transfers and acoustic positioning for the Mac.
@MainActor
final class PeerServices {
    let identity: LocalIdentity
    let network: PeerNetwork
    let radar: SpatialRadarEngine
    let transfers: PeerTransferManager

    /// Called whenever the peer list or positions change (menu refresh).
    var onPeersChanged: (() -> Void)?
    /// True while a gesture is active; acoustic probes pause so chirps don't
    /// play while the user is aiming.
    var isGestureActive = false

    private let settings: AppSettings
    private let emitter = AcousticEmitter()
    private let positioner = AcousticPositioner()
    private var probeTimer: Timer?
    /// Last time a chirp pair was played (shown in the menu).
    private(set) var lastChirp: Date?
    private(set) var chirpCount = 0
    private let log = Logger(subsystem: "com.aircompass.AirCompass", category: "Peers")

    init(settings: AppSettings) {
        self.settings = settings
        let name = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
        identity = LocalIdentity(id: LocalIdentity.persistentID(), name: name, kind: .mac)
        network = PeerNetwork(identity: identity)
        radar = SpatialRadarEngine(sectorMode: settings.sectorMode)
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        transfers = PeerTransferManager(network: network, inbox: downloads)
        positioner.hemisphere = settings.hemisphere
        // Stay warm between on-demand probes so chirps play without start-up delay.
        emitter.keepWarmSeconds = 60
    }

    func start() {
        transfers.azimuthForPeer = { [weak self] id in
            guard let peer = self?.radar.peer(id), peer.hasPosition else { return nil }
            return peer.smoothedAzimuthDegrees
        }

        network.onPeerConnected = { [weak self] hello in
            self?.radar.upsertPeer(id: hello.peerID, name: hello.name, kind: hello.kind)
            self?.onPeersChanged?()
        }
        network.onPeerUpdated = { [weak self] hello in
            self?.radar.upsertPeer(id: hello.peerID, name: hello.name, kind: hello.kind)
            self?.onPeersChanged?()
        }
        network.onPeerDisconnected = { [weak self] id in
            self?.radar.removePeer(id: id)
            self?.transfers.peerDisconnected(id)
            self?.onPeersChanged?()
        }
        network.onFrame = { [weak self] id, frame in self?.handle(frame, from: id) }

        network.updateHello {
            $0.sectorMode = settings.sectorMode
            $0.wantsAcousticProbes = settings.acousticListen
        }
        network.start()

        if settings.acousticListen { Task { await positioner.startListening() } }

        // Background cadence; moving devices also request probes on demand.
        probeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.probeIfNeeded() }
        }
    }

    func setSectorMode(_ mode: SectorMode) {
        radar.sectorMode = mode
        network.updateHello { $0.sectorMode = mode }
    }

    func setAcousticListen(_ enabled: Bool) {
        settings.acousticListen = enabled
        network.updateHello { $0.wantsAcousticProbes = enabled }
        if enabled {
            Task { await positioner.startListening() }
        } else {
            positioner.stopListening()
        }
    }

    func setHemisphere(_ hemisphere: AcousticHemisphere) {
        settings.hemisphere = hemisphere
        positioner.hemisphere = hemisphere
    }

    func hello(for peerID: String) -> PeerHelloFrame? {
        network.connectedPeers.first { $0.peerID == peerID }
    }

    // MARK: Frames

    private func handle(_ frame: WireFrame, from peerID: String) {
        switch frame {
        case let .position(update):
            // Only accept a peer's report about itself.
            guard update.peerID == peerID else { return }
            radar.apply(update)
            onPeersChanged?()
        case .transferHeader, .transferChunk, .transferAck:
            transfers.handle(frame, from: peerID)
        case let .acousticProbe(probe):
            guard settings.acousticListen else { return }
            positioner.handle(probe, localPeerID: identity.id) { [weak self] update in
                self?.network.send(.position(update), to: probe.emitterID)
            }
        case .acousticProbeRequest:
            probeIfNeeded(onDemand: true)
        case .hello, .gestureMirror:
            break
        }
    }

    // MARK: Acoustic emitter

    /// Chirp for peers that asked to be located by sound. A single chirp pair
    /// serves every listener at once. Runs every 5 s, and immediately when a
    /// moving device asks (rate-limited so overlapping pairs can't collide).
    func probeIfNeeded(force: Bool = false, onDemand: Bool = false) {
        guard settings.acousticEmit, force || !isGestureActive else { return }
        if let lastChirp, Date().timeIntervalSince(lastChirp) < (onDemand ? 0.45 : 1.0), !force { return }
        let listeners = network.connectedPeers.filter(\.wantsAcousticProbes)
        guard !listeners.isEmpty else { return }

        let probe = AcousticProbeFrame(
            probeID: UUID(), emitterID: identity.id, leadInSeconds: 0.15, slotGapSeconds: 0.06,
            chirp: .standard, speakerSpacingMeters: settings.speakerSpacing
        )
        for peer in listeners { network.send(.acousticProbe(probe), to: peer.peerID) }
        do {
            try emitter.emit(probe)
            lastChirp = Date()
            chirpCount += 1
            log.info("Chirp #\(self.chirpCount) for \(listeners.map(\.name).joined(separator: ", "), privacy: .public)\(onDemand ? " (on demand)" : "")")
        } catch {
            log.error("Chirp playback failed: \(String(describing: error), privacy: .public)")
        }
    }
}
