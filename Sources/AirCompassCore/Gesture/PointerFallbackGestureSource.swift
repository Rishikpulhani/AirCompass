#if os(macOS)
import AppKit

/// Testing fallback for machines without a usable MultitouchSupport device
/// (external mouse, VM, CI, or a future macOS that drops the private symbols).
///
/// Holding the trigger modifiers (⌃⌥ by default) stands in for "three fingers
/// down"; moving the pointer drags the vector; releasing the modifiers lifts the
/// fingers. Pointer motion is fed through the same `ThreeFingerGestureRecognizer`
/// as real touches, so commit radius, hysteresis and sector math are identical.
///
/// Global `flagsChanged` monitoring requires the Accessibility permission.
@MainActor
public final class PointerFallbackGestureSource: GestureInputSource {
    public var onEvent: ((GestureEvent) -> Void)?

    public var sectorMode: SectorMode {
        get { recognizer.sectorMode }
        set { recognizer.sectorMode = newValue }
    }

    public var triggerModifiers: NSEvent.ModifierFlags
    /// Pointer travel (points) that maps to 1.0 trackpad-height units.
    /// At 400 pt the default 0.12 commit radius is ~48 pt of mouse travel.
    public var pointsPerUnit: CGFloat

    public private(set) var isRunning = false

    private var recognizer: ThreeFingerGestureRecognizer
    private var monitors: [Any] = []
    private var fingersDown = false
    private var gestureActive = false

    public init(
        triggerModifiers: NSEvent.ModifierFlags = [.control, .option],
        pointsPerUnit: CGFloat = 400,
        configuration: ThreeFingerGestureRecognizer.Configuration = .init(),
        sectorMode: SectorMode = .four
    ) {
        self.triggerModifiers = triggerModifiers
        self.pointsPerUnit = pointsPerUnit
        var config = configuration
        config.settleDuration = 0 // A modifier press is already a deliberate, discrete signal.
        self.recognizer = ThreeFingerGestureRecognizer(configuration: config, sectorMode: sectorMode)
    }

    public func start() throws {
        guard !isRunning else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]

        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        // Local monitor covers the case where one of our own windows is key.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
        isRunning = true
    }

    public func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let event = recognizer.reset() { emit(event) }
        fingersDown = false
        isRunning = false
    }

    public func suppressCurrentGesture() {
        _ = recognizer.suppress()
        if gestureActive {
            gestureActive = false
            onEvent?(.cancelled(.suppressed))
        }
    }

    private func handle(_ event: NSEvent) {
        if event.type == .flagsChanged {
            let held = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .isSuperset(of: triggerModifiers)
            guard held != fingersDown else { return }
            fingersDown = held
        } else if !fingersDown {
            return
        }
        feed(timestamp: event.timestamp)
    }

    private func feed(timestamp: TimeInterval) {
        var contacts: [TouchContact] = []
        if fingersDown {
            // Screen coordinates are y-up, matching trackpad space (+y = North).
            let p = NSEvent.mouseLocation
            let x = Double(p.x / pointsPerUnit), y = Double(p.y / pointsPerUnit)
            let count = Int32(recognizer.configuration.fingerCount)
            contacts = (0..<count).map { TouchContact(id: $0, x: x, y: y) }
        }
        if let event = recognizer.process(TouchFrame(timestamp: timestamp, contacts: contacts)) {
            emit(event)
        }
    }

    private func emit(_ event: GestureEvent) {
        switch event {
        case .began: gestureActive = true
        case .changed: guard gestureActive else { return }
        case .committed, .cancelled:
            guard gestureActive else { return }
            gestureActive = false
        }
        onEvent?(event)
    }
}
#endif
