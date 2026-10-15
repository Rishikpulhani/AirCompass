import AirCompassCore
import Foundation
import Observation
import os
import UIKit
import UserNotifications

/// iPhone/iPad side: connects to Macs, reports this device's position,
/// mirrors the Mac's 3-finger drag, and sends/receives files.
@MainActor
@Observable
final class CompanionModel {
    enum PositionMode: String, CaseIterable, Identifiable {
        case acoustic, manual, motion
        var id: String { rawValue }
        var title: String {
            switch self {
            case .acoustic: "Sound (auto)"
            case .manual: "Manual"
            case .motion: "Motion"
            }
        }
    }

    // MARK: Observable state

    private(set) var macs: [PeerHelloFrame] = []
    /// This device's bearing relative to the Mac (0 = behind the Mac's screen).
    private(set) var azimuthDegrees: Double
    var positionMode: PositionMode {
        didSet {
            defaults.set(positionMode.rawValue, forKey: "positionMode")
            applyPositionMode()
        }
    }
    var hemisphere: AcousticHemisphere {
        didSet {
            defaults.set(hemisphere.rawValue, forKey: "hemisphere")
            positioner.hemisphere = hemisphere
        }
    }
    private(set) var acousticStatus = "Waiting for the Mac to chirp…"
    private(set) var lastFixDate: Date?
    /// Keep running (and reachable) with the screen off or app in background.
    var alwaysOn: Bool {
        didSet {
            defaults.set(alwaysOn, forKey: "alwaysOn")
            if alwaysOn { requestNotificationPermission() }
            updateKeepAlive()
        }
    }
    private(set) var deviceName: String

    /// Latest live gesture from a Mac (nil when idle).
    private(set) var mirror: GestureMirrorFrame?
    var myScale: Double { mirror?.peerScales[identity.id] ?? 1 }
    var isTargeted: Bool { mirror?.targetPeerID == identity.id }

    private(set) var currentTransfer: TransferProgress?
    private(set) var receivedFiles: [URL] = []
    var previewURL: URL?
    private(set) var lastError: String?

    // MARK: Services

    let identity: LocalIdentity
    @ObservationIgnored private let network: PeerNetwork
    @ObservationIgnored let transfers: PeerTransferManager
    @ObservationIgnored private let positioner = AcousticPositioner()
    @ObservationIgnored private let motion = MotionHeadingTracker()
    @ObservationIgnored private let keeper = BackgroundKeeper()
    @ObservationIgnored private var lastProbeRequest: TimeInterval = 0
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var lastPositionSent: TimeInterval = 0
    @ObservationIgnored private var mirrorTimeout: Task<Void, Never>?
    @ObservationIgnored private var lastHapticScale = 1.0
    @ObservationIgnored private var wasArmedOnMe = false
    @ObservationIgnored private let log = Logger(subsystem: "com.rishikpulhani.AirCompassCompanion", category: "Companion")

    @ObservationIgnored private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    @ObservationIgnored private let heavyHaptic = UIImpactFeedbackGenerator(style: .heavy)
    @ObservationIgnored private let notifyHaptic = UINotificationFeedbackGenerator()

    var sectorMode: SectorMode { macs.first?.sectorMode ?? .four }
    var macName: String? { macs.first?.name }
    var inboxURL: URL { Self.inbox }

    static let inbox: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Received", isDirectory: true)

    init() {
        let defaults = UserDefaults.standard
        let kind: DeviceKind = UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        let name = defaults.string(forKey: "deviceName") ?? UIDevice.current.name
        deviceName = name
        identity = LocalIdentity(id: LocalIdentity.persistentID(), name: name, kind: kind)
        network = PeerNetwork(identity: identity)
        transfers = PeerTransferManager(network: network, inbox: Self.inbox)
        azimuthDegrees = defaults.object(forKey: "azimuth") as? Double ?? (kind == .iPad ? 270 : 90)
        positionMode = defaults.string(forKey: "positionMode").flatMap(PositionMode.init(rawValue:)) ?? .manual
        hemisphere = defaults.string(forKey: "hemisphere").flatMap(AcousticHemisphere.init(rawValue:)) ?? .userSide
        alwaysOn = defaults.bool(forKey: "alwaysOn")
        positioner.hemisphere = hemisphere
        receivedFiles = (try? FileManager.default.contentsOfDirectory(at: Self.inbox, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }) ?? []
    }

