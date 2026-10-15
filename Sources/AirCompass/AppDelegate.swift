import AirCompassCore
import AppKit
import SwiftUI

/// Menu-bar agent (LSUIElement). Owns long-lived services and the status menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings()
    private let finder = FinderSelectionExtractor()
    private lazy var services = PeerServices(settings: settings)
    private lazy var coordinator = GestureCoordinator(finder: finder, services: services, settings: settings)

    private var statusItem: NSStatusItem!
    private var statusText = "Starting…"

    func applicationDidFinishLaunching(_ notification: Notification) {
        if HUDSnapshot.runIfRequested() { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "location.north.circle", accessibilityDescription: "AirCompass")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        coordinator.onStatus = { [weak self] text in self?.statusText = text }
        services.onPeersChanged = { [weak self] in self?.coordinator.peersChanged() }
        services.start()
        coordinator.sectorMode = settings.sectorMode
        activateInputMode(settings.inputMode)
        finder.warmUp()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.source?.stop()
        services.network.stop()
    }

    // MARK: - Input

    private func activateInputMode(_ mode: AppSettings.InputMode) {
        let source: GestureInputSource = switch mode {
        case .trackpad: MultitouchGestureSource(sectorMode: settings.sectorMode)
        case .pointerFallback: PointerFallbackGestureSource(sectorMode: settings.sectorMode)
        }

        if let error = coordinator.use(source) {
            if mode == .trackpad {
                statusText = "Trackpad unavailable — using pointer fallback"
                settings.inputMode = .pointerFallback
                activateInputMode(.pointerFallback)
            } else {
                statusText = "Input error: \(error)"
            }
            return
        }
        settings.inputMode = mode
        statusText = "Ready"
        if mode == .pointerFallback {
            FinderSelectionExtractor.checkAccessibilityTrust(prompt: true)
        }
    }

    // MARK: - Menu (rebuilt every time it opens, so peer data is live)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        menu.addItem(item("Preview Compass HUD", #selector(togglePreview), state: coordinator.previewMode))

        // HUD look
        let tracking = NSMenu()
        for mode in TrackingMode.allCases {
            let i = item(mode.title, #selector(selectTrackingMode(_:)), state: settings.trackingMode == mode)
            i.representedObject = mode.rawValue
            tracking.addItem(i)
        }
        let resolved = settings.trackingMode.resolve(peers: services.radar.peers)
        tracking.addItem(.separator())
        tracking.addItem(header("Now showing: \(resolved == .spatial ? "Spatial Compass" : "Non-Directional")"))
        menu.addItem(submenu("Tracking Mode", tracking))

        let uniformStyles = NSMenu()
        for (n, style) in NonDirectionalStyle.allCases.enumerated() {
            let i = item("\(n + 1). \(style.title)", #selector(selectUniformStyle(_:)), state: settings.nonDirectionalStyle == style)
            i.representedObject = style.rawValue
            uniformStyles.addItem(i)
        }
        menu.addItem(submenu("Mode A Style (Non-Directional)", uniformStyles))

        let spatialStyles = NSMenu()
        for (n, style) in SpatialCompassStyle.allCases.enumerated() {
            let i = item("\(n + 1). \(style.title)", #selector(selectSpatialStyle(_:)), state: settings.spatialStyle == style)
            i.representedObject = style.rawValue
            spatialStyles.addItem(i)
        }
        menu.addItem(submenu("Mode B Style (Spatial Compass)", spatialStyles))

        let glassMenu = NSMenu()
        let glassItem = NSMenuItem()
        let controls = NSHostingView(rootView: GlassControlsMenuView(
            appearance: settings.glassAppearance,
            onChange: { [weak self] glass in self?.coordinator.setGlass(glass) },
            onOpenLab: { [weak self] in
                menu.cancelTracking()
                self?.coordinator.openGlassLab()
            }
        ))
        controls.frame.size = controls.fittingSize
        glassItem.view = controls
        glassMenu.addItem(glassItem)
        glassMenu.addItem(.separator())
        glassMenu.addItem(item("Open Glass Lab…", #selector(openGlassLab)))
        menu.addItem(submenu("Glass Appearance", glassMenu))

        // Sector division
        let sectors = NSMenu()
        for mode in SectorMode.allCases {
            let i = item(mode.title, #selector(selectSectorMode(_:)), state: settings.sectorMode == mode)
            i.tag = mode.rawValue
            sectors.addItem(i)
        }
        menu.addItem(submenu("Sector Division", sectors))

        // Peers
        menu.addItem(.separator())
        menu.addItem(header("Nearby Devices"))
        let peers = services.radar.peers
        if peers.isEmpty {
            menu.addItem(header("   None found — open AirCompass on your iPhone/iPad"))
        }
        for peer in peers {
            let position = peer.hasPosition
                ? "\(Int(peer.smoothedAzimuthDegrees.rounded()) % 360)° · sector \(peer.assignedSector) · \(peer.positionSource.rawValue)"
                : "no position yet"
            let i = NSMenuItem(title: "\(peer.name) — \(position)", action: nil, keyEquivalent: "")
            i.image = NSImage(systemSymbolName: peer.deviceKind.symbolName, accessibilityDescription: nil)
            i.indentationLevel = 1
            menu.addItem(i)
        }
        menu.addItem(item("Seed Simulated Peers (iPhone + iPad)", #selector(toggleSimulated), state: services.radar.hasSimulatedPeers))
        menu.addItem(item("Simulate Orbiting Movement", #selector(toggleOrbit), state: services.radar.isOrbiting))

        // Acoustic
        menu.addItem(.separator())
        menu.addItem(header("Sound Positioning (experimental)"))
        menu.addItem(item("Chirp So Devices Can Locate Themselves", #selector(toggleEmit), state: settings.acousticEmit))
        menu.addItem(item("Chirp Now", #selector(chirpNow)))
        if let last = services.lastChirp {
            let ago = Int(Date().timeIntervalSince(last).rounded())
            menu.addItem(header("   Last chirp \(ago)s ago · \(services.chirpCount) total"))
        } else {
            menu.addItem(header("   No chirps yet — set a device to Sound (auto)"))
        }
        menu.addItem(item("Let Other Macs Locate This Mac", #selector(toggleListen), state: settings.acousticListen))
        let sides = NSMenu()
        for side in AcousticHemisphere.allCases {
            let i = item(side.title, #selector(selectHemisphere(_:)), state: settings.hemisphere == side)
            i.representedObject = side.rawValue
            sides.addItem(i)
        }
        menu.addItem(submenu("This Mac Sits…", sides))

        // Input
        menu.addItem(.separator())
        let inputs = NSMenu()
        for mode in AppSettings.InputMode.allCases {
            let i = item(mode.title, #selector(selectInputMode(_:)), state: settings.inputMode == mode)
            i.representedObject = mode.rawValue
            i.isEnabled = mode != .trackpad || MultitouchGestureSource.isAvailable
            inputs.addItem(i)
        }
        menu.addItem(submenu("Gesture Input", inputs))
        menu.addItem(item("Fallback to Native AirDrop Sheet…", #selector(airDropSelection)))

        menu.addItem(.separator())
        menu.addItem(item("Grant Accessibility Access…", #selector(requestAccessibility)))
        menu.addItem(item("Grant Finder Automation Access…", #selector(requestAutomation)))
        if let error = services.network.lastError {
            menu.addItem(header("Network: \(error)"))
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit AirCompass", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func item(_ title: String, _ action: Selector, state: Bool = false) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.state = state ? .on : .off
        return i
    }

    private func header(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = menu
        return i
    }

    // MARK: - Actions

    @objc private func openGlassLab() {
        coordinator.openGlassLab()
    }

    @objc private func togglePreview() {
        coordinator.previewMode.toggle()
    }

    @objc private func selectTrackingMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = TrackingMode(rawValue: raw) else { return }
        settings.trackingMode = mode
        coordinator.trackingModeChanged()
    }

    @objc private func selectUniformStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = NonDirectionalStyle(rawValue: raw) else { return }
        coordinator.select(style: .uniform(style))
    }

    @objc private func selectSpatialStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = SpatialCompassStyle(rawValue: raw) else { return }
        coordinator.select(style: .spatial(style))
    }

    @objc private func selectSectorMode(_ sender: NSMenuItem) {
        guard let mode = SectorMode(rawValue: sender.tag) else { return }
        settings.sectorMode = mode
        coordinator.sectorMode = mode
    }

    @objc private func toggleSimulated() {
        if services.radar.hasSimulatedPeers {
            services.radar.removeSimulatedPeers()
        } else {
            services.radar.seedSimulatedPeers()
        }
        coordinator.peersChanged()
    }

    @objc private func toggleOrbit() {
        if services.radar.isOrbiting {
            services.radar.stopOrbiting()
        } else {
            services.radar.startOrbiting()
            startOrbitRefresh()
        }
    }

    /// Simulated peers move continuously; push their positions into the HUD.
    private func startOrbitRefresh() {
        Task { [weak self] in
            while let self, self.services.radar.isOrbiting {
                self.coordinator.peersChanged()
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    @objc private func toggleEmit() {
        settings.acousticEmit.toggle()
    }

    @objc private func chirpNow() {
        services.probeIfNeeded(force: true)
    }

    @objc private func toggleListen() {
        services.setAcousticListen(!settings.acousticListen)
    }

    @objc private func selectHemisphere(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let side = AcousticHemisphere(rawValue: raw) else { return }
        services.setHemisphere(side)
    }

    @objc private func selectInputMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = AppSettings.InputMode(rawValue: raw) else { return }
        activateInputMode(mode)
    }

    @objc private func airDropSelection() {
        let urls = finder.currentSelectionIgnoringContext()
        guard !urls.isEmpty else {
            statusText = "Select files in Finder first"
            return
        }
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            statusText = "AirDrop is unavailable"
            return
        }
        NSApp.activate()
        service.perform(withItems: urls)
    }

    @objc private func requestAccessibility() {
        FinderSelectionExtractor.checkAccessibilityTrust(prompt: true)
    }

    @objc private func requestAutomation() {
        finder.warmUp()
        if case let .failed(errors) = finder.currentSelection(), errors[.appleEvents] == .automationNotPermitted,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}
