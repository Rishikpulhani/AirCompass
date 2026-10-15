import Foundation

// MARK: - Frames

public enum WireProtocol {
    public static let serviceType = "_aircompass._tcp"
    public static let version = 1
    public static let chunkSize = 64 * 1024
    /// Upper bound for any single frame (thumbnails are the largest control payload).
    public static let maxFrameLength = 8 * 1024 * 1024
}

/// First frame on every connection; re-sent when settings change.
public struct PeerHelloFrame: Codable, Sendable, Equatable {
    public var peerID: String
    public var name: String
    public var kind: DeviceKind
    public var protocolVersion: Int
    /// The peer is in acoustic positioning mode and wants chirp probes.
    public var wantsAcousticProbes: Bool
    /// The sender's compass sector mode (Macs only).
    public var sectorMode: SectorMode?

    public init(peerID: String, name: String, kind: DeviceKind, protocolVersion: Int = WireProtocol.version,
                wantsAcousticProbes: Bool = false, sectorMode: SectorMode? = nil) {
        self.peerID = peerID
        self.name = name
        self.kind = kind
        self.protocolVersion = protocolVersion
        self.wantsAcousticProbes = wantsAcousticProbes
        self.sectorMode = sectorMode
    }
}

/// "My bearing relative to you is …". Sent by the device being placed.
public struct PositionUpdateFrame: Codable, Sendable, Equatable {
    public var peerID: String
    public var azimuthDegrees: Double
    public var distanceMeters: Double?
    public var source: PositionSource
    /// Acoustic fixes include their quality (peak-to-noise ratio).
    public var confidence: Double?

    public init(peerID: String, azimuthDegrees: Double, distanceMeters: Double? = nil,
                source: PositionSource, confidence: Double? = nil) {
        self.peerID = peerID
        self.azimuthDegrees = azimuthDegrees
        self.distanceMeters = distanceMeters
        self.source = source
        self.confidence = confidence
    }
}

/// Live 3-finger drag state, broadcast by the Mac at up to 60 Hz.
public struct GestureMirrorFrame: Codable, Sendable, Equatable {
    public var senderID: String
    public var r: Double
    /// Bearing in radians.
    public var theta: Double
    public var isActive: Bool
    public var isArmed: Bool
    public var isCommitted: Bool
    public var targetPeerID: String?
    public var fileNames: [String]
    /// Dock magnification per peer, so each receiver can scale its own node.
    public var peerScales: [String: Double]
    public var sectorMode: SectorMode

    public init(senderID: String, r: Double, theta: Double, isActive: Bool, isArmed: Bool, isCommitted: Bool,
                targetPeerID: String?, fileNames: [String], peerScales: [String: Double], sectorMode: SectorMode) {
        self.senderID = senderID
        self.r = r
        self.theta = theta
        self.isActive = isActive
        self.isArmed = isArmed
        self.isCommitted = isCommitted
        self.targetPeerID = targetPeerID
        self.fileNames = fileNames
        self.peerScales = peerScales
        self.sectorMode = sectorMode
    }
}

public struct TransferFileInfo: Codable, Sendable, Equatable, Hashable {
    public var name: String
    public var size: Int64
    /// Lowercase hex SHA-256 of the file contents.
    public var sha256: String

    public init(name: String, size: Int64, sha256: String) {
        self.name = name
        self.size = size
        self.sha256 = sha256
    }
}

public struct TransferHeaderFrame: Codable, Sendable, Equatable {
    public var transferID: UUID
    public var senderID: String
    public var senderName: String
    public var senderKind: DeviceKind
    /// Bearing of the receiver as seen by the sender (receiver flips it 180°
    /// if it has no position of its own for the sender).
    public var senderRelativeAzimuthDegrees: Double?
    public var files: [TransferFileInfo]
    /// Small PNG preview of the first file.
    public var thumbnail: Data?