    func start() {
        network.onPeerConnected = { [weak self] hello in self?.peerConnected(hello) }
        network.onPeerUpdated = { [weak self] hello in self?.peerUpdated(hello) }
        network.onPeerDisconnected = { [weak self] id in
            self?.macs.removeAll { $0.peerID == id }
            self?.transfers.peerDisconnected(id)
        }
        network.onFrame = { [weak self] id, frame in self?.handle(frame, from: id) }

        transfers.onIncoming = { [weak self] progress in self?.currentTransfer = progress }
        transfers.onChange = { [weak self] progress in self?.transferChanged(progress) }
        transfers.azimuthForPeer = { [weak self] _ in
            // The Mac is opposite our bearing from it.
            self.map { AngleMath.normalizeDegrees($0.azimuthDegrees + 180) }
        }

        positioner.onStatus = { [weak self] status in self?.acousticStatusChanged(status) }
        motion.onBearing = { [weak self] bearing in
            guard let self, self.positionMode == .motion else { return }
            self.setAzimuth(bearing, source: .motion)
        }
        motion.onMovement = { [weak self] in self?.deviceMoved() }
        keeper.onShouldRestart = { [weak self] in self?.applyPositionMode() }

        applyPositionMode()
        network.start()
        lightHaptic.prepare()
    }

    // MARK: Settings

