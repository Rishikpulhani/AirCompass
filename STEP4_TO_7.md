I have installed full Xcode (`/Applications/Xcode.app`), enabled Developer Mode on both my iPhone and iPad, and verified that my `Apple Development` signing identity is valid in Keychain (`security find-identity -v -p codesigning`).

Here are my exact physical target devices from `xcrun xctrace list devices`:
- **MacBook Air**: `rishik’s MacBook Air` (UDID: `<mac-udid>`)
- **iPad Pro M2**: `Rishik’s iPad` (iPadOS 26.6.2, UDID: `<ipad-udid>`)
- **iPhone 14 Plus**: `Rishik’s iPhone` (iOS 26.6.1, UDID: `<iphone-udid>`)

Now proceed with **Steps 4, 5, 6, and 7**, upgrading the architecture to build both the macOS app (`build/AirCompass.app`) and the native iOS/iPadOS companion app (`AirCompassCompanion.app`) for my iPhone and iPad while keeping all Steps 1–3 tests passing under Swift 6 strict concurrency.

---

### 1. Project & Build Architecture (`AirCompassCore` + macOS App + iOS/iPadOS App)
1. **Shared Cross-Platform Library (`AirCompassCore`)**:
   - Refactor shared models, math, and networking protocol types into an `AirCompassCore` target in `Package.swift` supporting both macOS and iOS:
     - `PeerDevice: Identifiable, Sendable, Equatable, Codable` (`id`, `name`, `deviceKind: .mac | .iPhone | .iPad`, `rawAzimuthDegrees`, `smoothedAzimuthDegrees`, `assignedSector`, `displayAzimuthDegrees`, `distanceMeters`, `isSimulated`).
     - `SectorMode: Int, CaseIterable, Sendable, Codable` (`.four = 4`, `.six = 6`, `.eight = 8`).
     - Circular unit-vector EMA filter ($\overline{\sin \beta}, \overline{\cos \beta}$ with $\alpha = 0.28$), sector quantization math, and multi-device sub-clustering.
     - Cosine Dock magnification curve math ($S_i(\theta, r)$).
     - AWDL wire protocol frames (`PeerHelloFrame`, `PositionUpdateFrame`, `GestureMirrorFrame`, `TransferHeaderFrame`, `TransferAckFrame`).
2. **Persistent Code Signing in `Scripts/bundle.sh`**:
   - Automatically detect the first valid `"Apple Development"` identity from `security find-identity -v -p codesigning` (falling back to `-` only if none is found) so macOS Accessibility and Finder Automation TCC permissions persist across rebuilds.
   - Update `Scripts/test.sh` to use Xcode's toolchain cleanly and verify all unit tests pass.
3. **Native iOS/iPadOS Companion App & `Scripts/install-ios.sh`**:
   - Create the native SwiftUI iOS/iPadOS target/project (`AirCompassCompanion`) that links `AirCompassCore`.
   - Extract the 10-character Apple Developer Team ID (`OU=...`) automatically from the Keychain certificate via:
     `security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject`
   - Create `Scripts/install-ios.sh` that:
     1. Builds `AirCompassCompanion` for generic iOS device using `xcodebuild -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM_ID"`.
     2. Installs the built `.app` onto **Rishik’s iPhone** (`<iphone-udid>`) and **Rishik’s iPad** (`<ipad-udid>`) using `xcrun devicectl device install app --device <UDID> <path-to-app>`.
     3. Launches the app on both devices using `xcrun devicectl device process launch --terminate-existing --device <UDID> <bundle-id>`.

---

### 2. Step 4: `SpatialRadarEngine.swift` (True AWDL Discovery + Live Spatial Tracking)
1. **True Peer-to-Peer AWDL Discovery (`Network.framework`)**:
   - Use `NWListener` and `NWBrowser` advertising/browsing `_aircompass._tcp` with `parameters.includePeerToPeer = true` on both macOS and iOS/iPadOS.
   - Include `Info.plist` entries for `NSLocalNetworkUsageDescription` and `NSBonjourServices` (`_aircompass._tcp`) on both macOS and iOS targets so peer-to-peer discovery works without silent policy drops.
2. **Sector Quantization & Sub-Clustering Math**:
   - Given $N \in \{4, 6, 8\}$ sectors, each sector spans $\Delta \phi = \frac{360^\circ}{N}$:
     $$k = \left\lfloor \frac{(\beta + \Delta \phi / 2) \pmod{360^\circ}}{\Delta \phi} \right\rfloor$$
   - Smooth incoming azimuth angles $\beta \in [0^\circ, 360^\circ)$ using unit-vector EMA so crossing $359^\circ \leftrightarrow 1^\circ$ North never interpolates backwards through $180^\circ$.
   - If both the iPhone and iPad sit in the same sector $k$, offset their `displayAzimuthDegrees` symmetrically ($\pm 14^\circ$) so each device remains individually selectable via Dock magnification.
3. **Real-Time Spatial Stream + Built-in Demo Mode**:
   - Listen for live `PositionUpdateFrame` packets over AWDL whenever the connected iPhone or iPad changes its relative angle around the MacBook.
   - Provide a menu bar toggle **"Seed Simulated Peers (iPhone + iPad)"** and **"Simulate Orbiting Movement"** so the full radar and sector handoffs can also be tested solo.

---

