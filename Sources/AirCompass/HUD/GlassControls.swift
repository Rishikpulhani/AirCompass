import AirCompassCore
import AppKit
import SwiftUI

/// Compact glass controls: the Background meter and Clear / Frosted / Optical.
/// Shown in the preview switcher and the menu bar; changes apply live.
struct GlassControls: View {
    var appearance: GlassAppearance
    var onChange: (GlassAppearance) -> Void
    var onOpenLab: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            MeterRow(title: "Background", value: appearance.background, range: 0...1, format: { "\(Int(($0 * 100).rounded()))%" }) {
                var next = appearance
                next.background = $0
                onChange(next)
            }
            HStack(spacing: 10) {
                Text("Glass")
                    .foregroundStyle(.secondary)
                    .frame(width: MeterRow.labelWidth, alignment: .leading)
                GlassKindPicker(appearance: appearance, onChange: onChange)
                Spacer(minLength: 0)
                if let onOpenLab {
                    Button("Lab…", action: onOpenLab)
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(CompassPalette.accent)
                }
            }
            if appearance.isOptical, !BackdropCapture.hasPermission {
                ScreenRecordingNotice()
            }
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
    }
}

/// Label · meter · value, like Caustic's control panel.
struct MeterRow: View {
    static let labelWidth: CGFloat = 74
    var title: String
    var value: Double
    var range: ClosedRange<Double>
    var format: (Double) -> String
    var width: CGFloat = 128
    var onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .leading)
            MeterSlider(value: (value - range.lowerBound) / (range.upperBound - range.lowerBound), width: width) {
                onChange(range.lowerBound + $0 * (range.upperBound - range.lowerBound))
            }
            Text(format(value))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .frame(width: 42, alignment: .trailing)
        }
    }
}

/// Rounded track filled up to the value, with a white knob — click or drag
/// anywhere on it. `value` is 0…1.
struct MeterSlider: View {
    var value: Double
    var width: CGFloat = 128
    var onChange: (Double) -> Void

    private let knob: CGFloat = 16
    static let fill = LinearGradient(colors: [CompassPalette.accent, Color(red: 0.47, green: 0.45, blue: 0.95)],
                                     startPoint: .leading, endPoint: .trailing)

    var body: some View {
        GeometryReader { geo in
            let travel = max(geo.size.width - knob, 1)
            let x = travel * CGFloat(min(max(value, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.14)).frame(height: 5)
                Capsule().fill(Self.fill).frame(width: x + knob / 2, height: 5)
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.28), radius: 3, y: 1.5)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                onChange(Double(min(max((drag.location.x - knob / 2) / travel, 0), 1)))
            })
        }
        .frame(width: width, height: knob + 4)
    }
}

/// Clear / Frosted (Apple glass) / Optical (refraction) chips.
private struct GlassKindPicker: View {
    var appearance: GlassAppearance
    var onChange: (GlassAppearance) -> Void

