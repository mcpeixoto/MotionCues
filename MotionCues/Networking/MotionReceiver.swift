//
//  MotionReceiver.swift
//
//  Mac side of the local link. Publishes a Bonjour service and accepts UDP
//  datagrams from the iOS companion.
//
//  Design notes
//  ------------
//  * UDP, not TCP. At 100 Hz a lost datagram is worth ~10 ms of staleness;
//    a TCP retransmit would stall every *later* sample behind it
//    (head-of-line blocking) and produce a visible hitch. We would rather
//    drop than delay. Sequence numbers let us detect and ignore reordering.
//
//  * `includePeerToPeer = true`. Verified present in the macOS Swift interface
//    for `NWParameters`. This lets discovery and the data path run over
//    AWDL/peer-to-peer Wi-Fi, so the link works in a car with no Wi-Fi network
//    at all. If both devices happen to be on the same LAN or on the phone's
//    hotspot, the normal infrastructure path is used instead.
//
//  * The Mac is the listener because it is the consumer and the stable end.
//    The phone browses, connects, and re-connects; the Mac just accepts.
//
//  * We answer with a heartbeat once a second on the same connection. That is
//    the phone's only way to know a UDP peer is still alive, and it carries
//    the last sequence we saw so the phone can show link health.
//

import Foundation
import Network

final class MotionReceiver: MotionProvider {
    let kind: MotionSourceKind = .iPhone

    var onFrame: ((MotionFrame) -> Void)?
    var onStatusChange: ((MotionLinkStatus) -> Void)?
    /// Owned by `queue`; published to consumers via `onStatusChange`.
    private var status = MotionLinkStatus()

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var activeConnection: NWConnection?
    private let queue = DispatchQueue(label: "com.motioncues.receiver", qos: .userInteractive)
    private var heartbeatTimer: DispatchSourceTimer?
    private var meter = RateMeter()
    private var lastSeq: UInt32 = 0
    private var lastFrameAt: Double = 0
    private var watchdog: DispatchSourceTimer?

    /// The two devices have unrelated uptime clocks, so absolute one-way
    /// latency is not measurable without a full sync protocol. What *is*
    /// measurable, and what actually matters for smoothness, is the delay of
    /// each packet relative to the best-case packet: we track the running
    /// minimum of (ourTime − theirTime) and report each sample's excess over
    /// it. That number is the transport jitter, and it is what shows up as
    /// stutter. A slow upward creep is allowed so genuine clock drift does not
    /// pin the floor at a stale value forever.
    private var clockOffset: Double?

    private var advertiseService = true
    private var readyHandler: ((UInt16) -> Void)?

    var serviceName: String {
        ProcessInfo.processInfo.hostName
    }

    func start() {
        queue.async { [weak self] in self?.startLocked() }
    }

    /// Starts listening on an ephemeral port *without* advertising over
    /// Bonjour, and blocks until the listener is ready.
    ///
    /// Test hook. Advertising a Bonjour service triggers the Local Network
    /// permission prompt on recent macOS, which would make an automated test
    /// depend on someone clicking a dialog. Everything after discovery — the
    /// codec, ordering, counters, heartbeat — is exercised over loopback
    /// instead.
    /// - Returns: the bound port, or nil if the listener did not come up.
    func startForTesting(timeout: TimeInterval = 5) -> UInt16? {
        let semaphore = DispatchSemaphore(value: 0)
        var boundPort: UInt16?
        queue.async { [self] in
            advertiseService = false
            readyHandler = { port in
                boundPort = port
                semaphore.signal()
            }
            startLocked()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return boundPort
    }

    private func startLocked() {
        guard listener == nil else { return }
        meter.reset()
        status.source = .iPhone
        status.connected = false
        status.detail = "Advertising \(MotionCuesService.bonjourType)…"
        onStatusChange?(status)

        let params = NWParameters.udp
        params.includePeerToPeer = true
        params.allowLocalEndpointReuse = true
        // Nothing here is worth a retransmit; keep the stack out of the way.
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .any
        }

        do {
            let listener = try NWListener(using: params)
            if advertiseService {
                listener.service = NWListener.Service(name: serviceName,
                                                      type: MotionCuesService.bonjourType)
            }
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
            startWatchdog()
        } catch {
            status.connected = false
            status.detail = "Cannot listen: \(error.localizedDescription)"
            onStatusChange?(status)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.heartbeatTimer?.cancel(); self.heartbeatTimer = nil
            self.watchdog?.cancel(); self.watchdog = nil
            for (_, c) in self.connections { c.cancel() }
            self.connections.removeAll()
            self.activeConnection = nil
            self.listener?.cancel()
            self.listener = nil
            self.clockOffset = nil
            self.status.connected = false
            self.status.rateHz = 0
            self.status.latencyMs = nil
            self.status.detail = "Stopped"
            self.onStatusChange?(self.status)
        }
    }

