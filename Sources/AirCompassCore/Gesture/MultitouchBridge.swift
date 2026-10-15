#if os(macOS)
import AppKit
import CMultitouchSupport
import Darwin
import os

public enum MultitouchError: Error, CustomStringConvertible {
    case frameworkUnavailable(String)
    case symbolMissing(String)
    case noDevices

    public var description: String {
        switch self {
        case let .frameworkUnavailable(reason): "MultitouchSupport.framework could not be loaded: \(reason)"
        case let .symbolMissing(name): "MultitouchSupport.framework is missing symbol \(name)"
        case .noDevices: "No multitouch devices found"
        }
    }
}

// MARK: - Dynamic symbol table

/// Function pointers resolved from the private framework at runtime.
struct MultitouchFramework: @unchecked Sendable {
    static let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    let createList: MTDeviceCreateListFn
    let registerCallback: MTRegisterContactFrameCallbackFn
    let unregisterCallback: MTUnregisterContactFrameCallbackFn
    let start: MTDeviceStartFn
    let stop: MTDeviceStopFn
    let isBuiltIn: MTDeviceIsBuiltInFn?
    let surfaceDimensions: MTDeviceGetSensorSurfaceDimensionsFn?

    /// Loaded once per process; dlopen handles are intentionally never closed.
    static let shared: Result<MultitouchFramework, MultitouchError> = load()

    private static func load() -> Result<MultitouchFramework, MultitouchError> {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown error"
            return .failure(.frameworkUnavailable(reason))
        }

        func required<T>(_ name: String, as _: T.Type) throws(MultitouchError) -> T {
            guard let sym = dlsym(handle, name) else { throw .symbolMissing(name) }
            return unsafeBitCast(sym, to: T.self)
        }
        func optional<T>(_ name: String, as _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }

        do throws(MultitouchError) {
            return .success(MultitouchFramework(
                createList: try required("MTDeviceCreateList", as: MTDeviceCreateListFn.self),
                registerCallback: try required("MTRegisterContactFrameCallback", as: MTRegisterContactFrameCallbackFn.self),
                unregisterCallback: try required("MTUnregisterContactFrameCallback", as: MTUnregisterContactFrameCallbackFn.self),
                start: try required("MTDeviceStart", as: MTDeviceStartFn.self),
                stop: try required("MTDeviceStop", as: MTDeviceStopFn.self),
                isBuiltIn: optional("MTDeviceIsBuiltIn", as: MTDeviceIsBuiltInFn.self),
                surfaceDimensions: optional("MTDeviceGetSensorSurfaceDimensions", as: MTDeviceGetSensorSurfaceDimensionsFn.self)
            ))
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - Engine (runs on the framework's callback thread)

/// Owns the device list and the recognizer. MultitouchSupport's callback has no
/// user-data parameter, so the engine is a process-wide singleton reached from a
/// file-scope C callback.
final class MultitouchEngine: @unchecked Sendable {
    static let shared = MultitouchEngine()

    struct DeviceInfo {
        let device: MTDeviceRef
        let aspectRatio: Double
        let isBuiltIn: Bool
    }

    private struct State {
        var recognizer = ThreeFingerGestureRecognizer()
        var devices: [DeviceInfo] = []
        /// Retains the CFArray that owns the device refs.
        var deviceList: CFMutableArray?
        /// Device a gesture is in progress on; frames from others are ignored.
        var lockedDevice: MTDeviceRef?
        var handler: (@Sendable (GestureEvent) -> Void)?
        var scratch: [TouchContact] = []
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let log = Logger(subsystem: "com.aircompass.AirCompass", category: "Multitouch")

    var isRunning: Bool { state.withLockUnchecked { !$0.devices.isEmpty } }

    func configure(_ configuration: ThreeFingerGestureRecognizer.Configuration, sectorMode: SectorMode) {
        state.withLockUnchecked {
            $0.recognizer.configuration = configuration
            $0.recognizer.sectorMode = sectorMode
        }
    }

    func setSectorMode(_ count: SectorMode) {
        state.withLockUnchecked { $0.recognizer.sectorMode = count }
    }

    func start(handler: @escaping @Sendable (GestureEvent) -> Void) throws {
        let fw = try MultitouchFramework.shared.get()
        stop()

        guard let list = fw.createList()?.takeRetainedValue() else { throw MultitouchError.noDevices }
        let count = CFArrayGetCount(list)
        guard count > 0 else { throw MultitouchError.noDevices }

        var infos: [DeviceInfo] = []
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = MTDeviceRef(mutating: raw)

            var aspect = 1.0
            var w: Int32 = 0, h: Int32 = 0
            if let dims = fw.surfaceDimensions, dims(device, &w, &h) == 0, w > 0, h > 0 {
                aspect = Double(w) / Double(h)
            }
            let builtIn = fw.isBuiltIn?(device) ?? false
            infos.append(DeviceInfo(device: device, aspectRatio: aspect, isBuiltIn: builtIn))
        }

        state.withLockUnchecked {
            $0.deviceList = list
            $0.devices = infos
            $0.handler = handler
            $0.lockedDevice = nil
            _ = $0.recognizer.reset()
        }

        for info in infos {
            fw.registerCallback(info.device, multitouchContactFrameCallback)
            let status = fw.start(info.device, 0)
            log.info("Started multitouch device builtIn=\(info.isBuiltIn) aspect=\(info.aspectRatio, format: .fixed(precision: 2)) status=\(status)")
        }
    }

    func stop() {
        guard case let .success(fw) = MultitouchFramework.shared else { return }
        let (devices, handler, pending) = state.withLockUnchecked { s in
            let result = (s.devices, s.handler, s.recognizer.reset())
            s.devices = []
            s.deviceList = nil
            s.lockedDevice = nil
            s.handler = nil
            return result
        }
        for info in devices {
            fw.unregisterCallback(info.device, multitouchContactFrameCallback)
            _ = fw.stop(info.device)
        }
        if let pending, let handler { handler(pending) }
    }

    /// Host veto; the main-actor source emits its own cancellation.
    func suppress() {
        state.withLockUnchecked { s in
            _ = s.recognizer.suppress()
        }
    }

    /// Hot path: called ~90–120×/s per device on the framework thread.
    fileprivate func handleFrame(device: MTDeviceRef, touches: UnsafeMutablePointer<MTTouch>?, count: Int, timestamp: Double) {
        let (event, handler): (GestureEvent?, (@Sendable (GestureEvent) -> Void)?) = state.withLockUnchecked { s in
            if let locked = s.lockedDevice, locked != device { return (nil, nil) }
            guard let info = s.devices.first(where: { $0.device == device }) else { return (nil, nil) }

            s.scratch.removeAll(keepingCapacity: true)
            if let touches {
                for i in 0..<count {
                    let t = touches[i]
                    // Only count fingers physically on the surface.
                    guard t.state == Int32(MTTouchStateMakeTouch.rawValue)
                        || t.state == Int32(MTTouchStateTouching.rawValue) else { continue }
                    s.scratch.append(TouchContact(
                        id: t.pathIndex,
                        x: Double(t.normalized.position.x),
                        y: Double(t.normalized.position.y)
                    ))
                }
            }

            let frame = TouchFrame(timestamp: timestamp, contacts: s.scratch, aspectRatio: info.aspectRatio)
            let event = s.recognizer.process(frame)
            s.lockedDevice = s.recognizer.isEngaged ? device : nil
            return (event, s.handler)
        }
        if let event, let handler { handler(event) }
    }
}

/// File-scope C callback handed to MTRegisterContactFrameCallback.
private func multitouchContactFrameCallback(
    device: MTDeviceRef?,
    touches: UnsafeMutablePointer<MTTouch>?,
    numTouches: Int32,
    timestamp: Double,
    frame: Int32
) -> Int32 {
    guard let device else { return 0 }
    MultitouchEngine.shared.handleFrame(device: device, touches: touches, count: Int(numTouches), timestamp: timestamp)
    return 0
}

// MARK: - Main-actor façade

/// Global 3-finger trackpad hook backed by MultitouchSupport.framework.
///
/// Works without window focus or Accessibility permission. Events are hopped
/// to the main actor in order. Devices are re-enumerated on wake, since the
/// framework silently stops delivering frames across sleep.
@MainActor
public final class MultitouchGestureSource: GestureInputSource {
    public var onEvent: ((GestureEvent) -> Void)?

    public var sectorMode: SectorMode {
        didSet { engine.setSectorMode(sectorMode) }
    }

    public var configuration: ThreeFingerGestureRecognizer.Configuration {
        didSet { engine.configure(configuration, sectorMode: sectorMode) }
    }

    public private(set) var isRunning = false

    /// True if the private framework and all required symbols resolve.
    public static var isAvailable: Bool {
        if case .success = MultitouchFramework.shared { return true }
        return false
    }

    private let engine = MultitouchEngine.shared
    /// Filters stale events still queued on the main queue after a veto.
    private var gestureActive = false
    private var wakeObserver: NSObjectProtocol?

    public init(configuration: ThreeFingerGestureRecognizer.Configuration = .init(), sectorMode: SectorMode = .four) {
        self.configuration = configuration
        self.sectorMode = sectorMode
    }

    public func start() throws {
        engine.configure(configuration, sectorMode: sectorMode)
        try engine.start { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.deliver(event) }
            }
        }
        isRunning = true

        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.restartAfterWake() }
            }
        }
    }

    public func stop() {
        engine.stop()
        isRunning = false
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    public func suppressCurrentGesture() {
        engine.suppress()
        if gestureActive {
            gestureActive = false
            onEvent?(.cancelled(.suppressed))
        }
    }

    private func deliver(_ event: GestureEvent) {
        switch event {
        case .began:
            gestureActive = true
        case .changed:
            guard gestureActive else { return }
        case .committed, .cancelled:
            guard gestureActive else { return }
            gestureActive = false
        }
        onEvent?(event)
    }

    private func restartAfterWake() {
        guard isRunning else { return }
        do {
            try start()
        } catch {
            Logger(subsystem: "com.aircompass.AirCompass", category: "Multitouch")
                .error("Restart after wake failed: \(String(describing: error), privacy: .public)")
        }
    }
}
#endif