    var body: some View {
        HStack(spacing: 2) {
            chip("Clear", selected: !appearance.isOptical && !appearance.frosted) { set(.system, frosted: false) }
            chip("Frosted", selected: !appearance.isOptical && appearance.frosted) { set(.system, frosted: true) }
            chip("Optical", selected: appearance.isOptical) { set(.optical, frosted: appearance.frosted) }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
    }

    private func set(_ engine: GlassEngine, frosted: Bool) {
        var next = appearance
        next.engine = engine
        next.frosted = frosted
        if engine == .optical, !BackdropCapture.hasPermission { BackdropCapture.requestPermission() }
        onChange(next)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background {
                    if selected { Capsule().fill(MeterSlider.fill) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Optical glass bends a live picture of the screen under the HUD, which
/// macOS only allows with Screen Recording.
private struct ScreenRecordingNotice: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "record.circle")
                .foregroundStyle(.orange)
            Text("Optical glass needs Screen Recording")
                .foregroundStyle(.secondary)
            Button("Grant…") {
                if !BackdropCapture.requestPermission() {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(CompassPalette.accent)
        }
        .font(.system(size: 10, weight: .medium, design: .rounded))
    }
}

/// Menu-bar version: keeps its own copy so dragging stays smooth while the
/// menu is open, and reports every change.
struct GlassControlsMenuView: View {
    @State var appearance: GlassAppearance
    var onChange: (GlassAppearance) -> Void
    var onOpenLab: () -> Void

    var body: some View {
        GlassControls(appearance: appearance, onChange: { next in
            appearance = next
            onChange(next)
        }, onOpenLab: onOpenLab)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: 330, alignment: .leading)
    }
}

// MARK: - Glass Lab

/// Every Caustic lens control, laid out like its demo panel. Edits the live
/// HUD (the preview opens alongside).
struct GlassLabView: View {
    let model: CompassHUDModel

    var body: some View {
        let g = model.glass
        let o = g.optics
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                GlassControls(appearance: g, onChange: apply)
                Spacer()
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                GridRow {
                    meter("Bevel", o.bevel, 0...80, "%.1f") { $0.bevel = $1 }
                    meter("Dome", o.dome, 0...1, "%.2f") { $0.dome = $1 }
                }
                GridRow {
                    meter("Cap band", o.capBand, 1...3, "%.2f") { $0.capBand = $1 }
                    meter("Thickness", o.thickness, 0...400, "%.0f") { $0.thickness = $1 }
                }
                GridRow {
                    meter("Strength", o.strength, 0...2, "%.2f") { $0.strength = $1 }
                    meter("Magnify", o.magnify, 0.8...1.6, "%.2f") { $0.magnify = $1 }
                }
                GridRow {
                    meter("Aberration", o.aberration, 0...0.3, "%.3f") { $0.aberration = $1 }
                    meter("Light angle", o.lightAngle, 0...360, "%.0f") { $0.lightAngle = $1 }
                }
                GridRow {
                    meter("Rim", o.rim, 0...1, "%.2f") { $0.rim = $1 }
                    meter("Backlight", o.backlight, 0...1, "%.2f") { $0.backlight = $1 }
                }
                GridRow {
                    meter("Frost", o.frost, 0...20, "%.1f") { $0.frost = $1 }
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                }
            }
            .disabled(!g.isOptical)
            .opacity(g.isOptical ? 1 : 0.4)

            HStack(spacing: 8) {
                Text("Presets").foregroundStyle(.secondary)
                preset("Clear") { $0 = GlassAppearance(engine: .optical) }
                preset("Frosted") { $0.engine = .optical; $0.optics.frost = 6; $0.background = 0.08 }
                preset("Dark tint") { $0.engine = .optical; $0.optics.frost = 0; $0.background = 0.45 }
                preset("Bubble") { $0.engine = .optical; $0.optics.dome = 0.85; $0.optics.magnify = 1.35; $0.optics.aberration = 0.12 }
                Spacer()
                if !g.isOptical {
                    Text("Lens controls apply to Optical glass")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
        }
        .padding(22)
        .frame(width: 600)
    }

    private func apply(_ next: GlassAppearance) { model.onSetGlass?(next) }

    private func meter(_ title: String, _ value: Double, _ range: ClosedRange<Double>, _ format: String,
                       _ write: @escaping (inout OpticsParams, Double) -> Void) -> some View {
        MeterRow(title: title, value: value, range: range, format: { String(format: format, $0) }, width: 120) { v in
            var next = model.glass
            write(&next.optics, v)
            apply(next)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
    }

    private func preset(_ title: String, _ change: @escaping (inout GlassAppearance) -> Void) -> some View {
        Button {
            var next = model.glass
            change(&next)
            if !BackdropCapture.hasPermission { BackdropCapture.requestPermission() }
            apply(next)
        } label: {
            Text(title)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

/// Floating window hosting the Glass Lab.
@MainActor
final class GlassLabWindow {
    private var window: NSWindow?

    func show(model: CompassHUDModel) {
        if window == nil {
            let host = NSHostingController(rootView: GlassLabView(model: model))
            let w = NSWindow(contentViewController: host)
            w.title = "Glass Lab"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.level = .floating
            w.isReleasedWhenClosed = false
            // Lower middle of the screen, clear of the top-center HUD.
            if let screen = NSScreen.main {
                let size = w.frame.size
                w.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 60))
            }
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
