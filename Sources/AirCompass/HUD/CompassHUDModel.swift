import AirCompassCore
import AppKit
import Observation
import SwiftUI

/// Everything the HUD renders. Mutated by the coordinators, observed by SwiftUI.
@MainActor
@Observable
final class CompassHUDModel {
    enum Mode: Equatable {
        case hidden
        /// Idle radar (Preview Compass HUD toggle).
        case preview
        /// 3-finger drag in progress, then sending.
        case sending
        /// Incoming files from a peer.
        case receiving
    }

    var mode: Mode = .hidden
    /// Mode A (even layout) or Mode B (true bearings).
    var family: HUDFamily = .uniform
    var uniformStyle: NonDirectionalStyle = .orbitalHalo
    var spatialStyle: SpatialCompassStyle = .liquidGlassCompass
    var sectorMode: SectorMode = .four
    var nodes: [CompassNodeModel] = []
    var vector: GestureVector?
    var isArmed = false
    var activeSector: Int?
    var files: [URL] = []
    var targetName: String?
    var transfer: TransferProgress?
    /// Message shown under the compass ("Pull further to send", errors, ...).
    var message: String?
    /// Where the HUD sits: pinned under the menu bar / notch, or with the
    /// glass centered on the selected files (see `CompassHUDPanel.present`).
    var pinnedToTop = true
    /// Shows the A1…B3 switcher pill (preview mode only).
    var showsStyleSwitcher = false
    var glass = GlassAppearance()
    @ObservationIgnored var onSelectStyle: ((HUDStyle) -> Void)?
    @ObservationIgnored var onSetGlass: ((GlassAppearance) -> Void)?
    @ObservationIgnored var onOpenLab: (() -> Void)?

    var style: HUDStyle {
        family == .uniform ? .uniform(uniformStyle) : .spatial(spatialStyle)
    }

    var fileIcon: NSImage? {
        guard let first = files.first else { return nil }
        return NSWorkspace.shared.icon(forFile: first.path)
    }

    var thumbnail: NSImage? {
        transfer?.thumbnail.flatMap(NSImage.init(data:))
    }

    var fileCount: Int {
        mode == .receiving ? (transfer?.files.count ?? 0) : files.count
    }

    /// Tether colour: cyan while aiming, emerald once release would send.
    var tint: Color { isArmed ? CompassPalette.armed : CompassPalette.accent }

    /// The node files would go to right now.
    var targetNode: CompassNodeModel? { nodes.first(where: \.isTarget) }
}
