# Role & Objective
You are a Staff macOS Systems Engineer and Human Interface Designer. We are building **"AirCompass"** (codename), a native macOS utility written in Swift 6 (AppKit + SwiftUI + low-level C-bridging) that replaces the multi-step Finder -> Share -> AirDrop flow with an instantaneous, spatially-aware 3-finger trackpad gesture and a sleek radial compass HUD.

Build this application cleanly, modularly, and with production-grade macOS APIs. Do not stub out core logic with fake comments where real macOS framework calls can be written.

---

# Core User Flow & Product Requirements
1. **File Selection**: The user selects one or more files in macOS Finder.
2. **Gesture Trigger**: The user places and drags 3 fingers on the MacBook trackpad.
3. **Sleek Compass HUD (Sender)**: Immediately upon detecting a 3-finger drag while Finder has active file selections, a sleek, glassmorphic radial Compass HUD animates in at the top-center of the screen (below the notch/menu bar).
4. **Directional Sector Mapping**:
   - The 360° compass is relative to the user facing the MacBook screen (0° / North = straight ahead behind the display, 90° / East = right, 180° / South = toward the user, 270° / West = left).
   - Support configurable sector divisions: **4 sectors** (default, highest accuracy: 90° each), **6 sectors** (60° each), or **8 sectors** (45° each).
   - Nearby discoverable devices are mapped into their respective angular sectors based on their real-time relative azimuth to the user's MacBook.
5. **macOS Dock-Style Radial Magnification**:
   - As the user drags 3 fingers in a direction, calculate the drag vector $(r, \theta)$ from the initial 3-finger centroid.
   - Apply a continuous parabolic/Gaussian magnification curve (identical in feel to the macOS Dock) to the device icons around the compass ring based on angular proximity to $\theta$ and radial pull distance $r$.
   - Clearly highlight and scale up the target device that will receive the files if the gesture is released.
6. **Release to Send**: When the user reaches the radial threshold ($r \ge r_{\text{commit}}$) and lifts their 3 fingers, immediately transmit the selected Finder files to the magnified target device.
7. **Receiver HUD**: On the receiving Mac running the daemon, automatically trigger a matching incoming Compass HUD at the top of the screen indicating the sender's identity, incoming directional vector (flipped $180^\circ$ relative to receiver orientation), file preview, and transfer progress.
8. **Dynamic Spatial Tracking**: Continuously monitor relative device positions. If a peer device moves across room sectors, smoothly animate its node across the compass in real time.

---

# Technical Architecture & macOS Frameworks

## 1. Global 3-Finger Trackpad Hook (`MultitouchSupport.framework`)
Standard `NSEvent` gesture monitors do not expose raw 3-finger normalized trackpad coordinates globally without window focus.
- Create a C-bridging header / `@_silgen_name` wrapper for Apple's private `MultitouchSupport.framework` (`/System/Library/PrivateFrameworks/MultitouchSupport.framework`).
- Bind `MTDeviceCreateList()`, `MTRegisterContactFrameCallback()`, and `MTDeviceStart()`.
- Parse the `MTTouch` struct array on a high-priority background thread:
  - Detect when active touch count transitions to `3`.
  - Compute the initial 3-finger centroid $(x_0, y_0)$ in normalized trackpad coordinates $[0, 1] \times [0, 1]$.
  - On subsequent frames with 3 fingers, compute $\Delta x = x_t - x_0$ and $\Delta y = y_t - y_0$.
  - Convert to polar coordinates:
    $$r = \sqrt{\Delta x^2 + \Delta y^2}, \quad \theta = \operatorname{atan2}(\Delta x, \Delta y) \pmod{2\pi}$$
    *(where $\theta = 0$ is North / pushing fingers toward the top edge of the trackpad).*
- Provide a fallback toggle using a global `CGEventTap` (`NSEvent.addGlobalMonitorForEvents`) for testing on external mice/trackpads if `MultitouchSupport` is unavailable.

