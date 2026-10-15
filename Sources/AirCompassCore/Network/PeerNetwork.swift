import Foundation
import Network
import os

/// Who this device is on the AirCompass network.
public struct LocalIdentity: Sendable, Equatable {
    public var id: String
    public var name: String
    public var kind: DeviceKind

    public init(id: String, name: String, kind: DeviceKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    /// Stable per-install identifier persisted in UserDefaults.
    public static func persistentID(defaults: UserDefaults = .standard) -> String {
        if let id = defaults.string(forKey: "AirCompass.peerID") { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "AirCompass.peerID")
        return id
    }
}

// MARK: - Connection

/// One framed TCP connection to a peer. All callbacks arrive on the main queue.
@MainActor
final class PeerConnection {
    let connection: NWConnection
    let isOutgoing: Bool
    private(set) var hello: PeerHelloFrame?
    private var decoder = FrameDecoder()

    var onReady: (() -> Void)?
    var onFrame: ((WireFrame) -> Void)?
    var onClose: ((Error?) -> Void)?
    private var closed = false

    init(connection: NWConnection, isOutgoing: Bool) {
        self.connection = connection
        self.isOutgoing = isOutgoing
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.onReady?()
                    self.receiveNext()
                case let .failed(error):
                    self.close(error)
                case .cancelled:
                    self.close(nil)
                case let .waiting(error):
                    // Peer-to-peer paths that can't come up quickly are abandoned;
                    // the browser will offer the peer again.
                    self.close(error)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    func setHello(_ hello: PeerHelloFrame) { self.hello = hello }

    func send(_ frame: WireFrame, completion: (@MainActor (Error?) -> Void)? = nil) {
        let data: Data
        do {
            data = try FrameCodec.encode(frame)
        } catch {
            completion?(error)
            return
        }
        connection.send(content: data, completion: .contentProcessed { error in
            MainActor.assumeIsolated { completion?(error) }
        })
    }

    /// Async send that resumes once the bytes are handed to the network stack;
    /// awaiting it in a loop provides natural backpressure for file streaming.
    func send(_ frame: WireFrame) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(frame) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func cancel() {
        connection.cancel()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty {
                    self.decoder.append(data)
                    do {
                        while let frame = try self.decoder.next() {
                            if case let .hello(h) = frame { self.hello = h }
                            self.onFrame?(frame)
                        }
                    } catch {
                        self.close(error)
                        return
                    }
                }
                if let error {
                    self.close(error)
                } else if isComplete {
                    self.close(nil)
                } else {
                    self.receiveNext()
                }
            }
        }
    }

    private func close(_ error: Error?) {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?(error)
    }
}

// MARK: - Network

/// Bonjour discovery + framed TCP connections over infrastructure Wi-Fi and
/// Apple Wireless Direct Link (`includePeerToPeer`), the same peer-to-peer
/// radio path AirDrop uses.
///
/// Every device both advertises and browses. To avoid duplicate links, only
/// the side with the lexicographically smaller peer ID dials out.
@MainActor
public final class PeerNetwork {
    public var onPeerConnected: ((PeerHelloFrame) -> Void)?
    public var onPeerUpdated: ((PeerHelloFrame) -> Void)?
    public var onPeerDisconnected: ((String) -> Void)?
    public var onFrame: ((String, WireFrame) -> Void)?

    public private(set) var identity: LocalIdentity
    public private(set) var localHello: PeerHelloFrame
    public private(set) var isRunning = false
    public private(set) var lastError: String?

    /// Connected peers that completed the hello exchange.
    public var connectedPeers: [PeerHelloFrame] {
        connections.values.compactMap(\.hello)
    }

    private var listener: NWListener?
    private var browser: NWBrowser?
    /// Identified connections by peer ID.
    private var connections: [String: PeerConnection] = [:]
    /// Connections that haven't sent a hello yet.
    private var pending: [ObjectIdentifier: PeerConnection] = [:]
    /// Peer IDs we're currently dialing.
    private var dialing: Set<String> = []
    private let log = Logger(subsystem: "com.aircompass.AirCompass", category: "Network")

    public init(identity: LocalIdentity) {
        self.identity = identity
        self.localHello = PeerHelloFrame(peerID: identity.id, name: identity.name, kind: identity.kind)
    }

