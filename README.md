# AirCompass

**AirDrop by pointing.** Select files in Finder, drag three fingers on the trackpad toward a person's device, and lift to send. No right-click, no Share menu, no hunting for a name in a list.

<p align="center">
  <img src="docs/media/hero-anchored.jpg" alt="AirCompass HUD opened over the desktop, next to the selected files, in optical liquid glass" width="900">
</p>

A liquid-glass compass opens right next to the files you selected. Nearby iPhones, iPads and Macs sit around it. The one you drag toward swells like an icon in the Dock, and lifting your fingers sends the files.

## The idea, in 90 seconds

<p align="center">
  <a href="docs/media/airdrop-compass-demo.mp4">
    <img src="docs/media/video-poster.jpg" alt="Watch the AirDrop Compass concept video" width="820">
  </a>
  <br>
  <sub>▶ <a href="docs/media/airdrop-compass-demo.mp4">Watch the concept video</a> (1:37, with voiceover): the five-step AirDrop of today, the setup, the three-finger compass, the receiving side, and live position tracking.</sub>
</p>

| AirDrop today | AirCompass |
|---|---|
| 1. Select files | 1. Select files |
| 2. Right-click | 2. Three-finger drag toward a device |
| 3. Share › | 3. Lift |
| 4. AirDrop | |
| 5. Find the person in a list | |

## Two ways to see the room

AirCompass has two families of HUD and switches between them automatically.

### Mode A: Non-directional

