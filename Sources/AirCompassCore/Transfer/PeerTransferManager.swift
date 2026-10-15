import CryptoKit
import Foundation
import Observation
import os
import QuickLookThumbnailing
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Live state of one transfer, for HUDs on both ends.
public struct TransferProgress: Identifiable, Sendable, Equatable {
    public enum Direction: Sendable, Equatable { case outgoing, incoming }

    public enum State: Sendable, Equatable {
        case preparing
        case transferring
        case completed([URL])
        case failed(String)

        public var isFinished: Bool {
            switch self {
            case .completed, .failed: true
            case .preparing, .transferring: false
            }
        }
    }

    public var id: UUID
    public var direction: Direction
    public var peerID: String
    public var peerName: String
    public var peerKind: DeviceKind
    public var files: [TransferFileInfo]
    public var bytesTransferred: Int64
    public var totalBytes: Int64
    public var state: State
    /// For incoming transfers: the bearing the sender is at, from our point of view.
    public var peerAzimuthDegrees: Double?
    public var thumbnail: Data?
    public var isSimulated: Bool

    public var fraction: Double {
        totalBytes > 0 ? min(1, Double(bytesTransferred) / Double(totalBytes)) : (state.isFinished ? 1 : 0)
    }
}

public enum TransferError: Error, CustomStringConvertible {
    case peerNotConnected
    case noFiles
    case unreadable(String)
    case rejected(String)

    public var description: String {
        switch self {
        case .peerNotConnected: "Peer is not connected"
        case .noFiles: "No regular files to send (folders aren't supported yet)"
        case let .unreadable(name): "Couldn't read \(name)"
        case let .rejected(message): "Receiver reported: \(message)"
        }
    }
}

/// Streams files between peers: JSON header, 64 KB binary chunks, SHA-256
/// verification on the receiver, then a completion ack.
@MainActor
@Observable
public final class PeerTransferManager {
    public private(set) var transfers: [UUID: TransferProgress] = [:]

    /// Fired when an incoming header arrives (summon the receiver HUD).
    @ObservationIgnored public var onIncoming: ((TransferProgress) -> Void)?
    /// Fired on every progress/state change.
    @ObservationIgnored public var onChange: ((TransferProgress) -> Void)?
    /// Receiver-side bearing lookup for a sender, if positioning knows it.
    @ObservationIgnored public var azimuthForPeer: ((String) -> Double?)?

