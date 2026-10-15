import AirCompassCore
import AppKit
import os

/// End-to-end pipeline: gesture → Finder selection → HUD → 60 Hz gesture
/// mirroring → on release, send to the most magnified device in the sector.
@MainActor
final class GestureCoordinator {
    private(set) var source: GestureInputSource?
    let hud = CompassHUDModel()

    /// Lets the HUD and gestures run with no Finder selection (menu toggle).
    var previewMode = false {
        didSet {
            if !previewMode { previewFamily = nil }
            hud.showsStyleSwitcher = previewMode
            panel.isInteractive = previewMode
            previewMode ? showPreview() : hideIfIdle()
        }
    }
    var onStatus: ((String) -> Void)?

    private let finder: FinderSelectionExtractor
    private let services: PeerServices
    private let settings: AppSettings
    /// Family picked on the preview's style switcher, overriding the tracking mode.
    private var previewFamily: HUDFamily?
    private lazy var panel = CompassHUDPanel(rootView: CompassHUDView(model: hud))
    private let log = Logger(subsystem: "com.aircompass.AirCompass", category: "Gesture")

    private let glassLab = GlassLabWindow()
    private var pendingFiles: [URL] = []
    private var gestureActive = false
    private var lastTargetID: String?
    private var lastArmed = false
    private var lastMirrorTime: TimeInterval = 0
    private var hideTask: Task<Void, Never>?

    init(finder: FinderSelectionExtractor, services: PeerServices, settings: AppSettings) {
        self.finder = finder
        self.services = services
        self.settings = settings
        hud.sectorMode = services.radar.sectorMode
        hud.onSelectStyle = { [weak self] style in self?.select(style: style) }
        hud.onSetGlass = { [weak self] glass in self?.setGlass(glass) }
        hud.onOpenLab = { [weak self] in self?.openGlassLab() }
        applyAppearance()

        services.transfers.onIncoming = { [weak self] progress in self?.showIncoming(progress) }
        services.transfers.onChange = { [weak self] progress in self?.transferChanged(progress) }
    }

    @discardableResult
    func use(_ newSource: GestureInputSource) -> Error? {
        source?.stop()
        source = newSource
        newSource.onEvent = { [weak self] event in self?.handle(event) }
        do {
            try newSource.start()
            log.info("Gesture source started: \(String(describing: type(of: newSource)))")
            return nil
        } catch {
            log.error("Gesture source failed to start: \(String(describing: error), privacy: .public)")
            source = nil
            return error
        }
    }

    var sectorMode: SectorMode {
        get { services.radar.sectorMode }
        set {
            source?.sectorMode = newValue
            services.setSectorMode(newValue)
            hud.sectorMode = newValue
            refreshNodes()
        }
    }

    /// Keeps HUD nodes in sync when peers move while the HUD is up.
    func peersChanged() {
        guard hud.mode != .hidden else { return }
        if gestureActive, let vector = hud.vector {
            hud.nodes = aim(vector).nodes
        } else {
            hud.family = currentFamily()
            refreshNodes()
        }
    }

    // MARK: Appearance

    /// Re-reads tracking mode and styles from settings.
    func applyAppearance() {
        hud.glass = settings.glassAppearance
        OpticalGlassEngine.shared.enabled = hud.glass.isOptical
        hud.uniformStyle = settings.nonDirectionalStyle
        hud.spatialStyle = settings.spatialStyle
        guard !gestureActive else { return }
        hud.family = currentFamily()
        if hud.mode != .hidden { refreshNodes() }
    }

    /// Glass Lab: every lens control, with the preview open to see them live.
    func openGlassLab() {
        if !previewMode { previewMode = true }
        glassLab.show(model: hud)
    }

    /// Glass Appearance meter (menu or preview switcher); applies live.
    func setGlass(_ glass: GlassAppearance) {
        settings.glassAppearance = glass
        hud.glass = glass
        OpticalGlassEngine.shared.enabled = glass.isOptical
    }

    /// Picks a style (menu or preview switcher). While previewing, picking a
    /// style from the other family shows that family right away.
    func select(style: HUDStyle) {
        switch style {
        case let .uniform(s): settings.nonDirectionalStyle = s
        case let .spatial(s): settings.spatialStyle = s
        }
        if previewMode { previewFamily = style.family }
        applyAppearance()
    }

    func trackingModeChanged() {
        previewFamily = nil
        applyAppearance()
    }

    private func currentFamily() -> HUDFamily {
        previewFamily ?? settings.trackingMode.resolve(peers: services.radar.peers)
    }

    // MARK: Gesture events

