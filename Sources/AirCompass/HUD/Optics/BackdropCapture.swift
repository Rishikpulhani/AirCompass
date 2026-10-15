import AppKit
import CoreMedia
import os
import ScreenCaptureKit

/// Live capture of the screen rectangle under the HUD — the picture optical
/// glass bends. The HUD panel itself is excluded, so the glass never sees
/// itself (other windows, e.g. the Glass Lab, show through). Frames stay in memory (latest one only) and are never saved.
final class BackdropCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let latestFrame = OSAllocatedUnfairLock<CVPixelBuffer?>(uncheckedState: nil)
    private let queue = DispatchQueue(label: "com.aircompass.backdrop", qos: .userInteractive)
    private let log = Logger(subsystem: "com.aircompass.AirCompass", category: "Backdrop")

    @MainActor private var stream: SCStream?
    @MainActor private var displayID: CGDirectDisplayID?
    /// Screen rectangle (Cocoa coordinates) actually being captured.
    @MainActor private(set) var region: CGRect = .null
    /// Bumped on every start/stop so a slow async start can't resurrect a stopped stream.
    @MainActor private var generation = 0

    /// Most recent frame of the region, if capturing.
    var latest: CVPixelBuffer? { latestFrame.withLockUnchecked { $0 } }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt / adds AirCompass to the Screen Recording list.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Captures `frame` (Cocoa screen coordinates) on `screen`. Moving within
    /// the same display only updates the stream's source rectangle.
    @MainActor
    func capture(frame: CGRect, on screen: NSScreen, excluding windowNumber: Int) {
        guard Self.hasPermission,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return }
        if frame == region, id == displayID, stream != nil { return }

        let config = Self.configuration(frame: frame, screen: screen)
        region = frame
        if let stream, id == displayID {
            stream.updateConfiguration(config) { [log] error in
                if let error { log.error("Backdrop reconfigure failed: \(error.localizedDescription, privacy: .public)") }
            }
            return
        }

        stop()
        displayID = id
        generation += 1
        let ticket = generation
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard ticket == generation, let display = content.displays.first(where: { $0.displayID == id }) else { return }
                let hud = content.windows.filter { $0.windowID == CGWindowID(windowNumber) }
                let filter = SCContentFilter(display: display, excludingWindows: hud)
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                try await stream.startCapture()
                guard ticket == generation else {
                    try? await stream.stopCapture()
                    return
                }
                self.stream = stream
            } catch {
                log.error("Backdrop capture failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    func stop() {
        generation += 1
        if let stream {
            Task { try? await stream.stopCapture() }
        }
        stream = nil
        displayID = nil
        region = .null
        latestFrame.withLockUnchecked { $0 = nil }
    }

    private static func configuration(frame: CGRect, screen: NSScreen) -> SCStreamConfiguration {
        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        // Display-local, top-left origin.
        config.sourceRect = CGRect(x: frame.minX - screen.frame.minX, y: screen.frame.maxY - frame.maxY,
                                   width: frame.width, height: frame.height)
        config.width = Int(frame.width * scale)
        config.height = Int(frame.height * scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 3
        return config
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let pixels = sampleBuffer.imageBuffer else { return }
        // Idle/blank frames carry a status other than complete; keep the last good one.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw), status != .complete {
            return
        }
        latestFrame.withLockUnchecked { $0 = pixels }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        log.notice("Backdrop stream stopped: \(error.localizedDescription, privacy: .public)")
        let stopped = ObjectIdentifier(stream)
        Task { @MainActor in
            if let current = self.stream, ObjectIdentifier(current) == stopped {
                self.stream = nil
                self.displayID = nil
                self.region = .null
            }
        }
    }
}

/// Owns the capture and decides when it runs: optical engine on, HUD visible,
/// permission granted.
@MainActor
final class OpticalGlassEngine {
    static let shared = OpticalGlassEngine()

    let capture = BackdropCapture()
    private weak var window: NSWindow?
    private var windowVisible = false

    var enabled = false {
        didSet { if enabled != oldValue { refresh() } }
    }

    /// Called by the HUD panel whenever it shows, moves or hides.
    func track(_ window: NSWindow, visible: Bool) {
        self.window = window
        windowVisible = visible
        refresh()
    }

    static let margin: CGFloat = 160

    var isReady: Bool { enabled && BackdropCapture.hasPermission }

    /// Captured area in the panel's own top-left coordinates, points.
    func captureRect(in window: NSWindow?) -> CGRect? {
        guard let window, !capture.region.isNull else { return nil }
        let r = capture.region, w = window.frame
        return CGRect(x: r.minX - w.minX, y: w.maxY - r.maxY, width: r.width, height: r.height)
    }

    private func refresh() {
        if enabled, windowVisible, let window, let screen = window.screen ?? NSScreen.main {
            // A margin round the panel gives the rim's strongest bends real
            // pixels to pull in instead of a clamped, smeared edge.
            // Below the menu bar only: the notch strip is physically black and
            // the rim would otherwise pull it in as a dark crescent.
            let frame = window.frame.insetBy(dx: -Self.margin, dy: -Self.margin).intersection(screen.visibleFrame)
            capture.capture(frame: frame, on: screen, excluding: window.windowNumber)
        } else {
            capture.stop()
        }
    }
}