## 2. Finder Selection Bridge (`FinderBridge.swift`)
- When the 3-finger gesture begins, immediately query the active Finder selection.
- Primary method: Use `ScriptingBridge` or `NSAppleScript` / AppleEvents (`tell application "Finder" to get selection as alias list`) pre-compiled in memory for sub-15ms execution, converting aliases to `[URL]`.
- Secondary/Fallback method: Use the Accessibility API (`AXUIElementCopyAttributeValue` on the focused Finder window's `kAXSelectedChildrenAttribute`) to extract file URLs with zero AppleEvent overhead.
- If no files are selected in Finder (or Finder is not the active/recent context), ignore the 3-finger gesture so normal macOS Mission Control / App Expose gestures are unaffected.

## 3. Spatial Discovery & Relative Positioning Engine (`SpatialEngine.swift`)
Design a modular `SpatialPositionProvider` protocol with three concrete strategies so the app works across all hardware configurations:
1. **Ultra-Wideband / iPhone Anchor Bridge (`NearbyInteraction`)**:
   - Since MacBooks lack built-in UWB azimuth antennas, allow pairing an iPhone (or peer iOS device) via `MultipeerConnectivity` + `NearbyInteraction` (`NINearbyPeerConfiguration`) to stream real-time UWB `direction` vectors $(x, y, z)$ and `distance` to the Mac.
2. **Acoustic / BLE RSSI + Heading Triangulation (`Network.framework` + `CoreBluetooth`)**:
   - Discover peers over Apple Wireless Direct Link (AWDL) using `NWBrowser` (`parameters.includePeerToPeer = true`) and BLE advertisements containing each Mac's compass heading (`CoreLocation` / magnetometer or manual orientation calibration).
   - Apply an Exponential Moving Average (EMA) / 1D Kalman filter on azimuth angles $\theta_i(t)$ to prevent sector-boundary jitter.
3. **Interactive Spatial Calibration & Simulation Mode**:
   - Include a debug/calibration overlay where devices discovered via Bonjour can be dragged around a virtual room radar or auto-assigned angles to test 4-, 6-, and 8-sector transitions and live movement updates.

### Sector Quantization Math
Given $N \in \{4, 6, 8\}$ sectors:
- Each sector $k \in \{0, \dots, N-1\}$ spans an angular width of $\Delta \phi = \frac{360^\circ}{N}$, centered at $\phi_k = k \cdot \Delta \phi$.
- Map each discovered peer's relative bearing $\beta \in [0^\circ, 360^\circ)$ to sector:
  $$k = \left\lfloor \frac{(\beta + \Delta \phi / 2) \pmod{360^\circ}}{\Delta \phi} \right\rfloor$$
- If multiple devices fall into the same sector, sub-cluster them angularly within that sector's arc while maintaining individual Dock magnification targets.

## 4. Sleek Compass HUD & Dock Magnification UI (`CompassHUDWindow.swift` & `CompassView.swift`)
- **Window Configuration**: Subclass `NSPanel` with `.borderless`, `.nonActivatingPanel`, `level = .statusBar`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, `isOpaque = false`, and `backgroundColor = .clear`. Position it top-center just below the menu bar / MacBook notch.
- **Visual Design**:
  - Ultra-sleek dark glassmorphic aesthetic (`NSVisualEffectView` with `.hudWindow` / `.ultraThinMaterial`, subtle specular inner borders, and crisp SF Symbols).
  - Render a precision 360° radial compass with subtle sector dividers (4, 6, or 8 segments), a glowing central vector puck tracking the 3-finger drag $(r, \theta)$, and peripheral device nodes.
- **Dock-Style Parabolic Magnification Math**:
  - For each device $i$ at angle $\phi_i$, calculate the shortest angular distance to the user's current 3-finger drag angle $\theta$:
    $$\delta_i = \left\vert{} \operatorname{atan2}(\sin(\theta - \phi_i), \cos(\theta - \phi_i)) \right\vert{}$$
  - Gate the magnification intensity by how far the user has pulled their fingers radially: $\alpha(r) = \operatorname{clamp}(r / r_{\text{active}}, 0, 1)$.
  - Compute the scale factor $S_i$ using a smooth cosine bell curve (matching the macOS Dock algorithm):
    $$S_i(\theta, r) = 1.0 + \alpha(r) \cdot (S_{\max} - 1.0) \cdot \begin{cases} \cos^2\left(\frac{\pi}{2} \cdot \frac{\delta_i}{\delta_{\text{spread}}}\right) & \text{if } \delta_i < \delta_{\text{spread}} \\ 0 & \text{otherwise} \end{cases}$$
    where $S_{\max} = 1.85$ and $\delta_{\text{spread}} = \frac{\pi}{N}$.
  - Animate transitions with interactive spring physics (`response: 0.22, dampingFraction: 0.78`) and trigger subtle haptic feedback (`NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)`) whenever the locked target device changes or crosses the commit threshold.

## 5. Peer-to-Peer AWDL Transfer & Native AirDrop Bridge (`TransferService.swift`)
- **Primary Transport (Custom AWDL High-Speed Stream)**:
  - Use `Network.framework` (`NWListener` and `NWConnection`) with `NWParameters.tls` and `includePeerToPeer = true` (which leverages Apple Wireless Direct Link—the exact same high-speed peer-to-peer Wi-Fi interface used by AirDrop).
  - Frame protocol: Send a JSON metadata header (sender device name, sender relative angle, file names, sizes, SHA-256 hashes, thumbnail bytes) followed by chunked binary file streams.
  - On the **Receiving Mac**, receiving the header immediately summons the **Receiver Compass HUD**, displaying an incoming pulse animation from the sender's directional sector and saving files to `~/Downloads` (with an option for auto-accept from trusted peers).
- **Secondary Transport (Native AirDrop Fallback)**:
  - Also provide a direct bridge to `NSSharingService(named: .sendViaAirDrop)` for sending to non-daemon iOS/macOS devices when desired.

---

# Implementation Plan & Deliverables
Please implement this project step-by-step in complete, compilable Swift files:
1. **Project Structure & Entitlements**: `Package.swift` / Xcode setup, required entitlements (Disable App Sandbox for `MultitouchSupport` and Finder automation, `NSAppleEventsUsageDescription`, `NSLocalNetworkUsageDescription`, `NSBluetoothAlwaysUsageDescription`).
2. **`MultitouchBridge.swift`**: Full C-function dynamic bindings for `MultitouchSupport.framework` and the 3-finger gesture state machine (`idle -> tracking(r, theta) -> committed(sector) -> cancelled`).
3. **`FinderSelectionExtractor.swift`**: Fast Finder selected-files lookup via Accessibility API + AppleEvents fallback.
4. **`SpatialRadarEngine.swift`**: Sector math (4, 6, 8 modes), angular EMA smoothing filter, Bonjour/AWDL peer discovery, and dynamic position tracking.
5. **`CompassHUDPanel.swift` & `CompassHUDView.swift`**: The non-activating floating `NSPanel` and the SwiftUI Canvas/View implementing the sleek compass UI, radial vector tether, haptic feedback, and the cosine Dock magnification effect.
6. **`PeerTransferManager.swift`**: AWDL `NWListener`/`NWConnection` file transfer engine + Receiver HUD state controller.

Start by generating the complete project architecture and implementing **Steps 1, 2, and 3** in full detail, then proceed to **Steps 4, 5, and 6** without truncating any code.
