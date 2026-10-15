import AVFoundation
import Foundation
import os

/// "Always-On" mode: keeps the companion running while the screen is off or
/// another app is in front, so the Mac's connection, live mirroring and file
/// receiving keep working.
///
/// iOS only lets an app keep running in the background while it is actively
/// using audio (UIBackgroundModes = audio). In sound-positioning mode the
/// microphone stream already qualifies; otherwise this plays inaudible silence
/// mixed with other audio. Swiping the app away or rebooting still stops it.
@MainActor
final class BackgroundKeeper {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var observers: [NSObjectProtocol] = []
    private let log = Logger(subsystem: "com.rishikpulhani.AirCompassCompanion", category: "Background")

    /// Called when an interruption (phone call, Siri) ends so the owner can
    /// restart whichever audio keeps the app alive.
    var onShouldRestart: (() -> Void)?

    var isPlayingSilence: Bool { engine?.isRunning ?? false }

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
            MainActor.assumeIsolated { self?.onShouldRestart?() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.engine = nil
                self?.player = nil
                self?.onShouldRestart?()
            }
        })
    }

    /// Plays looping silence so the app keeps background execution time.
    func startSilence() {
        guard !isPlayingSilence else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // Keep the record-capable category so switching to sound mode
            // later doesn't fight over the shared session.
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return }
            buffer.frameLength = 44_100 // zero-filled: one second of silence
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            self.engine = engine
            self.player = player
            log.info("Always-On: silent audio started")
        } catch {
            log.error("Always-On failed: \(String(describing: error), privacy: .public)")
        }
    }

    func stopSilence() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
    }
}
