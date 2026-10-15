import AirCompassCore
import AppKit
import SwiftUI

/// Developer aid: `AIRCOMPASS_SNAPSHOT=<dir> AirCompass` renders every HUD
/// style mid-drag over a sample backdrop into `<dir>/<code>.png`, then quits.
/// (Behind-window blur can't be captured offscreen, so glass looks clearer
/// than on screen.)
///
/// `AIRCOMPASS_SNAPSHOT_LIVE=1` instead shows the real panel, holding each
/// style for 2.5 s and printing `<code> x y w h` (top-left screen points) so
/// `screencapture -R` can grab it with the true behind-window blur.
@MainActor
enum HUDSnapshot {
    static func runIfRequested() -> Bool {
        if ProcessInfo.processInfo.environment["AIRCOMPASS_SNAPSHOT_LIVE"] != nil {
            runLive()
            return true
        }
        guard let dir = ProcessInfo.processInfo.environment["AIRCOMPASS_SNAPSHOT"] else { return false }
        let model = CompassHUDModel()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: CompassHUDPanel.size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let host = NSHostingView(rootView: ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.20, blue: 0.36), Color(red: 0.42, green: 0.27, blue: 0.40)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            CompassHUDView(model: model)
        })
        host.frame = NSRect(origin: .zero, size: CompassHUDPanel.size)
        window.contentView = host

        Task {
            for style in HUDStyle.allCases {
                configure(model, style: style)
                try? await Task.sleep(for: .milliseconds(1600))
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(style.code).png"))
            }
            NSApp.terminate(nil)
        }
        return true
    }

    private static func runLive() {
        let model = CompassHUDModel()
        let panel = CompassHUDPanel(rootView: CompassHUDView(model: model))
        // AIRCOMPASS_SNAPSHOT_ANCHOR = "x,y" (Cocoa screen point) or
        // "selection" (the current Finder selection) anchors the glass there.
        let anchorSpec = ProcessInfo.processInfo.environment["AIRCOMPASS_SNAPSHOT_ANCHOR"]
        var anchor: CGPoint?
        if anchorSpec == "selection" {
            let frame = FinderSelectionExtractor().selectionFrame()
            print("selection frame: \(String(describing: frame))")
            anchor = frame.map { CGPoint(x: $0.midX, y: $0.midY) }
        } else if let parts = anchorSpec?.split(separator: ",").compactMap({ Double($0) }), parts.count == 2 {
            anchor = CGPoint(x: parts[0], y: parts[1])
        }
        // AIRCOMPASS_SNAPSHOT_CLEAN=1 hides other apps' windows (wallpaper
        // only) for the run and unhides exactly those afterwards.
        // AIRCOMPASS_SNAPSHOT_STYLES=A1,B1 limits the styles.
        // AIRCOMPASS_SNAPSHOT_LAB=1 also opens the Glass Lab ("LAB x y w h").
        var hidden: [NSRunningApplication] = []
        if env["AIRCOMPASS_SNAPSHOT_CLEAN"] == "1" {
            hidden = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && !$0.isHidden && $0 != .current
            }
            // Hiding the active app is refused, so take over as active app
            // and use the system's Hide Others.
            NSApp.activate(ignoringOtherApps: true)
            NSWorkspace.shared.hideOtherApplications()
        }
        // AIRCOMPASS_SNAPSHOT_BACKDROP=<image> fills the screen behind the HUD
        // with that picture (e.g. a frame of a video wallpaper).
        let backdrop = env["AIRCOMPASS_SNAPSHOT_BACKDROP"].flatMap(Self.backdropWindow)
        backdrop?.orderFrontRegardless()
        let only = env["AIRCOMPASS_SNAPSHOT_STYLES"].map { Set($0.split(separator: ",").map(String.init)) }
        let lab = GlassLabWindow()
        Task {
            if !hidden.isEmpty { try? await Task.sleep(for: .milliseconds(1200)) }
            for style in HUDStyle.allCases where only?.contains(style.code) ?? true {
                configure(model, style: style)
                if env["AIRCOMPASS_SNAPSHOT_LAB"] == "1" {
                    model.onSetGlass = { model.glass = $0 }
                    lab.show(model: model)
                }
                model.pinnedToTop = anchor == nil
                panel.present(anchor: anchor)
                try? await Task.sleep(for: .milliseconds(1200))
                let f = panel.frame
                let top = (NSScreen.screens.first?.frame.maxY ?? 0) - f.maxY
                print("\(style.code) \(Int(f.minX)) \(Int(top)) \(Int(f.width)) \(Int(f.height))")
                fflush(stdout)
                try? await Task.sleep(for: .milliseconds(1300))
            }
            hidden.forEach { $0.unhide() }
            backdrop?.orderOut(nil)
            try? await Task.sleep(for: .milliseconds(300))
            NSApp.terminate(nil)
        }
    }

    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    private static func backdropWindow(path: String) -> NSWindow? {
        guard let image = NSImage(contentsOfFile: path), let screen = NSScreen.main else { return nil }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Aspect-fill like the desktop.
        let layer = CALayer()
        layer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        layer.contentsGravity = .resizeAspectFill
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.layer = layer
        view.wantsLayer = true
        window.contentView = view
        window.setFrame(screen.frame, display: true)
        return window
    }

    private static func configure(_ model: CompassHUDModel, style: HUDStyle) {
        var peers = [
            PeerDevice(id: "phone", name: "Rishik's iPhone", deviceKind: .iPhone, azimuthDegrees: 84, distanceMeters: 1.1, hasPosition: true),
            PeerDevice(id: "pad", name: "iPad", deviceKind: .iPad, azimuthDegrees: 268, distanceMeters: 2.4, hasPosition: true),
            PeerDevice(id: "mac", name: "Studio Mac", deviceKind: .mac, azimuthDegrees: 192, hasPosition: true),
        ]
        RadarLayout.apply(to: &peers, mode: .four)

        model.mode = .preview
        model.showsStyleSwitcher = env["AIRCOMPASS_SNAPSHOT_SWITCHER"] != "0"
        // AIRCOMPASS_SNAPSHOT_GLASS = "<background 0…1>[,frosted]"
        if let spec = ProcessInfo.processInfo.environment["AIRCOMPASS_SNAPSHOT_GLASS"] {
            let parts = spec.split(separator: ",")
            model.glass = GlassAppearance(background: parts.first.flatMap { Double($0) } ?? 0,
                                          frosted: parts.contains("frosted"),
                                          engine: parts.contains("optical") ? .optical : .system)
            OpticalGlassEngine.shared.enabled = model.glass.isOptical
        }
        model.sectorMode = .four
        model.family = style.family
        model.vector = GestureVector(r: 0.11, theta: AngleMath.radians(style.family == .uniform ? 150 : 88))
        model.isArmed = false
        model.files = [URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")]

        switch style {
        case let .uniform(s):
            model.uniformStyle = s
            let v = model.vector!
            let scales = UniformLayout.scales(style: s, count: peers.count, theta: v.theta, r: v.r)
            let index = UniformLayout.targetIndex(scales: scales)
            model.nodes = UniformLayout.nodes(for: peers, style: s, scales: scales, targetIndex: index)
            model.activeSector = nil
            model.targetName = index.map { peers[$0].name }
        case let .spatial(s):
            model.spatialStyle = s
            let v = model.vector!
            let scales = DockMagnification.scales(for: peers, theta: v.theta, r: v.r, mode: .four)
            let sector = SectorMode.four.sector(for: v.theta)
            let target = DockMagnification.target(in: peers, scales: scales, sector: sector)
            model.nodes = peers.map { CompassNodeModel(peer: $0, scale: scales[$0.id] ?? 1, isTarget: $0.id == target?.id) }
            model.activeSector = sector
            model.targetName = target?.name
        }
    }
}
