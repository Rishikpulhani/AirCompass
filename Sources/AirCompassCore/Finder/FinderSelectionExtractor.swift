#if os(macOS)
import AppKit
import ApplicationServices
import os

/// Fast lookup of the files currently selected in Finder.
///
/// Two strategies, tried in `strategyOrder`:
/// - **AppleEvents**: a pre-compiled in-memory `NSAppleScript` running
///   `selection as alias list`. Authoritative for every Finder view and the
///   Desktop. Needs the Automation (Finder) permission.
/// - **Accessibility**: walks the focused Finder window's AX tree for
///   `AXSelectedChildren` / `AXSelectedRows` and resolves item names against the
///   window's `AXDocument` folder. No AppleEvent round trip, but best-effort:
///   items inside expanded list-view subfolders, and Desktop selection, are
///   not resolvable. Needs the Accessibility permission.
///
/// Before querying, the extractor checks that Finder is the user's current
/// context so 3-finger drags in other apps stay with the system.
@MainActor
public final class FinderSelectionExtractor {
    public enum Strategy: String, Sendable, CaseIterable {
        case appleEvents
        case accessibility
    }

    public enum ContextPolicy: Sendable, Equatable {
        /// Finder must be the frontmost app.
        case requireFrontmost
        /// Finder is frontmost, or was frontmost within the given interval
        /// (covers clicking our status item right before gesturing).
        case allowRecent(TimeInterval)
        /// Always query, regardless of the frontmost app.
        case any
    }

    public struct Selection: Sendable, Equatable {
        public var urls: [URL]
        public var strategy: Strategy
        public var elapsed: Duration
    }

    public enum Outcome: Sendable {
        case selection(Selection)
        /// Finder is in context but nothing is selected.
        case empty
        /// Finder is not the active context; leave the gesture to the system.
        case finderNotInContext
        /// Every strategy failed.
        case failed([Strategy: FinderSelectionError])

        public var urls: [URL] {
            if case let .selection(s) = self { return s.urls }
            return []
        }
    }

    public var strategyOrder: [Strategy]
    public var contextPolicy: ContextPolicy

    nonisolated static let finderBundleID = "com.apple.finder"

    private let log = Logger(subsystem: "com.aircompass.AirCompass", category: "Finder")
    private let script: NSAppleScript?
    private var finderDeactivatedAt: Date?
    private var activationObserver: NSObjectProtocol?