    @ObservationIgnored private let network: PeerNetwork
    @ObservationIgnored private let inbox: URL
    @ObservationIgnored private var incoming: [UUID: IncomingTransfer] = [:]
    @ObservationIgnored private var completionWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    /// Acks that arrived before the sender started waiting (tiny files, fast links).
    @ObservationIgnored private var earlyAcks: [UUID: TransferAckFrame] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "com.aircompass.AirCompass", category: "Transfer")

    public init(network: PeerNetwork, inbox: URL) {
        self.network = network
        self.inbox = inbox
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    public var activeTransfers: [TransferProgress] {
        transfers.values.filter { !$0.state.isFinished }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    // MARK: - Sending

    /// Sends files and returns once the receiver confirms every file verified.
    @discardableResult
    public func send(
        files urls: [URL],
        to peer: PeerHelloFrame,
        receiverAzimuthDegrees: Double?
    ) async throws -> UUID {
        let regular = urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        guard !regular.isEmpty else { throw TransferError.noFiles }
        guard let connection = network.connection(for: peer.peerID) else { throw TransferError.peerNotConnected }

        let id = UUID()
        update(TransferProgress(
            id: id, direction: .outgoing, peerID: peer.peerID, peerName: peer.name, peerKind: peer.kind,
            files: regular.map { TransferFileInfo(name: $0.lastPathComponent, size: 0, sha256: "") },
            bytesTransferred: 0, totalBytes: 0, state: .preparing,
            peerAzimuthDegrees: receiverAzimuthDegrees, thumbnail: nil, isSimulated: false
        ))

        do {
            // Hashing can take a while for large files; keep it off the main actor.
            let infos = try await Task.detached(priority: .userInitiated) { try regular.map(Self.describe) }.value
            let thumbnail = await Self.thumbnail(for: regular[0])

            var progress = transfers[id]!
            progress.files = infos
            progress.totalBytes = infos.reduce(0) { $0 + $1.size }
            progress.thumbnail = thumbnail
            progress.state = .transferring
            update(progress)

            let identity = network.identity
            try await connection.send(.transferHeader(TransferHeaderFrame(
                transferID: id, senderID: identity.id, senderName: identity.name, senderKind: identity.kind,
                senderRelativeAzimuthDegrees: receiverAzimuthDegrees, files: infos, thumbnail: thumbnail
            )))

            var sent: Int64 = 0
            for (index, url) in regular.enumerated() {
                guard let handle = try? FileHandle(forReadingFrom: url) else { throw TransferError.unreadable(url.lastPathComponent) }
                defer { try? handle.close() }
                var offset: UInt64 = 0
                while let data = try handle.read(upToCount: WireProtocol.chunkSize), !data.isEmpty {
                    try await connection.send(.transferChunk(TransferChunkFrame(
                        transferID: id, fileIndex: UInt32(index), offset: offset, data: data
                    )))
                    offset += UInt64(data.count)
                    sent += Int64(data.count)
                    progress.bytesTransferred = sent
                    update(progress)
                }
            }

            // Wait for the receiver's verified-completion ack.
            if let ack = earlyAcks.removeValue(forKey: id) {
                if ack.status == .failed { throw TransferError.rejected(ack.message ?? "unknown error") }
            } else {
                try await withCheckedThrowingContinuation { completionWaiters[id] = $0 }
            }
            progress.bytesTransferred = progress.totalBytes
            progress.state = .completed(regular)
            update(progress)
            log.info("Sent \(regular.count) file(s) to \(peer.name, privacy: .public)")
            return id
        } catch {
            completionWaiters[id] = nil
            if var progress = transfers[id] {
                progress.state = .failed(String(describing: error))
                update(progress)
            }
            throw error
        }
    }

    /// Animated stand-in for sending to a simulated peer (no network).
    public func simulateSend(files urls: [URL], to peer: PeerDevice) async {
        let id = UUID()
        let infos = urls.map { url in
            TransferFileInfo(name: url.lastPathComponent,
                             size: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1_000_000),
                             sha256: "")
        }
        var progress = TransferProgress(
            id: id, direction: .outgoing, peerID: peer.id, peerName: peer.name, peerKind: peer.deviceKind,
            files: infos, bytesTransferred: 0, totalBytes: max(1, infos.reduce(0) { $0 + $1.size }),
            state: .transferring, peerAzimuthDegrees: peer.smoothedAzimuthDegrees, thumbnail: nil, isSimulated: true
        )
        update(progress)
        for step in 1...30 {
            try? await Task.sleep(for: .milliseconds(40))
            progress.bytesTransferred = progress.totalBytes * Int64(step) / 30
            update(progress)
        }
        progress.state = .completed(urls)
        update(progress)
    }

    // MARK: - Receiving

    private final class IncomingTransfer {
        let header: TransferHeaderFrame
        let staging: URL
        var fileIndex = 0
        var handle: FileHandle?
        var hasher = SHA256()
        var written: Int64 = 0
        var fileWritten: Int64 = 0
        var finished: [URL] = []

        init(header: TransferHeaderFrame, staging: URL) {
            self.header = header
            self.staging = staging
        }
    }

    public func handle(_ frame: WireFrame, from peerID: String) {
        switch frame {
        case let .transferHeader(header): receiveHeader(header, from: peerID)
        case let .transferChunk(chunk): receiveChunk(chunk, from: peerID)
        case let .transferAck(ack): receiveAck(ack)
        default: break
        }
    }

    private func receiveHeader(_ header: TransferHeaderFrame, from peerID: String) {
        let staging = inbox.appendingPathComponent(".aircompass-\(header.transferID.uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            network.send(.transferAck(TransferAckFrame(transferID: header.transferID, status: .failed, bytesReceived: 0,
                                                       message: "Can't write to inbox")), to: peerID)
            return
        }
        let transfer = IncomingTransfer(header: header, staging: staging)
        incoming[header.transferID] = transfer

        // Prefer our own measured bearing for the sender; else flip theirs.
        let azimuth = azimuthForPeer?(peerID)
            ?? header.senderRelativeAzimuthDegrees.map { AngleMath.normalizeDegrees($0 + 180) }
        let progress = TransferProgress(
            id: header.transferID, direction: .incoming, peerID: peerID, peerName: header.senderName,
            peerKind: header.senderKind, files: header.files, bytesTransferred: 0, totalBytes: header.totalBytes,
            state: .transferring, peerAzimuthDegrees: azimuth, thumbnail: header.thumbnail, isSimulated: false
        )
        update(progress)
        onIncoming?(progress)
        network.send(.transferAck(TransferAckFrame(transferID: header.transferID, status: .accepted, bytesReceived: 0)), to: peerID)

        // Zero-byte files never receive chunks.
        advanceOverEmptyFiles(transfer, peerID: peerID)
    }

    private func receiveChunk(_ chunk: TransferChunkFrame, from peerID: String) {
        guard let transfer = incoming[chunk.transferID], Int(chunk.fileIndex) == transfer.fileIndex else { return }
        let info = transfer.header.files[transfer.fileIndex]
        do {
            if transfer.handle == nil {
                let partial = transfer.staging.appendingPathComponent("\(transfer.fileIndex).part")
                FileManager.default.createFile(atPath: partial.path, contents: nil)
                transfer.handle = try FileHandle(forWritingTo: partial)
            }
            try transfer.handle?.write(contentsOf: chunk.data)
            transfer.hasher.update(data: chunk.data)
            transfer.fileWritten += Int64(chunk.data.count)
            transfer.written += Int64(chunk.data.count)

            if var progress = transfers[chunk.transferID] {
                progress.bytesTransferred = transfer.written
                update(progress)
            }
            if transfer.fileWritten >= info.size {
                try finishCurrentFile(transfer)
                advanceOverEmptyFiles(transfer, peerID: peerID)
            }
        } catch {
            fail(transfer, peerID: peerID, message: String(describing: error))
        }
    }

    private func advanceOverEmptyFiles(_ transfer: IncomingTransfer, peerID: String) {
        do {
            while transfer.fileIndex < transfer.header.files.count, transfer.header.files[transfer.fileIndex].size == 0 {
                FileManager.default.createFile(atPath: transfer.staging.appendingPathComponent("\(transfer.fileIndex).part").path, contents: nil)
                try finishCurrentFile(transfer)
            }
        } catch {
            fail(transfer, peerID: peerID, message: String(describing: error))
            return
        }
        guard transfer.fileIndex >= transfer.header.files.count else { return }

        let id = transfer.header.transferID
        incoming[id] = nil
        try? FileManager.default.removeItem(at: transfer.staging)
        network.send(.transferAck(TransferAckFrame(transferID: id, status: .completed, bytesReceived: transfer.written)), to: peerID)
        if var progress = transfers[id] {
            progress.bytesTransferred = progress.totalBytes
            progress.state = .completed(transfer.finished)
            update(progress)
        }
        log.info("Received \(transfer.finished.count) file(s) from \(transfer.header.senderName, privacy: .public)")
    }

    private func finishCurrentFile(_ transfer: IncomingTransfer) throws {
        try transfer.handle?.close()
        transfer.handle = nil
        let info = transfer.header.files[transfer.fileIndex]
        let digest = transfer.hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let partial = transfer.staging.appendingPathComponent("\(transfer.fileIndex).part")
        // Empty files hash the same as an empty hasher; compare for all.
        guard digest == info.sha256 else {
            throw TransferError.rejected("Checksum mismatch for \(info.name)")
        }
        let destination = Self.uniqueURL(in: inbox, name: Self.sanitized(info.name))
        try FileManager.default.moveItem(at: partial, to: destination)
        transfer.finished.append(destination)
        transfer.fileIndex += 1
        transfer.hasher = SHA256()
        transfer.fileWritten = 0
    }

    private func fail(_ transfer: IncomingTransfer, peerID: String, message: String) {
        let id = transfer.header.transferID
        try? transfer.handle?.close()
        incoming[id] = nil
        try? FileManager.default.removeItem(at: transfer.staging)
        network.send(.transferAck(TransferAckFrame(transferID: id, status: .failed, bytesReceived: transfer.written, message: message)), to: peerID)
        if var progress = transfers[id] {
            progress.state = .failed(message)
            update(progress)
        }
        log.error("Incoming transfer failed: \(message, privacy: .public)")
    }

    private func receiveAck(_ ack: TransferAckFrame) {
        switch ack.status {
        case .accepted, .progress:
            break
        case .completed, .failed:
            guard let waiter = completionWaiters.removeValue(forKey: ack.transferID) else {
                earlyAcks[ack.transferID] = ack
                return
            }
            if ack.status == .completed {
                waiter.resume()
            } else {
                waiter.resume(throwing: TransferError.rejected(ack.message ?? "unknown error"))
            }
        }
    }

    /// Peer dropped: fail anything in flight with it.
    public func peerDisconnected(_ peerID: String) {
        for (id, transfer) in incoming where transfers[id]?.peerID == peerID {
            try? transfer.handle?.close()
            try? FileManager.default.removeItem(at: transfer.staging)
            incoming[id] = nil
        }
        for (id, progress) in transfers where progress.peerID == peerID && !progress.state.isFinished {
            completionWaiters.removeValue(forKey: id)?.resume(throwing: TransferError.peerNotConnected)
            var p = progress
            p.state = .failed("Connection lost")
            update(p)
        }
    }

    // MARK: - Helpers

    private func update(_ progress: TransferProgress) {
        transfers[progress.id] = progress
        onChange?(progress)
    }

    nonisolated static func describe(_ url: URL) throws -> TransferFileInfo {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw TransferError.unreadable(url.lastPathComponent) }
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
            size += Int64(data.count)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return TransferFileInfo(name: url.lastPathComponent, size: size, sha256: digest)
    }

    nonisolated static func thumbnail(for url: URL) async -> Data? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 96), scale: 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        #if os(macOS)
        let image = rep.nsImage
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
        #else
        return rep.uiImage.pngData()
        #endif
    }

    static func sanitized(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "file" + cleaned : cleaned
    }

    static func uniqueURL(in directory: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}
