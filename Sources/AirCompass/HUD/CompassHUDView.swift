import AirCompassCore
import SwiftUI

/// Root of the HUD. One glass plate morphs between the six styles' shapes
/// (circle, capsule, notch fan) while the style's contents cross-fade on top.
/// Below sit the status pill and, while previewing, the A1…B3 switcher.
struct CompassHUDView: View {
    let model: CompassHUDModel
    /// Glass shapes reported by the layout, for the optical renderer.
    @State private var glassShapes: [GlassShapeInfo] = []

    /// Panel y (from the top) of the glass center when anchored to a selection.
    static let anchorY: CGFloat = 186

    var body: some View {
        let layout = StageLayout(model.style)
        VStack(spacing: 12) {
            ZStack(alignment: .top) {
                // The capsule style draws its own plate (system or optical
                // glass) so its droplets can fuse with it.
                if !(model.style == .uniform(.dynamicIslandCapsule) && (SystemGlass.isAvailable || model.glass.isOptical)) {
                    LiquidGlass(shape: UnevenRoundedRectangle(cornerRadii: layout.radii, style: .continuous))
                        .frame(width: layout.plate.width, height: layout.plate.height)
                        .transition(.opacity)
                }

                content(stage: layout.stage)
                    .id(model.style)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top)),
                                            removal: .opacity))
            }
            .frame(width: layout.stage.width, height: layout.stage.height, alignment: .top)

            StatusPill(model: model)

            if model.showsStyleSwitcher {
                StyleSwitcher(current: model.style, glass: model.glass,
                              select: { model.onSelectStyle?($0) },
                              setGlass: { model.onSetGlass?($0) },
                              openLab: { model.onOpenLab?() })
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // Pinned: the glass hangs from the top edge. Anchored: the glass's
        // center stays on `anchorY`, so switching styles morphs in place
        // around the selection.
        .padding(.top, model.pinnedToTop ? CompassHUDPanel.topInset : Self.anchorY - layout.plate.height / 2)
        .frame(width: CompassHUDPanel.size.width, height: CompassHUDPanel.size.height, alignment: .top)
        .background {
            if model.glass.isOptical {
                OpticalGlassLayer(shapes: glassShapes, appearance: model.glass, active: model.mode != .hidden)
            }
        }
        .coordinateSpace(.named(HUDSpace.name))
        .onPreferenceChange(GlassShapesKey.self) { shapes in
            MainActor.assumeIsolated { glassShapes = shapes }
        }
        .animation(HUDPalette.morph, value: model.style)
        .animation(HUDPalette.morph, value: model.showsStyleSwitcher)
        .environment(\.glassAppearance, model.glass)
        .animation(.easeOut(duration: 0.12), value: model.glass)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func content(stage: CGSize) -> some View {
        switch model.style {
        case .uniform(.orbitalHalo): OrbitalHaloStyle(model: model, stage: stage)
        case .uniform(.dynamicIslandCapsule): IslandCapsuleStyle(model: model, stage: stage)
        case .uniform(.notchHalfArc): NotchFanStyle(model: model, stage: stage)
        case .spatial(.liquidGlassCompass): LiquidCompassStyle(model: model, stage: stage)
        case .spatial(.chronoSectorDial): ChronoDialStyle(model: model, stage: stage)
        case .spatial(.sonarHorizonRadar): SonarRadarStyle(model: model, stage: stage)
        }
    }
}

/// Glass plate shape and the area its contents may use (magnified orbs and
/// droplets overflow the plate).
@MainActor
struct StageLayout: Equatable {
    var plate: CGSize
    var radii: RectangleCornerRadii
    var stage: CGSize

    init(plate: CGSize, radii: RectangleCornerRadii, stageHeight: CGFloat) {
        self.plate = plate
        self.radii = radii
        stage = CGSize(width: CompassHUDPanel.size.width, height: stageHeight)
    }

    init(_ style: HUDStyle) {
        switch style {
        case .uniform(.orbitalHalo):
            self = .circle(OrbitalHaloStyle.plate, extra: 36)
        case .uniform(.dynamicIslandCapsule):
            let p = IslandCapsuleStyle.plate
            let r = p.height / 2
            self.init(plate: p, radii: RectangleCornerRadii(topLeading: r, bottomLeading: r, bottomTrailing: r, topTrailing: r),
                      stageHeight: p.height + 120)
        case .uniform(.notchHalfArc):
            let p = NotchFanStyle.plate
            let top = NotchFanStyle.topRadius, bottom = p.width / 2
            self.init(plate: p, radii: RectangleCornerRadii(topLeading: top, bottomLeading: bottom, bottomTrailing: bottom, topTrailing: top),
                      stageHeight: p.height + 52)
        case .spatial(.liquidGlassCompass):
            self = .circle(LiquidCompassStyle.plate, extra: 40)
        case .spatial(.chronoSectorDial):
            self = .circle(ChronoDialStyle.plate, extra: 30)
        case .spatial(.sonarHorizonRadar):
            self = .circle(SonarRadarStyle.plate, extra: 40)
        }
    }

    private static func circle(_ d: CGFloat, extra: CGFloat) -> StageLayout {
        let r = d / 2
        return StageLayout(plate: CGSize(width: d, height: d),
                           radii: RectangleCornerRadii(topLeading: r, bottomLeading: r, bottomTrailing: r, topTrailing: r),
                           stageHeight: d + extra)
    }
}