    private func handle(_ event: GestureEvent) {
        switch event {
        case .began:
            switch finder.currentSelection() {
            case let .selection(selection):
                pendingFiles = selection.urls
                log.info("Gesture began with \(selection.urls.count) file(s) via \(selection.strategy.rawValue, privacy: .public)")
            case .empty, .finderNotInContext, .failed:
                guard previewMode else {
                    source?.suppressCurrentGesture()
                    return
                }
                pendingFiles = []
            }
            begin()

        case let .changed(vector, armed):
            guard gestureActive else { return }
            update(vector: vector, armed: armed)

        case let .committed(commit):
            guard gestureActive else { return }
            commitGesture(commit)

        case let .cancelled(reason):
            guard gestureActive else { return }
            endGesture()
            if reason == .releasedBelowThreshold || reason == .extraFingers {
                hud.message = nil
                scheduleHide(after: 0.1)
            }
        }
    }

    private func begin() {
        hideTask?.cancel()
        gestureActive = true
        services.isGestureActive = true
        lastTargetID = nil
        lastArmed = false
        hud.mode = .sending
        hud.family = currentFamily()
        hud.files = pendingFiles
        hud.transfer = nil
        hud.message = nil
        hud.vector = .zero
        hud.isArmed = false
        hud.targetName = nil
        hud.activeSector = nil
        refreshNodes()
        if previewMode {
            // The preview is already open top-center; drag in place.
            panel.present()
        } else {
            hud.pinnedToTop = false
            panel.present(anchor: selectionAnchor())
        }
        onStatus?("Tracking — \(pendingFiles.count) file(s)")
    }

    /// Center of the selected files on screen, so the HUD opens right where
    /// they are; the pointer when the selection's frame can't be read
    /// (no Accessibility permission, or nothing visible).
    private func selectionAnchor() -> CGPoint {
        let clock = ContinuousClock()
        let start = clock.now
        let frame = pendingFiles.isEmpty ? nil : finder.selectionFrame()
        log.debug("Selection frame \(String(describing: frame), privacy: .public) in \(clock.now - start)")
        return frame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
    }

    /// What the drag points at, in the HUD's current family.
    private struct Aim {
        var target: PeerDevice?
        var scales: [String: Double]
        var nodes: [CompassNodeModel]
        var sector: Int?
    }

    private func aim(_ vector: GestureVector) -> Aim {
        let radar = services.radar
        let aiming = vector.r > 0.02
        switch hud.family {
        case .spatial:
            // The target is the most magnified device in the sector being
            // pointed at — the same rule while aiming and on release.
            let scales = radar.scales(theta: vector.theta, r: vector.r)
            let sector = radar.sectorMode.sector(for: vector.theta)
            let target = aiming ? radar.target(theta: vector.theta, r: vector.r, sector: sector) : nil
            let nodes = radar.positionedPeers.map {
                CompassNodeModel(peer: $0, scale: scales[$0.id] ?? 1, isTarget: $0.id == target?.id)
            }
            return Aim(target: target, scales: scales, nodes: nodes, sector: aiming ? sector : nil)
        case .uniform:
            // Every connected device, positioned or not, on an even layout.
            let peers = radar.peers
            let style = settings.nonDirectionalStyle
            let scales = UniformLayout.scales(style: style, count: peers.count, theta: vector.theta, r: vector.r)
            let index = aiming ? UniformLayout.targetIndex(scales: scales) : nil
            return Aim(target: index.map { peers[$0] },
                       scales: Dictionary(uniqueKeysWithValues: zip(peers.map(\.id), scales)),
                       nodes: UniformLayout.nodes(for: peers, style: style, scales: scales, targetIndex: index),
                       sector: nil)
        }
    }

    private func update(vector: GestureVector, armed: Bool) {
        let aim = aim(vector)
        let target = aim.target

        if target?.id != lastTargetID {
            if target != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            lastTargetID = target?.id
        }
        if armed != lastArmed {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            lastArmed = armed
        }

        hud.vector = vector
        hud.isArmed = armed
        hud.activeSector = aim.sector
        hud.targetName = target?.name
        hud.nodes = aim.nodes

        mirror(vector: vector, armed: armed, committed: false, active: true, target: target?.id, scales: aim.scales)
    }

