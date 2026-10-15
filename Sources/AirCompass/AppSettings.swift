import AirCompassCore
import Foundation

/// User preferences persisted in `UserDefaults`.
@MainActor
final class AppSettings {
    enum InputMode: String, CaseIterable {
        /// Raw trackpad via MultitouchSupport.framework.
        case trackpad
        /// ⌃⌥ + pointer movement, for external mice and testing.
        case pointerFallback

        var title: String {
            switch self {
            case .trackpad: "Trackpad (3-finger drag)"
            case .pointerFallback: "Pointer Fallback (hold ⌃⌥ + move)"
            }
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "acousticEmit": true,
            "acousticListen": false,
            "speakerSpacing": 0.27,
        ])
    }

    var sectorMode: SectorMode {
        get { SectorMode(rawValue: defaults.integer(forKey: "sectorMode")) ?? .four }
        set { defaults.set(newValue.rawValue, forKey: "sectorMode") }
    }

    var inputMode: InputMode {
        get { defaults.string(forKey: "inputMode").flatMap(InputMode.init(rawValue:)) ?? .trackpad }
        set { defaults.set(newValue.rawValue, forKey: "inputMode") }
    }

    /// Play chirp probes so listening peers can measure their direction.
    var acousticEmit: Bool {
        get { defaults.bool(forKey: "acousticEmit") }
        set { defaults.set(newValue, forKey: "acousticEmit") }
    }

    /// Answer other Macs' probes (uses the microphone).
    var acousticListen: Bool {
        get { defaults.bool(forKey: "acousticListen") }
        set { defaults.set(newValue, forKey: "acousticListen") }
    }

    var hemisphere: AcousticHemisphere {
        get { defaults.string(forKey: "hemisphere").flatMap(AcousticHemisphere.init(rawValue:)) ?? .userSide }
        set { defaults.set(newValue.rawValue, forKey: "hemisphere") }
    }

    /// Left-to-right speaker distance of this Mac (MacBook Air 13″ ≈ 0.27 m).
    var speakerSpacing: Double {
        get { defaults.double(forKey: "speakerSpacing") }
        set { defaults.set(newValue, forKey: "speakerSpacing") }
    }

    // MARK: HUD look

    var trackingMode: TrackingMode {
        get { defaults.string(forKey: "trackingMode").flatMap(TrackingMode.init(rawValue:)) ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: "trackingMode") }
    }

    var nonDirectionalStyle: NonDirectionalStyle {
        get { defaults.string(forKey: "nonDirectionalStyle").flatMap(NonDirectionalStyle.init(rawValue:)) ?? .orbitalHalo }
        set { defaults.set(newValue.rawValue, forKey: "nonDirectionalStyle") }
    }

    /// Glass Appearance meter: backing behind the glass (0…1) and clear vs. frosted.
    var glassAppearance: GlassAppearance {
        get {
            if let data = defaults.data(forKey: "glassAppearance"),
               let saved = try? JSONDecoder().decode(GlassAppearance.self, from: data) {
                return saved
            }
            // Before the Glass Lab, only these two were stored.
            return GlassAppearance(background: defaults.double(forKey: "glassBackground"),
                                   frosted: defaults.bool(forKey: "glassFrosted"))
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "glassAppearance") }
    }

    var spatialStyle: SpatialCompassStyle {
        get { defaults.string(forKey: "spatialStyle").flatMap(SpatialCompassStyle.init(rawValue:)) ?? .liquidGlassCompass }
        set { defaults.set(newValue.rawValue, forKey: "spatialStyle") }
    }
}