    // MARK: - Listener

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            let port = listener?.port?.rawValue
            status.detail = port.map { "Waiting for iPhone on port \($0)" } ?? "Waiting for iPhone"
            onStatusChange?(status)
            if let port { readyHandler?(port); readyHandler = nil }
        case .failed(let error):
            status.connected = false
            status.detail = "Listener failed: \(error.localizedDescription)"
            onStatusChange?(status)
            // NWListener does not recover on its own; rebuild shortly.
            listener?.cancel()
            listener = nil
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startLocked() }
        case .waiting(let error):
            status.detail = "Waiting: \(error.localizedDescription)"
            onStatusChange?(status)
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.activeConnection = connection
                self.status.connected = true
                self.status.detail = Self.describe(connection.endpoint)
                self.onStatusChange?(self.status)
                self.startHeartbeat()
            case .failed, .cancelled:
                self.connections[id] = nil
                if self.activeConnection === connection {
                    self.activeConnection = self.connections.values.first
                }
                if self.connections.isEmpty {
                    self.status.connected = false
                    self.status.rateHz = 0
                    self.status.latencyMs = nil
                    self.status.detail = "iPhone disconnected"
                    self.onStatusChange?(self.status)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        // One datagram per read; `maximumLength` just needs to exceed a packet.
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.ingest(data, from: connection) }
            if error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection)
        }
    }

    private func ingest(_ data: Data, from connection: NWConnection) {
        guard let frame = MotionFrameCodec.decode(data) else { return }

        // Drop reordered stragglers; freshness beats completeness here.
        if frame.seq <= lastSeq && lastSeq &- frame.seq < 1000 { return }
        lastSeq = frame.seq

        let now = hostUptime()
        lastFrameAt = now
        activeConnection = connection

        // Transport jitter relative to the best-case packet. See `clockOffset`.
        let observed = now - frame.senderTime
        let floor = min(observed, (clockOffset ?? observed) + 2e-5)
        clockOffset = floor
        status.latencyMs = max(0, (observed - floor) * 1000)

        onFrame?(frame)

        if meter.record(seq: frame.seq, now: now) {
            status.rateHz = meter.rateHz
            status.dropped = meter.dropped
            onStatusChange?(status)
        }
    }

    // MARK: - Heartbeat and watchdog

    private func startHeartbeat() {
        guard heartbeatTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + MotionCuesService.heartbeatInterval,
                       repeating: MotionCuesService.heartbeatInterval,
                       leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, let connection = self.activeConnection else { return }
            let packet = HeartbeatPacket(ackSeq: self.lastSeq, receiverTime: hostUptime())
            connection.send(content: packet.encoded(), completion: .idempotent)
        }
        heartbeatTimer = timer
        timer.resume()
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self, self.status.connected else { return }
            if hostUptime() - self.lastFrameAt > 2.0 {
                self.status.connected = false
                self.status.rateHz = 0
                self.status.latencyMs = nil
                self.status.detail = "No data from iPhone"
                self.onStatusChange?(self.status)
            }
        }
        watchdog = timer
        timer.resume()
    }

    private static func describe(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, _): "Connected to \(host)"
        case .service(let name, _, _, _): "Connected to \(name)"
        default: "Connected"
        }
    }
}