    private func commitGesture(_ commit: GestureCommit) {
        let aim = aim(commit.vector)
        let target = aim.target
        let files = pendingFiles
        mirror(vector: commit.vector, armed: true, committed: true, active: false, target: target?.id, scales: aim.scales)
        endGesture()

        guard let target else {
            hud.message = "No device in that direction"
            scheduleHide(after: 1.2)
            return
        }
        guard !files.isEmpty else {
            hud.message = "Preview — would send to \(target.name)"
            scheduleHide(after: 1.5)
            return
        }

        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        log.info("Sending \(files.count) file(s) to \(target.name, privacy: .public)")
        onStatus?("Sending \(files.count) file(s) → \(target.name)")

        Task {
            if target.isSimulated {
                await services.transfers.simulateSend(files: files, to: target)
            } else if let hello = services.hello(for: target.id) {
                do {
                    try await services.transfers.send(files: files, to: hello, receiverAzimuthDegrees: target.hasPosition ? target.smoothedAzimuthDegrees : nil)
                } catch {
                    log.error("Send failed: \(String(describing: error), privacy: .public)")
                    if hud.transfer == nil {
                        hud.message = String(describing: error)
                        scheduleHide(after: 2.5)
                    }
                }
            } else {
                hud.message = "\(target.name) is no longer connected"
                scheduleHide(after: 2)
            }
        }
    }

    private func endGesture() {
        gestureActive = false
        services.isGestureActive = false
        hud.vector = nil
        pendingFiles = []
    }

    /// Broadcast drag state to peers, throttled to 60 Hz (final frames always go).
    private func mirror(vector: GestureVector, armed: Bool, committed: Bool, active: Bool, target: String?, scales: [String: Double]) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !active || now - lastMirrorTime >= 1.0 / 60 else { return }
        lastMirrorTime = now
        let frame = GestureMirrorFrame(
            senderID: services.identity.id, r: vector.r, theta: vector.theta, isActive: active, isArmed: armed,
            isCommitted: committed, targetPeerID: target, fileNames: hud.files.map(\.lastPathComponent),
            peerScales: scales, sectorMode: services.radar.sectorMode
        )
        services.network.broadcast(.gestureMirror(frame))
    }

    // MARK: Transfers

    private func showIncoming(_ progress: TransferProgress) {
        hideTask?.cancel()
        if !gestureActive { hud.family = currentFamily() }
        if hud.mode == .hidden { hud.pinnedToTop = true }
        hud.mode = .receiving
        hud.transfer = progress
        hud.files = []
        hud.message = nil
        hud.vector = nil
        hud.isArmed = false
        hud.activeSector = progress.peerAzimuthDegrees.map(services.radar.sectorMode.sector(forDegrees:))
        refreshNodes(highlight: progress.peerID)
        panel.present()
    }

    private func transferChanged(_ progress: TransferProgress) {
        // Outgoing transfers take over the HUD after the gesture ends.
        if progress.direction == .outgoing, !gestureActive, hud.mode == .sending || hud.mode == .hidden || hud.mode == .preview {
            hideTask?.cancel()
            if hud.mode != .sending {
                hud.mode = .sending
                panel.present()
            }
            hud.transfer = progress
            hud.message = nil
        } else if progress.direction == .incoming, hud.transfer?.id == progress.id {
            hud.transfer = progress
        } else {
            return
        }

        switch progress.state {
        case .completed:
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            onStatus?(progress.direction == .incoming ? "Received from \(progress.peerName)" : "Sent to \(progress.peerName)")
            scheduleHide(after: 1.8)
        case let .failed(reason):
            onStatus?("Transfer failed: \(reason)")
            scheduleHide(after: 3)
        default:
            break
        }
    }

    // MARK: HUD helpers

    private func refreshNodes(highlight: String? = nil) {
        hud.sectorMode = services.radar.sectorMode
        switch hud.family {
        case .spatial:
            hud.nodes = services.radar.positionedPeers.map {
                CompassNodeModel(peer: $0, scale: $0.id == highlight ? 1.5 : 1, isTarget: $0.id == highlight)
            }
        case .uniform:
            let peers = services.radar.peers
            hud.nodes = UniformLayout.nodes(for: peers, style: settings.nonDirectionalStyle,
                                            scales: peers.map { $0.id == highlight ? 1.5 : 1 },
                                            targetIndex: peers.firstIndex { $0.id == highlight })
        }
    }

    private func showPreview() {
        guard hud.mode == .hidden else { return }
        hud.mode = .preview
        hud.pinnedToTop = true
        hud.family = currentFamily()
        hud.message = nil
        hud.transfer = nil
        hud.files = []
        refreshNodes()
        panel.present()
    }

    private func hideIfIdle() {
        guard hud.mode == .preview else { return }
        hud.mode = .hidden
        panel.dismiss()
    }

    private func scheduleHide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, !self.gestureActive else { return }
            self.hud.transfer = nil
            self.hud.message = nil
            self.hud.activeSector = nil
            self.hud.targetName = nil
            if self.previewMode {
                self.hud.mode = .preview
                self.hud.family = self.currentFamily()
                self.refreshNodes()
            } else {
                self.hud.mode = .hidden
                self.panel.dismiss()
            }
        }
    }
}