    public init(transferID: UUID, senderID: String, senderName: String, senderKind: DeviceKind,
                senderRelativeAzimuthDegrees: Double?, files: [TransferFileInfo], thumbnail: Data?) {
        self.transferID = transferID
        self.senderID = senderID
        self.senderName = senderName
        self.senderKind = senderKind
        self.senderRelativeAzimuthDegrees = senderRelativeAzimuthDegrees
        self.files = files
        self.thumbnail = thumbnail
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

/// Raw file bytes. Encoded in binary, not JSON, to avoid base64 overhead.
public struct TransferChunkFrame: Sendable, Equatable {
    public var transferID: UUID
    public var fileIndex: UInt32
    public var offset: UInt64
    public var data: Data

    public init(transferID: UUID, fileIndex: UInt32, offset: UInt64, data: Data) {
        self.transferID = transferID
        self.fileIndex = fileIndex
        self.offset = offset
        self.data = data
    }
}

public struct TransferAckFrame: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case accepted, progress, completed, failed
    }

    public var transferID: UUID
    public var status: Status
    public var bytesReceived: Int64
    public var message: String?

    public init(transferID: UUID, status: Status, bytesReceived: Int64, message: String? = nil) {
        self.transferID = transferID
        self.status = status
        self.bytesReceived = bytesReceived
        self.message = message
    }
}

/// "Listen now: I'm about to play a left-then-right chirp pair."
public struct AcousticProbeFrame: Codable, Sendable, Equatable {
    public var probeID: UUID
    public var emitterID: String
    /// Silence before the left chirp, giving the listener time to start its mic.
    public var leadInSeconds: Double
    /// Time between the start of the left chirp and the start of the right chirp.
    public var slotGapSeconds: Double
    public var chirp: ChirpSpec
    /// Distance between the emitter's left and right speakers.
    public var speakerSpacingMeters: Double

    public init(probeID: UUID, emitterID: String, leadInSeconds: Double, slotGapSeconds: Double,
                chirp: ChirpSpec, speakerSpacingMeters: Double) {
        self.probeID = probeID
        self.emitterID = emitterID
        self.leadInSeconds = leadInSeconds
        self.slotGapSeconds = slotGapSeconds
        self.chirp = chirp
        self.speakerSpacingMeters = speakerSpacingMeters
    }
}

/// "I'm moving — chirp now please." Sent by a listener so the emitter can
/// probe on demand instead of waiting for its periodic timer.
public struct AcousticProbeRequestFrame: Codable, Sendable, Equatable {
    public var peerID: String

    public init(peerID: String) {
        self.peerID = peerID
    }
}

public enum WireFrame: Sendable, Equatable {
    case hello(PeerHelloFrame)
    case position(PositionUpdateFrame)
    case gestureMirror(GestureMirrorFrame)
    case transferHeader(TransferHeaderFrame)
    case transferChunk(TransferChunkFrame)
    case transferAck(TransferAckFrame)
    case acousticProbe(AcousticProbeFrame)
    case acousticProbeRequest(AcousticProbeRequestFrame)
}

// MARK: - Codec

public enum FrameCodecError: Error, Equatable {
    case unknownType(UInt8)
    case frameTooLarge(Int)
    case malformedChunk
}

/// Wire layout: `[type: UInt8][length: UInt32 big-endian][payload]`.
/// Control payloads are JSON; chunk payloads are
/// `[transferID: 16][fileIndex: UInt32 BE][offset: UInt64 BE][bytes]`.
public enum FrameCodec {
    enum TypeCode: UInt8 {
        case hello = 1, position, gestureMirror, transferHeader, transferChunk, transferAck, acousticProbe, acousticProbeRequest
    }

    static let headerLength = 5
    static let chunkPrefixLength = 16 + 4 + 8