    public init(
        strategyOrder: [Strategy] = [.appleEvents, .accessibility],
        contextPolicy: ContextPolicy = .allowRecent(1.5)
    ) {
        self.strategyOrder = strategyOrder
        self.contextPolicy = contextPolicy

        // Compile once so each gesture only pays for execution.
        let source = """
        tell application id "\(Self.finderBundleID)" to return selection as alias list
        """
        let compiled = NSAppleScript(source: source)
        var error: NSDictionary?
        if compiled?.compileAndReturnError(&error) == true {
            script = compiled
        } else {
            script = nil
            log.error("Failed to compile Finder selection script: \(String(describing: error), privacy: .public)")
        }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Self.finderBundleID else { return }
            MainActor.assumeIsolated { self?.finderDeactivatedAt = Date() }
        }
    }

    // Observer is torn down with the process; the extractor lives for the app's lifetime.

    /// Runs the AppleEvents strategy once so the Automation consent prompt
    /// appears at launch instead of in the middle of the first gesture.
    public func warmUp() {
        guard finderApplication != nil else { return }
        _ = try? selectionViaAppleEvents()
    }

    // MARK: - Query

    public func currentSelection() -> Outcome {
        guard finderApplication != nil, isFinderInContext else { return .finderNotInContext }

        var failures: [Strategy: FinderSelectionError] = [:]
        for strategy in strategyOrder {
            let clock = ContinuousClock()
            let start = clock.now
            do {
                let urls = switch strategy {
                case .appleEvents: try selectionViaAppleEvents()
                case .accessibility: try selectionViaAccessibility()
                }
                let elapsed = clock.now - start
                log.debug("Finder selection via \(strategy.rawValue, privacy: .public): \(urls.count) item(s) in \(elapsed)")
                return urls.isEmpty
                    ? .empty
                    : .selection(Selection(urls: urls, strategy: strategy, elapsed: elapsed))
            } catch {
                failures[strategy] = error
                log.notice("Finder selection via \(strategy.rawValue, privacy: .public) failed: \(error.description, privacy: .public)")
            }
        }
        return .failed(failures)
    }

    /// Selection regardless of which app is frontmost (for explicit menu actions).
    public func currentSelectionIgnoringContext() -> [URL] {
        let saved = contextPolicy
        contextPolicy = .any
        defer { contextPolicy = saved }
        return currentSelection().urls
    }

    public var isFinderInContext: Bool {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        switch contextPolicy {
        case .any:
            return true
        case .requireFrontmost:
            return frontmost == Self.finderBundleID
        case let .allowRecent(window):
            if frontmost == Self.finderBundleID { return true }
            guard let at = finderDeactivatedAt else { return false }
            return Date().timeIntervalSince(at) <= window
        }
    }

    private var finderApplication: NSRunningApplication? {
        // Never message Finder unless it's running: an AppleEvent would launch it.
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.finderBundleID).first
    }

    // MARK: - AppleEvents strategy

    func selectionViaAppleEvents() throws(FinderSelectionError) -> [URL] {
        guard let script else { throw .scriptUnavailable }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "unknown"
            if code == -1743 || code == -1744 { throw .automationNotPermitted }
            throw .appleEvent(code: code, message: message)
        }

        // A list descriptor; a lone alias is tolerated in case Finder skips the list wrap.
        let items: [NSAppleEventDescriptor] = result.numberOfItems > 0
            ? (1...result.numberOfItems).compactMap { result.atIndex($0) }
            : (result.descriptorType == Self.typeList ? [] : [result])

        return items.compactMap { item in
            if let url = item.fileURLValue { return url.standardizedFileURL }
            return item.coerce(toDescriptorType: Self.typeFileURL)?.fileURLValue?.standardizedFileURL
        }
    }

    private static let typeList = fourCharCode("list")
    private static let typeFileURL = fourCharCode("furl")

    private static func fourCharCode(_ s: StaticString) -> DescType {
        s.withUTF8Buffer { $0.reduce(0) { ($0 << 8) | DescType($1) } }
    }

    // MARK: - Accessibility strategy

    func selectionViaAccessibility() throws(FinderSelectionError) -> [URL] {
        guard AXIsProcessTrusted() else { throw .accessibilityNotTrusted }
        guard let finder = finderApplication else { throw .finderNotRunning }

        let app = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)

        guard let window: AXUIElement = AX.attribute(app, kAXFocusedWindowAttribute)
            ?? AX.attribute(app, kAXMainWindowAttribute)
        else { throw .accessibilityNoWindow }

        guard let documentString: String = AX.attribute(window, kAXDocumentAttribute),
              let folder = URL(string: documentString), folder.isFileURL
        else { throw .accessibilityNoFolder }

        guard let selected = Self.deepestSelection(in: window) else { return [] }

        let fm = FileManager.default
        var urls: [URL] = []
        for element in selected {
            if let url: URL = AX.attribute(element, kAXURLAttribute), url.isFileURL {
                urls.append(url.standardizedFileURL)
                continue
            }
            guard let name = Self.itemName(of: element) else { continue }
            let candidate = folder.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) {
                urls.append(candidate.standardizedFileURL)
            }
        }
        return urls
    }

    // MARK: - Selection frame

    /// Screen rectangle (Cocoa coordinates, bottom-left origin) around the
    /// selected items in Finder's focused window — or on the Desktop — clipped
    /// to what is visible. Nil without Accessibility or a visible selection.
    public func selectionFrame() -> CGRect? {
        guard AXIsProcessTrusted(), let finder = finderApplication else { return nil }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.15)

        let window: AXUIElement? = AX.attribute(app, kAXFocusedWindowAttribute)
        // The Desktop is not a window; search the whole app when the focused
        // window has no selection.
        for root in [window, app].compactMap({ $0 }) {
            guard let selected = Self.deepestSelection(in: root) else { continue }
            var frame = selected.compactMap(Self.screenFrame(ofItem:)).reduce(CGRect.null) { $0.union($1) }
            if let window, root == window, let bounds = AX.frame(of: window) {
                frame = frame.intersection(bounds)
            }
            guard !frame.isNull, !frame.isEmpty else { continue }
            return AX.cocoaRect(fromAX: frame)
        }
        return nil
    }

    /// Item frame; for list-view rows only the name cell, not the full width.
    private static func screenFrame(ofItem element: AXUIElement) -> CGRect? {
        let role: String? = AX.attribute(element, kAXRoleAttribute)
        if role == kAXRowRole,
           let cells: [AXUIElement] = AX.attribute(element, kAXChildrenAttribute),
           let first = cells.first, let frame = AX.frame(of: first) {
            return frame
        }
        return AX.frame(of: element)
    }

    /// Breadth-first search for containers with a non-empty selection. Returns
    /// the last one found, which in column view is the rightmost (deepest) column.
    private static func deepestSelection(in root: AXUIElement) -> [AXUIElement]? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var head = 0
        var found: [AXUIElement]?
        let maxDepth = 10, maxNodes = 600

        while head < queue.count, head < maxNodes {
            let (element, depth) = queue[head]
            head += 1

            for attribute in [kAXSelectedChildrenAttribute, kAXSelectedRowsAttribute] {
                if let items: [AXUIElement] = AX.attribute(element, attribute), !items.isEmpty {
                    found = items
                }
            }
            guard depth < maxDepth, let children: [AXUIElement] = AX.attribute(element, kAXChildrenAttribute) else { continue }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return found
    }

    /// Filename shown for an icon-view item or list-view row.
    private static func itemName(of element: AXUIElement) -> String? {
        for attribute in [kAXFilenameAttribute, kAXTitleAttribute] {
            if let s: String = AX.attribute(element, attribute), !s.isEmpty { return s }
        }
        // List-view rows: the name lives in a text field a few levels down.
        var queue: [(AXUIElement, Int)] = [(element, 0)]
        var head = 0
        while head < queue.count {
            let (node, depth) = queue[head]
            head += 1
            let role: String? = AX.attribute(node, kAXRoleAttribute)
            if role == kAXTextFieldRole || role == kAXStaticTextRole,
               let value: String = AX.attribute(node, kAXValueAttribute), !value.isEmpty {
                return value
            }
            if depth < 3, let children: [AXUIElement] = AX.attribute(node, kAXChildrenAttribute) {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        return nil
    }

    // MARK: - Permissions

    /// Whether this process is trusted for Accessibility; optionally shows the
    /// system prompt that deep-links to Privacy & Security.
    @discardableResult
    public static func checkAccessibilityTrust(prompt: Bool) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

public enum FinderSelectionError: Error, Sendable, Equatable, CustomStringConvertible {
    case finderNotRunning
    case scriptUnavailable
    case automationNotPermitted
    case appleEvent(code: Int, message: String)
    case accessibilityNotTrusted
    case accessibilityNoWindow
    case accessibilityNoFolder

    public var description: String {
        switch self {
        case .finderNotRunning: "Finder is not running"
        case .scriptUnavailable: "Finder selection script failed to compile"
        case .automationNotPermitted: "Automation permission for Finder was denied (System Settings › Privacy & Security › Automation)"
        case let .appleEvent(code, message): "AppleEvent error \(code): \(message)"
        case .accessibilityNotTrusted: "Accessibility permission not granted (System Settings › Privacy & Security › Accessibility)"
        case .accessibilityNoWindow: "Finder has no focused window"
        case .accessibilityNoFolder: "Finder window has no resolvable folder"
        }
    }
}

/// Typed wrappers over `AXUIElementCopyAttributeValue`.
enum AX {
    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        return cast(value)
    }

    private static func cast<T>(_ value: CFTypeRef) -> T? {
        if T.self == AXUIElement.self {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement) as? T
        }
        if T.self == [AXUIElement].self {
            guard let array = value as? [AnyObject] else { return nil }
            let elements = array.compactMap { item -> AXUIElement? in
                guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
                return (item as! AXUIElement)
            }
            return elements as? T
        }
        if T.self == URL.self {
            guard CFGetTypeID(value) == CFURLGetTypeID() else { return nil }
            return ((value as! CFURL) as URL) as? T
        }
        return value as? T
    }

    /// Element frame in AX coordinates (top-left origin of the primary screen).
    static func frame(of element: AXUIElement) -> CGRect? {
        var position = CGPoint.zero, size = CGSize.zero
        guard let p: AXValue = attribute(element, kAXPositionAttribute),
              let s: AXValue = attribute(element, kAXSizeAttribute),
              AXValueGetValue(p, .cgPoint, &position),
              AXValueGetValue(s, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// AX (top-left origin) → Cocoa (bottom-left origin) screen rectangle.
    @MainActor
    static func cocoaRect(fromAX rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
#endif
