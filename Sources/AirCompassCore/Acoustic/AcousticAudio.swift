@preconcurrency import AVFoundation
import Foundation
import os

public enum AcousticError: Error, CustomStringConvertible {
    case microphoneDenied
    case noInput
    case formatUnavailable

    public var description: String {
        switch self {
        case .microphoneDenied: "Microphone access was denied"
        case .noInput: "No audio input device"
        case .formatUnavailable: "Audio format unavailable"
        }
    }
}

// MARK: - Emitter

/// Plays stereo chirp probes through the built-in speakers.
@MainActor
public final class AcousticEmitter {
    public static let sampleRate = 48_000.0

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    private var configured = false
    private var idleStop: Task<Void, Never>?
    /// Seconds of silence before the output engine is released.
    public var keepWarmSeconds: Double = 8

    public init() {}

    public func emit(_ probe: AcousticProbeFrame) throws {
        if !configured {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            configured = true
        }
        if !engine.isRunning { try engine.start() }

        let (left, right) = AcousticDSP.stereoProbe(probe, sampleRate: Self.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count)),
              let channels = buffer.floatChannelData else { throw AcousticError.formatUnavailable }
        buffer.frameLength = AVAudioFrameCount(left.count)
        left.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress!, count: left.count) }
        right.withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress!, count: right.count) }

        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }

        // Keep the engine warm between probes, but release the output when idle.
        idleStop?.cancel()
        idleStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.keepWarmSeconds ?? 8))
            guard !Task.isCancelled, let self else { return }
            self.player.stop()
            self.engine.stop()
        }
    }
}

// MARK: - Listener

/// Thread-safe ring buffer filled from the audio render thread.
final class SampleRing: @unchecked Sendable {
    private struct State {
        var samples: [Float] = []
        var capacity: Int
    }
    private let lock: OSAllocatedUnfairLock<State>

    init(capacity: Int) {
        lock = OSAllocatedUnfairLock(initialState: State(capacity: capacity))
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let chunk = Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        lock.withLock { state in
            state.samples.append(contentsOf: chunk)
            if state.samples.count > state.capacity {
                state.samples.removeFirst(state.samples.count - state.capacity)
            }
        }
    }

    /// The most recent `count` samples.
    func latest(_ count: Int) -> [Float] {
        lock.withLock { Array($0.samples.suffix(count)) }
    }

    func reset() { lock.withLock { $0.samples.removeAll(keepingCapacity: true) } }

    /// Built outside any actor so the closure isn't main-actor isolated: the
    /// tap is invoked on the realtime audio thread.
    nonisolated static func tapBlock(for ring: SampleRing) -> AVAudioNodeTapBlock {
        { buffer, _ in ring.append(buffer) }
    }
}

/// Keeps the raw microphone running and remembers the last few seconds, so a
/// probe can be analysed without paying mic start-up latency each time.
@MainActor
public final class AcousticListener {
    public static let historySeconds = 3.0

    private var engine: AVAudioEngine?
    private var ring: SampleRing?
    public private(set) var sampleRate = 48_000.0
    public var isRunning: Bool { engine?.isRunning ?? false }

    public init() {}

    public static func requestPermission() async -> Bool {
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
        #endif
    }

    public func start() async throws {
        guard !isRunning else { return }
        guard await Self.requestPermission() else { throw AcousticError.microphoneDenied }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // .measurement disables voice processing / AGC that would smear the chirps.
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
        try? session.setPreferredSampleRate(48_000)
        try session.setActive(true)
        #endif

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AcousticError.noInput }

        let ring = SampleRing(capacity: Int(format.sampleRate * Self.historySeconds))
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: SampleRing.tapBlock(for: ring))
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.ring = ring
        sampleRate = format.sampleRate
    }

    public func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        ring = nil
    }

    /// The last `seconds` of microphone audio.
    public func recent(seconds: Double) -> [Float] {
        ring?.latest(Int(seconds * sampleRate)) ?? []
    }
}

// MARK: - Positioner (listener side)

/// Answers acoustic probes: records, estimates the lateral angle, applies the
/// user's hemisphere choice and reports a bearing back to the emitter.
@MainActor
public final class AcousticPositioner {
    public struct Fix: Sendable, Equatable {
        public var bearingDegrees: Double
        public var estimate: AcousticEstimate
        public var date: Date
    }

    public enum Status: Sendable, Equatable {
        case idle
        case listening
        case fix(Fix)
        case noSignal
        case failed(String)
    }

    public var hemisphere: AcousticHemisphere = .userSide
    public var onStatus: ((Status) -> Void)?
    public var isListening: Bool { listener.isRunning }

    private let listener = AcousticListener()
    private var busy = false
    private let log = Logger(subsystem: "com.aircompass.AirCompass", category: "Acoustic")

    public init() {}

    /// Starts the always-on microphone stream (call when sound mode is enabled).
    public func startListening() async {
        do {
            try await listener.start()
            onStatus?(.idle)
        } catch {
            onStatus?(.failed(String(describing: error)))
        }
    }

    public func stopListening() {
        listener.stop()
    }

    public func handle(_ probe: AcousticProbeFrame, localPeerID: String, reply: @escaping (PositionUpdateFrame) -> Void) {
        guard !busy else { return }
        busy = true
        onStatus?(.listening)

        // Wait until the chirp pair has certainly played, then analyse the
        // recent audio. Slack covers network latency and output buffering.
        let span = probe.leadInSeconds + probe.slotGapSeconds + probe.chirp.durationSeconds
        let wait = span + 0.30
        Task {
            defer { busy = false }
            if !listener.isRunning { await startListening() }
            try? await Task.sleep(for: .seconds(wait))
            let samples = listener.recent(seconds: wait + 0.15)
            let rate = listener.sampleRate
            guard !samples.isEmpty else {
                onStatus?(.failed("Microphone isn't running"))
                return
            }
            let estimate = await Task.detached(priority: .userInitiated) {
                AcousticDSP.estimate(samples: samples, sampleRate: rate, chirp: probe.chirp,
                                     slotGapSeconds: probe.slotGapSeconds,
                                     speakerSpacingMeters: probe.speakerSpacingMeters)
            }.value

            guard let estimate else {
                log.info("Acoustic probe: no reliable chirp pair")
                onStatus?(.noSignal)
                return
            }
            let bearing = AcousticDSP.bearing(lateralDegrees: estimate.lateralDegrees, hemisphere: hemisphere)
            log.info("Acoustic fix lateral=\(estimate.lateralDegrees, format: .fixed(precision: 1))° bearing=\(bearing, format: .fixed(precision: 1))° conf=\(estimate.confidence, format: .fixed(precision: 1))")
            onStatus?(.fix(Fix(bearingDegrees: bearing, estimate: estimate, date: Date())))
            reply(PositionUpdateFrame(peerID: localPeerID, azimuthDegrees: bearing,
                                      source: .acoustic, confidence: estimate.confidence))
        }
    }
}