    func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        deviceName = trimmed
        defaults.set(trimmed, forKey: "deviceName")
        network.updateHello { $0.name = trimmed }
    }

    private func applyPositionMode() {
        network.updateHello { $0.wantsAcousticProbes = positionMode == .acoustic }
        // Motion updates drive yaw in motion mode and movement detection in sound mode.
        if positionMode == .manual { motion.stop() } else { motion.start() }
        if positionMode == .acoustic {
            acousticStatus = "Starting microphone…"
            keeper.stopSilence()
            Task {
                await positioner.startListening()
                updateKeepAlive()
            }
        } else {
            positioner.stopListening()
        }
        updateKeepAlive()
    }

    /// In sound mode the always-on mic keeps the app alive; otherwise play silence.
    private func updateKeepAlive() {
        if alwaysOn, positionMode != .acoustic {
            keeper.startSilence()
        } else {
            keeper.stopSilence()
        }
    }

    /// Being carried: ask the Mac to chirp now (rate-limited) so the new
    /// position is measured within a fraction of a second.
    private func deviceMoved() {
        guard positionMode == .acoustic, !macs.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastProbeRequest >= 0.5 else { return }
        lastProbeRequest = now
        network.broadcast(.acousticProbeRequest(AcousticProbeRequestFrame(peerID: identity.id))) { $0.kind == .mac }
    }

    private func requestNotificationPermission() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    private func notifyReceived(_ progress: TransferProgress) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "Received from \(progress.peerName)"
        content.body = progress.files.map(\.name).joined(separator: ", ")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: progress.id.uuidString, content: content, trigger: nil))
    }

    // MARK: Position

    /// Dial drag: switches to manual and streams the position at ≤60 Hz.
    func dragDial(to degrees: Double) {
        if positionMode != .manual { positionMode = .manual }
        setAzimuth(degrees, source: .manual)
    }

    func calibrateMotion() {
        motion.calibrate(currentBearing: azimuthDegrees)
        if positionMode != .motion { positionMode = .motion }
    }

    private func setAzimuth(_ degrees: Double, source: PositionSource, force: Bool = false) {
        azimuthDegrees = AngleMath.normalizeDegrees(degrees)
        defaults.set(azimuthDegrees, forKey: "azimuth")
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastPositionSent >= 1.0 / 60 else { return }
        lastPositionSent = now
        network.broadcast(.position(PositionUpdateFrame(peerID: identity.id, azimuthDegrees: azimuthDegrees, source: source)))
    }

    private func acousticStatusChanged(_ status: AcousticPositioner.Status) {
        switch status {
        case .idle: acousticStatus = "Microphone on — waiting for the Mac to chirp…"
        case .listening: acousticStatus = "Hearing a chirp…"
        case let .fix(fix):
            lastFixDate = fix.date
            azimuthDegrees = fix.bearingDegrees
            defaults.set(azimuthDegrees, forKey: "azimuth")
            acousticStatus = String(format: "Measured %.0f° (signal %.0f×)", fix.bearingDegrees, fix.estimate.confidence)
        case .noSignal: acousticStatus = "Couldn't hear the chirps — turn the Mac's volume up"
        case let .failed(message): acousticStatus = message
        }
    }

    // MARK: Peers

    private func peerConnected(_ hello: PeerHelloFrame) {
        guard hello.kind == .mac else { return }
        macs.removeAll { $0.peerID == hello.peerID }
        macs.append(hello)
        log.info("Connected to \(hello.name)")
        // Tell the new Mac where we are right away (acoustic waits for a probe).
        if positionMode != .acoustic {
            network.send(.position(PositionUpdateFrame(peerID: identity.id, azimuthDegrees: azimuthDegrees,
                                                       source: positionMode == .manual ? .manual : .motion)), to: hello.peerID)
        }
    }

    private func peerUpdated(_ hello: PeerHelloFrame) {
        guard let i = macs.firstIndex(where: { $0.peerID == hello.peerID }) else { return }
        macs[i] = hello
    }

    private func handle(_ frame: WireFrame, from peerID: String) {
        switch frame {
        case let .gestureMirror(m): receiveMirror(m)
        case let .acousticProbe(probe):
            guard positionMode == .acoustic else { return }
            positioner.handle(probe, localPeerID: identity.id) { [weak self] update in
                self?.network.send(.position(update), to: probe.emitterID)
            }
        case .transferHeader, .transferChunk, .transferAck:
            transfers.handle(frame, from: peerID)
        case .hello, .position, .acousticProbeRequest:
            break
        }
    }

    // MARK: Gesture mirroring

    private func receiveMirror(_ frame: GestureMirrorFrame) {
        mirrorTimeout?.cancel()
        guard frame.isActive else {
            if frame.isCommitted, frame.targetPeerID == identity.id {
                notifyHaptic.notificationOccurred(.success)
            }
            withMirrorReset()
            return
        }
        mirror = frame

        // Haptics as the drag closes in on this device.
        let scale = myScale
        if scale > 1.3, lastHapticScale <= 1.3 { lightHaptic.impactOccurred() }
        lastHapticScale = scale
        let armedOnMe = frame.isArmed && frame.targetPeerID == identity.id
        if armedOnMe, !wasArmedOnMe { heavyHaptic.impactOccurred() }
        wasArmedOnMe = armedOnMe

        // Clear if the Mac goes quiet mid-gesture.
        mirrorTimeout = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.withMirrorReset()
        }
    }

    private func withMirrorReset() {
        mirror = nil
        lastHapticScale = 1
        wasArmedOnMe = false
    }

    // MARK: Transfers

    private func transferChanged(_ progress: TransferProgress) {
        currentTransfer = progress
        switch progress.state {
        case let .completed(urls):
            notifyHaptic.notificationOccurred(.success)
            if progress.direction == .incoming {
                receivedFiles.insert(contentsOf: urls, at: 0)
                previewURL = urls.first
                notifyReceived(progress)
            }
            clearTransferSoon(progress.id)
        case let .failed(reason):
            notifyHaptic.notificationOccurred(.error)
            lastError = reason
            clearTransferSoon(progress.id)
        default:
            break
        }
    }

    private func clearTransferSoon(_ id: UUID) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            if self?.currentTransfer?.id == id { self?.currentTransfer = nil }
        }
    }

    /// Sends files to the first connected Mac.
    func send(_ urls: [URL]) {
        guard let mac = macs.first else {
            lastError = "No Mac connected"
            return
        }
        lastError = nil
        Task {
            do {
                try await transfers.send(files: urls, to: mac,
                                         receiverAzimuthDegrees: AngleMath.normalizeDegrees(azimuthDegrees + 180))
            } catch {
                lastError = String(describing: error)
            }
        }
    }

    func sendTestFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AirCompass Test from \(deviceName).txt")
        let text = """
        Hello from \(deviceName)!
        Sent with AirCompass at \(Date().formatted(date: .abbreviated, time: .standard)).
        My bearing relative to the Mac: \(Int(azimuthDegrees.rounded()))°
        """
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            send([url])
        } catch {
            lastError = error.localizedDescription
        }
    }

    func sendData(_ data: Data, named name: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url)
            send([url])
        } catch {
            lastError = error.localizedDescription
        }
    }
}