    private static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true
        return params
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        startListener()
        startBrowser()
    }

    public func stop() {
        isRunning = false
        listener?.cancel()
        browser?.cancel()
        listener = nil
        browser = nil
        connections.values.forEach { $0.cancel() }
        pending.values.forEach { $0.cancel() }
        connections.removeAll()
        pending.removeAll()
        dialing.removeAll()
    }

    /// Updates the hello broadcast to every connected peer.
    public func updateHello(_ mutate: (inout PeerHelloFrame) -> Void) {
        var hello = localHello
        mutate(&hello)
        guard hello != localHello else { return }
        localHello = hello
        identity.name = hello.name
        broadcast(.hello(hello))
        // Bonjour name follows the user-visible name.
        if isRunning, listener?.service?.name != hello.name {
            listener?.cancel()
            startListener()
        }
    }

    public func send(_ frame: WireFrame, to peerID: String) {
        connections[peerID]?.send(frame)
    }

    func connection(for peerID: String) -> PeerConnection? { connections[peerID] }

    public func broadcast(_ frame: WireFrame, filter: ((PeerHelloFrame) -> Bool)? = nil) {
        for connection in connections.values {
            guard let hello = connection.hello else { continue }
            if let filter, !filter(hello) { continue }
            connection.send(frame)
        }
    }

    // MARK: Listener

    private func startListener() {
        do {
            let listener = try NWListener(using: Self.parameters())
            let txt = NWTXTRecord(["id": identity.id, "kind": identity.kind.rawValue])
            listener.service = NWListener.Service(name: localHello.name, type: WireProtocol.serviceType, txtRecord: txt)
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.adopt(connection, outgoing: false, expectedID: nil) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.lastError = nil
                        self.log.info("Listener ready on port \(listener.port?.rawValue ?? 0)")
                    case let .failed(error):
                        self.lastError = "Listener: \(error)"
                        self.log.error("Listener failed: \(String(describing: error), privacy: .public); restarting")
                        listener.cancel()
                        self.restartListenerSoon()
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            lastError = "Listener: \(error)"
            log.error("Could not create listener: \(String(describing: error), privacy: .public)")
            restartListenerSoon()
        }
    }

    private func restartListenerSoon() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.isRunning else { return }
            self.startListener()
        }
    }

    // MARK: Browser

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: WireProtocol.serviceType, domain: nil), using: Self.parameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.evaluate(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case let .failed(error) = state {
                    self?.lastError = "Browser: \(error)"
                    self?.log.error("Browser failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func evaluate(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case let .bonjour(txt) = result.metadata, let remoteID = txt["id"] else { continue }
            guard remoteID != identity.id,
                  identity.id < remoteID,            // only the smaller ID dials
                  connections[remoteID] == nil,
                  !dialing.contains(remoteID) else { continue }

            dialing.insert(remoteID)
            log.info("Dialing peer \(remoteID, privacy: .public)")
            adopt(NWConnection(to: result.endpoint, using: Self.parameters()), outgoing: true, expectedID: remoteID)
        }
    }

    /// Re-dial anything still visible after a connection drops.
    private func reevaluateSoon() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.isRunning, let results = self.browser?.browseResults else { return }
            self.evaluate(results)
        }
    }

    // MARK: Connection lifecycle

    private func adopt(_ nw: NWConnection, outgoing: Bool, expectedID: String?) {
        let connection = PeerConnection(connection: nw, isOutgoing: outgoing)
        let key = ObjectIdentifier(connection)
        pending[key] = connection

        connection.onReady = { [weak self, weak connection] in
            guard let self, let connection else { return }
            connection.send(.hello(self.localHello))
        }
        connection.onFrame = { [weak self, weak connection] frame in
            guard let self, let connection else { return }
            self.handle(frame, on: connection)
        }
        connection.onClose = { [weak self, weak connection] error in
            guard let self, let connection else { return }
            self.pending[ObjectIdentifier(connection)] = nil
            if let expectedID { self.dialing.remove(expectedID) }
            if let id = connection.hello?.peerID, self.connections[id] === connection {
                self.connections[id] = nil
                self.log.info("Peer \(id, privacy: .public) disconnected: \(String(describing: error), privacy: .public)")
                self.onPeerDisconnected?(id)
            }
            self.reevaluateSoon()
        }
        connection.start()
    }

    private func handle(_ frame: WireFrame, on connection: PeerConnection) {
        if case let .hello(hello) = frame {
            let key = ObjectIdentifier(connection)
            if pending.removeValue(forKey: key) != nil {
                dialing.remove(hello.peerID)
                if let old = connections[hello.peerID], old !== connection { old.cancel() }
                connections[hello.peerID] = connection
                log.info("Peer connected: \(hello.name, privacy: .public) (\(hello.kind.rawValue, privacy: .public))")
                onPeerConnected?(hello)
            } else {
                onPeerUpdated?(hello)
            }
            return
        }
        guard let id = connection.hello?.peerID else { return }
        onFrame?(id, frame)
    }
}