    public static func encode(_ frame: WireFrame) throws -> Data {
        let encoder = JSONEncoder()
        let (type, payload): (TypeCode, Data) = switch frame {
        case let .hello(f): (.hello, try encoder.encode(f))
        case let .position(f): (.position, try encoder.encode(f))
        case let .gestureMirror(f): (.gestureMirror, try encoder.encode(f))
        case let .transferHeader(f): (.transferHeader, try encoder.encode(f))
        case let .transferChunk(f): (.transferChunk, encodeChunk(f))
        case let .transferAck(f): (.transferAck, try encoder.encode(f))
        case let .acousticProbe(f): (.acousticProbe, try encoder.encode(f))
        case let .acousticProbeRequest(f): (.acousticProbeRequest, try encoder.encode(f))
        }
        guard payload.count <= WireProtocol.maxFrameLength else { throw FrameCodecError.frameTooLarge(payload.count) }

        var data = Data(capacity: headerLength + payload.count)
        data.append(type.rawValue)
        data.appendBigEndian(UInt32(payload.count))
        data.append(payload)
        return data
    }

    static func decode(type rawType: UInt8, payload: Data) throws -> WireFrame {
        guard let type = TypeCode(rawValue: rawType) else { throw FrameCodecError.unknownType(rawType) }
        let decoder = JSONDecoder()
        switch type {
        case .hello: return .hello(try decoder.decode(PeerHelloFrame.self, from: payload))
        case .position: return .position(try decoder.decode(PositionUpdateFrame.self, from: payload))
        case .gestureMirror: return .gestureMirror(try decoder.decode(GestureMirrorFrame.self, from: payload))
        case .transferHeader: return .transferHeader(try decoder.decode(TransferHeaderFrame.self, from: payload))
        case .transferChunk: return .transferChunk(try decodeChunk(payload))
        case .transferAck: return .transferAck(try decoder.decode(TransferAckFrame.self, from: payload))
        case .acousticProbe: return .acousticProbe(try decoder.decode(AcousticProbeFrame.self, from: payload))
        case .acousticProbeRequest: return .acousticProbeRequest(try decoder.decode(AcousticProbeRequestFrame.self, from: payload))
        }
    }

    private static func encodeChunk(_ chunk: TransferChunkFrame) -> Data {
        var data = Data(capacity: chunkPrefixLength + chunk.data.count)
        withUnsafeBytes(of: chunk.transferID.uuid) { data.append(contentsOf: $0) }
        data.appendBigEndian(chunk.fileIndex)
        data.appendBigEndian(chunk.offset)
        data.append(chunk.data)
        return data
    }

    private static func decodeChunk(_ payload: Data) throws -> TransferChunkFrame {
        guard payload.count >= chunkPrefixLength else { throw FrameCodecError.malformedChunk }
        let bytes = [UInt8](payload.prefix(chunkPrefixLength))
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        let fileIndex = bytes[16..<20].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let offset = bytes[20..<28].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let start = payload.startIndex + chunkPrefixLength
        return TransferChunkFrame(transferID: uuid, fileIndex: fileIndex, offset: offset, data: Data(payload[start...]))
    }
}

/// Incremental decoder for a TCP byte stream: append whatever arrives, then
/// drain complete frames with `next()`.
public struct FrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    public mutating func next() throws -> WireFrame? {
        guard buffer.count >= FrameCodec.headerLength else { return nil }
        let base = buffer.startIndex
        let type = buffer[base]
        let length = Int(buffer[(base + 1)..<(base + 5)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard length <= WireProtocol.maxFrameLength else { throw FrameCodecError.frameTooLarge(length) }
        guard buffer.count >= FrameCodec.headerLength + length else { return nil }

        let payload = buffer.subdata(in: (base + FrameCodec.headerLength)..<(base + FrameCodec.headerLength + length))
        buffer.removeSubrange(base..<(base + FrameCodec.headerLength + length))
        // Skip frame types from newer app versions instead of dropping the link.
        guard FrameCodec.TypeCode(rawValue: type) != nil else { return try next() }
        return try FrameCodec.decode(type: type, payload: payload)
    }
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
