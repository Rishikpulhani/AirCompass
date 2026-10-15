import Foundation

public enum DeviceKind: String, Codable, Sendable, CaseIterable {
    case mac
    case iPhone
    case iPad

    /// SF Symbol used for compass nodes.
    public var symbolName: String {
        switch self {
        case .mac: "laptopcomputer"
        case .iPhone: "iphone"
        case .iPad: "ipad.landscape"
        }
    }
}

/// Where a peer's azimuth came from. Shown in the UI so it's clear which
/// positions are measured and which are set by hand.
public enum PositionSource: String, Codable, Sendable {
    case unknown
    /// Dragged on the companion's orbit dial.
    case manual
    /// Companion gyroscope/magnetometer offset from a calibrated reference.
    case motion
    /// Measured from stereo ultrasonic chirps (left/right + hemisphere).
    case acoustic
    /// Debug peer generated locally.
    case simulated
}

/// A nearby device as placed on the compass, relative to this device.
/// Angles are compass bearings in degrees: 0 = North (behind the display),
/// 90 = East (right), 180 = South (toward the user), 270 = West (left).
public struct PeerDevice: Identifiable, Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var deviceKind: DeviceKind
    /// Last bearing reported for this peer, unfiltered.
    public var rawAzimuthDegrees: Double
    /// Circular-EMA filtered bearing; drives sector assignment.
    public var smoothedAzimuthDegrees: Double
    public var assignedSector: Int
    /// Where the node is drawn and magnified. Equals the smoothed bearing,
    /// unless several peers share a sector and are fanned out to stay selectable.
    public var displayAzimuthDegrees: Double
    public var distanceMeters: Double?
    public var isSimulated: Bool
    public var positionSource: PositionSource
    public var isConnected: Bool
    public var hasPosition: Bool

    public init(
        id: String,
        name: String,
        deviceKind: DeviceKind,
        azimuthDegrees: Double = 0,
        distanceMeters: Double? = nil,
        isSimulated: Bool = false,
        positionSource: PositionSource = .unknown,
        isConnected: Bool = true,
        hasPosition: Bool = false
    ) {
        self.id = id
        self.name = name
        self.deviceKind = deviceKind
        self.rawAzimuthDegrees = azimuthDegrees
        self.smoothedAzimuthDegrees = azimuthDegrees
        self.assignedSector = 0
        self.displayAzimuthDegrees = azimuthDegrees
        self.distanceMeters = distanceMeters
        self.isSimulated = isSimulated
        self.positionSource = positionSource
        self.isConnected = isConnected
        self.hasPosition = hasPosition
    }
}