### 3. Step 5: `CompassHUDPanel.swift` & `CompassHUDView.swift` (Sleek Mac HUD + Dock Magnification)
1. **Non-Activating Floating HUD (`CompassHUDPanel: NSPanel`)**:
   - Style mask: `[.borderless, .nonActivatingPanel]`, `level = .statusBar`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`, `isOpaque = false`, `backgroundColor = .clear`.
   - Positioned top-center on the active screen (`12pt` below `screen.visibleFrame.maxY`, clearing the MacBook notch) without stealing focus from Finder.
2. **Sleek Compass UI & Cosine Dock Magnification (`CompassHUDView.swift`)**:
   - Dark glassmorphic radial radar (`360x360pt` with generous outer padding so magnified device nodes at $1.85\times$ never clip).
   - Render degree ticks every $15^\circ$, cardinal labels (`N`, `E`, `S`, `W`), glowing sector boundary lines for 4, 6, or 8 sectors, and an illuminated radial wedge for the active sector.
   - Center core showing the selected Finder file icon + file count badge, with an elastic glowing vector tether tracking $(r, \theta)$ and turning electric cyan/green when $r \ge r_{\text{commit}}$.
   - **macOS Dock-Style Cosine Magnification**:
     - For each device $i$ at display angle $\phi_i$, compute shortest angular distance $\delta_i = \vert{}\operatorname{atan2}(\sin(\theta - \phi_i), \cos(\theta - \phi_i))\vert{}$.
     - Compute continuous scale factor:
       $$S_i(\theta, r) = 1.0 + \operatorname{clamp}(r / r_{\text{active}}, 0, 1) \cdot (1.85 - 1.0) \cdot \max\left(0, \cos\left(\frac{\pi}{2} \cdot \min\left(1, \frac{\delta_i}{\delta_{\text{spread}}}\right)\right)^2\right)$$
     - Render each peer with its matching SF Symbol (`iphone`, `ipad.landscape`, `laptopcomputer`), glowing glass orb, device name pill, and live degree badge.
     - Trigger `NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)` when the magnified target device changes, and `.levelChange` when crossing $r_{\text{commit}}$.
   - Also support a **Receiver HUD state** on the Mac when receiving incoming files.

---

### 4. Step 6: Native iOS/iPadOS Companion App (`AirCompassCompanion`) & High-Speed Transfer
Build the native SwiftUI iOS/iPadOS app for **Rishik’s iPhone** and **Rishik’s iPad**:
1. **Sleek Receiver Compass HUD on iPhone & iPad**:
   - Matching dark glassmorphic 360° radial compass showing `rishik’s MacBook Air` at the center and the iPhone/iPad's current relative sector.
   - **60 Hz Live Gesture Mirroring**: While I drag 3 fingers on the MacBook trackpad, the Mac broadcasts `GestureMirrorFrame(r, theta, targetPeerID, fileNames, isCommitted)` over AWDL. When I drag toward `Rishik’s iPhone` or `Rishik’s iPad`, that device's screen dynamically magnifies its incoming compass node in real time and plays crisp haptics (`UIImpactFeedbackGenerator`) as the drag approaches the commit threshold.
2. **Spatial Position Calibration + Live Hardware Sensors on iOS/iPadOS**:
   - **Interactive 360° Orbit Dial**: Allow dragging the iPhone/iPad node directly around the compass ring on the touchscreen ($0^\circ \dots 360^\circ$) to set or move its relative position around the MacBook, streaming `PositionUpdateFrame` live at 60 Hz so the MacBook HUD animates the device across sectors immediately.
   - **Live Sensor Mode (`CMMotionManager` device motion yaw / `CLLocationManager` heading)**: Include a one-tap `"Calibrate North = Toward Mac"` button that uses live gyroscope/magnetometer updates to shift the relative angle automatically as the device moves.
3. **High-Speed AWDL File Transfer & QuickLook Preview**:
   - When the 3-finger gesture commits on the MacBook, stream the selected Finder files over the AWDL connection (`TransferHeaderFrame` + 64 KB binary chunks) with a synchronized glowing progress ring on both the MacBook HUD and the receiving iPhone/iPad HUD.
   - Save received files on the iPhone/iPad and immediately present a native QuickLook preview (`QLPreviewController` / `ShareLink`) with a completion haptic.
   - Also allow sending a test file or photo *from* the iPhone/iPad back to the MacBook to test the Mac's Receiver Compass HUD.
4. **Native macOS AirDrop Fallback**:
   - Include a menu bar toggle on the Mac (`"Trigger Native macOS AirDrop Sheet"`) using `NSSharingService(named: .sendViaAirDrop)`.

---

### 5. Step 7: End-to-End Coordinator, Menu Bar Controls & Verification
1. Wire the full pipeline in the Mac app coordinator:
   - 3-finger drag (or `⌃⌥` pointer fallback) -> query `FinderSelectionExtractor` -> show `CompassHUDPanel` -> stream 60 Hz `GestureMirrorFrame` to connected peers -> on release at $r \ge r_{\text{commit}}$, send selected Finder files to the highest-magnification target device in the committed sector.
   - Add Menu Bar items for:
     - **Preview Compass HUD** (allows testing the HUD and 3-finger drag even without an active Finder selection)
     - **Sector Division**: `4 Sectors (90°)` / `6 Sectors (60°)` / `8 Sectors (45°)`
     - **Seed Simulated Peers** & **Simulate Orbiting Movement**
     - **Connected Peers List** (live status of Rishik's iPhone & Rishik's iPad with their current azimuth and sector)
     - **Fallback to Native AirDrop Sheet**
2. Write comprehensive unit tests in `Tests/` for circular EMA wrap-around ($355^\circ \leftrightarrow 5^\circ$), 4/6/8 sector quantization, multi-device sub-clustering, cosine Dock magnification math, and AWDL frame serialization.
3. Run `Scripts/test.sh` and `Scripts/bundle.sh` to verify 100% test pass rate and a signed `build/AirCompass.app`.