Used when devices have no known position (no companion app, or you'd rather save battery). Devices are spaced **evenly**, with no compass ticks, cardinal letters or degrees, so the HUD never implies a direction it doesn't know.

| A1 · Orbital Glass Halo | A2 · Dynamic Island Capsule | A3 · Notch Fan |
|:---:|:---:|:---:|
| <img src="docs/media/system-A1.jpg" width="270"> | <img src="docs/media/system-A2.jpg" width="270"> | <img src="docs/media/system-A3.jpg" width="270"> |
| Devices evenly around a ring; a frosted tether stretches from the files toward your drag. | Devices in a pill under the notch; the target drips out of it as a liquid droplet. | A 180° fan hanging from the top of the screen; a soft spotlight sweeps across it. |

### Mode B: Spatial compass

Used when the **iPhone/iPad companion** reports where each device actually is. Devices sit at their real bearing around you, snapped into 4, 6 or 8 sectors, each with a `092° · E` badge.

| B1 · Liquid Glass Compass | B2 · Chrono Sector Wheel | B3 · Sonar Horizon Radar |
|:---:|:---:|:---:|
| <img src="docs/media/system-B1.jpg" width="270"> | <img src="docs/media/system-B2.jpg" width="270"> | <img src="docs/media/system-B3.jpg" width="270"> |
| A molten glass bridge stretches from the files and snaps into the target. | Chronograph bezel; the pointed-at sector lights up and a hand locks on. | Distance rings (0.5 m / 1.5 m / 3 m+); a spotlight cone and sonar ripples. |

All six share the same gesture maths: the macOS Dock's cosine magnification curve, a haptic tick when the target changes, and another when you pull far enough to send.

## Liquid glass, three ways

Pick the glass in **menu bar › Glass Appearance**, or live from the preview's switcher pill.

- **Clear / Frosted:** Apple's own Liquid Glass (`glassEffect`, macOS 26). Orbs, the file core and droplets melt into each other with `GlassEffectContainer`.
- **Optical:** real refraction. The desktop behind the HUD is bent through every glass shape by a Metal shader: a squircle bezel, Snell's law through the glass thickness, a dome bulge, magnification, chromatic aberration and a Fresnel rim light. The optics are a port of [Caustic](https://github.com/Oxkai/liquid-glass) (MIT) by Ajay Odedra.

| Optical · A1 | Optical · A2 | Optical · B1 |
|:---:|:---:|:---:|
| <img src="docs/media/optical-A1.jpg" width="270"> | <img src="docs/media/optical-A2.jpg" width="270"> | <img src="docs/media/optical-B1.jpg" width="270"> |

<details>
<summary>All six styles in optical glass</summary>

| A3 | B2 | B3 |
|:---:|:---:|:---:|
| <img src="docs/media/optical-A3.jpg" width="270"> | <img src="docs/media/optical-B2.jpg" width="270"> | <img src="docs/media/optical-B3.jpg" width="270"> |

</details>

### Glass Lab

Every lens control from Caustic, live on the HUD: **Bevel, Dome, Cap band, Thickness, Strength, Magnify, Aberration, Light angle, Rim, Backlight, Frost**, plus a **Background** meter that fades in a smoky backing for legibility over busy wallpapers. Presets: Clear, Frosted, Dark tint, Bubble.

<p align="center">
  <img src="docs/media/glass-lab.jpg" alt="Glass Lab window with refraction controls under the optical HUD" width="900">
</p>

## Opens where your files are

When a gesture starts, AirCompass reads where the selected items sit on screen (Finder windows or the Desktop) and centers the glass on them, so the file orb lands right on top of your files. If it can't tell (no Accessibility permission, or the selection is scrolled away), it opens at the pointer. The menu bar preview stays top-center under the notch.

## How positioning works

A Mac has no sensor that can tell where another device is, so each device reports its own bearing relative to the Mac through the companion app:

- **Sound (auto, experimental):** every 4 s the Mac plays a near-ultrasonic chirp from its left speaker, then its right. The listening device times the gap to tell left from right (about ±15–20°). Two speakers can't tell front from back, so you pick which side of the screen the device is on. Needs the Mac's volume up and microphone access on the device.
- **Manual:** drag the device's node around the ring in the companion app.
- **Motion:** gyroscope rotation after calibration. This senses turning, not moving across the room.

Positions pass through a circular EMA (α = 0.28), so crossing North never swings through South. Devices sharing a sector fan out ±14° so each stays selectable. In **Auto** tracking mode the spatial compass is shown only when every nearby device has a real position; otherwise you get the even layout.

## Build, test, install

Requires macOS 14+ (Liquid Glass needs macOS 26), Xcode with Swift 6, and a trackpad.

```sh
Scripts/test.sh           # unit tests
Scripts/bundle.sh         # build/AirCompass.app, signed with your Apple Development identity
open build/AirCompass.app
Scripts/install-ios.sh    # build, sign, install and launch the companion on your iPhone/iPad
```

`install-ios.sh` takes device UDIDs from `DEVICES="…"` or from a git-ignored `Scripts/devices.local` (one per line; `xcrun devicectl list devices` lists them).

**Free Apple account:** the companion's provisioning profile expires after 7 days; rerun `Scripts/install-ios.sh`. On first install, trust the certificate on each device: Settings › General › VPN & Device Management.

### Permissions

| Permission | Why |
|---|---|
| **Automation › Finder** | Asks Finder which files are selected. The main way the selection is read. |
| **Accessibility** | Finds where the selected items are on screen, so the HUD opens next to them. Also a fallback way to read the selection, and needed for the ⌃⌥ pointer-fallback gesture. |
| **Screen Recording** | Only for **Optical** glass: it bends a live picture of the area under the HUD. Captured only while the HUD is visible, kept in GPU memory, never saved. Apple glass doesn't need it. |
| **Local Network** | Finding and talking to nearby devices (Bonjour + AWDL). |
| **Microphone** | Companion: hearing the Mac's chirps for sound positioning. Mac: only with **Let Other Macs Locate This Mac** on. |

Both Mac permissions can be opened from the menu bar (**Grant Accessibility Access…**, **Grant Finder Automation Access…**).

## Menu bar

- **Preview Compass HUD:** shows the HUD with an A1…B3 switcher pill and the glass controls, so you can compare styles live.
- **Tracking Mode:** Auto · Always Non-Directional · Always Spatial.
- **Mode A Style / Mode B Style:** pick the look for each family (persisted).
- **Glass Appearance:** Background meter, Clear / Frosted / Optical, and **Open Glass Lab…**
- **Sector Division:** 4, 6 or 8 sectors.
- **Seed Simulated Peers / Simulate Orbiting Movement:** try everything without a second device.

## Project layout

| Part | Where |
|---|---|
| Trackpad hook, gesture state machine | `Sources/AirCompassCore/Gesture/` (macOS) |
| Finder selection and its on-screen frame (AppleEvents + Accessibility) | `Sources/AirCompassCore/Finder/` (macOS) |
| Sector math, circular EMA, Dock magnification, HUD layouts | `Sources/AirCompassCore/Geometry/` |
| Wire protocol (framed JSON + binary chunks) | `Sources/AirCompassCore/Protocol/` |
| Bonjour + AWDL peer networking | `Sources/AirCompassCore/Network/` |
| File transfer (64 KB chunks, SHA-256 verified) | `Sources/AirCompassCore/Transfer/` |
| Radar engine, simulated peers | `Sources/AirCompassCore/Spatial/` |
| Ultrasonic stereo-chirp direction finding | `Sources/AirCompassCore/Acoustic/` |
| Mac menu-bar app, HUD panel and the six styles | `Sources/AirCompass/HUD/` |
| Optical glass: backdrop capture, Metal lens shader | `Sources/AirCompass/HUD/Optics/` |
| iPhone/iPad companion | `AirCompassCompanion/` (Xcode project, links the package) |

Design notes: [SPEC.md](SPEC.md) and [STEP4_TO_7.md](STEP4_TO_7.md).

<details>
<summary>Regenerating the screenshots</summary>

The app has a developer snapshot mode that shows the real HUD panel and prints each style's screen rectangle for `screencapture`:

```sh
AIRCOMPASS_SNAPSHOT_LIVE=1 build/AirCompass.app/Contents/MacOS/AirCompass |
  while read code x y w h; do screencapture -x -R$x,$y,$w,$h "$code.png"; done
```

Options: `AIRCOMPASS_SNAPSHOT_GLASS=0.3,optical` (background, `frosted`, `optical`), `AIRCOMPASS_SNAPSHOT_STYLES=A1,B1`, `AIRCOMPASS_SNAPSHOT_SWITCHER=0`, `AIRCOMPASS_SNAPSHOT_LAB=1`, `AIRCOMPASS_SNAPSHOT_ANCHOR=x,y`, `AIRCOMPASS_SNAPSHOT_BACKDROP=<image>` (a full-screen picture behind the HUD, used here with a still from the desktop's Aerial wallpaper).

</details>

## Notes

- Set Mission Control / app switching to **four** fingers (System Settings › Trackpad › More Gestures). AirCompass only observes touches and can't block system gestures.
- Peer links use plain TCP over Wi-Fi/AWDL without TLS. Fine on a home network; not hardened for hostile ones.
- Received files land in `~/Downloads` on the Mac and in Files › On My iPhone/iPad › AirCompass on iOS.
- Optical glass captures and redraws at 60 fps while the HUD is on screen, so it costs more battery than Apple's glass.

## License

[MIT](LICENSE). The optical glass shader is adapted from [Caustic](https://github.com/Oxkai/liquid-glass), also MIT.
