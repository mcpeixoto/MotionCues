//
//  MotionSender.swift
//
//  Phone side of the link: find the Mac, connect, stream, and never stop
//  trying to come back.
//
//  Discovery is `NWBrowser` over Bonjour with `includePeerToPeer = true`.
//  That single flag is what makes this work in a car: with no Wi-Fi network
//  present, Network.framework will use peer-to-peer Wi-Fi (AWDL) for both the
//  discovery and the data path. If you happen to be on a shared Wi-Fi network,
//  or on the phone's own hotspot with the Mac joined, the ordinary
//  infrastructure path is used instead — same code either way.
//
//  Bandwidth: 76 bytes per sample at 100 Hz is 7.6 kB/s. Nothing.
//
//  Reconnection strategy:
//    * The browser stays up for the whole session, so a Mac that comes back is
//      re-discovered without any polling.
//    * UDP gives no delivery feedback, so liveness comes from the Mac's 1 Hz
//      heartbeat. Three seconds of silence and we tear the connection down and
//      take the next endpoint the browser offers.
//    * Backoff caps at two seconds. This needs to recover fast, not politely.
//
//  Threading: all networking lives on `queue`, inside `LinkCore`. The Core
//  Motion callback calls straight into it with no actor hop — a main-actor
//  round trip per sample would add scheduling latency to every single frame
//  for no benefit. `MotionSender` is the thin main-actor mirror the UI binds
//  to, updated at human speed.
//

import Foundation
import Network
import Combine

// MARK: - Observable façade

@MainActor
final class MotionSender: ObservableObject {
    enum LinkState: Equatable {
        case idle
        case searching
        case connecting(String)
        case streaming(String)
        case failed(String)

        var isStreaming: Bool { if case .streaming = self { return true }; return false }

        var description: String {
            switch self {
            case .idle: "Stopped"
            case .searching: "Looking for a Mac…"
            case .connecting(let name): "Connecting to \(name)…"
            case .streaming(let name): "Streaming to \(name)"
            case .failed(let reason): "Problem: \(reason)"
            }
        }
    }

    @Published private(set) var state: LinkState = .idle
    @Published private(set) var discovered: [String] = []
    @Published private(set) var packetsSent: Int = 0
    @Published private(set) var dropped: Int = 0

    /// Sticky preference so a phone that can see two Macs keeps using the same
    /// one across reconnects.
    @Published var preferredPeer: String? {
        didSet { core.setPreferredPeer(preferredPeer) }
    }

    private let core = LinkCore()

    init() {
        core.onState = { [weak self] state in
            Task { @MainActor in self?.state = state }
        }
        core.onDiscovered = { [weak self] names in
            Task { @MainActor in self?.discovered = names }
        }
        core.onCounters = { [weak self] sent, dropped in
            Task { @MainActor in
                self?.packetsSent = sent
                self?.dropped = dropped
            }
        }
    }

    func start() { core.start() }
    func stop() { core.stop() }

    /// Called on the Core Motion queue at sensor rate.
    nonisolated func send(_ frame: MotionFrame) { core.send(frame) }
}

// MARK: - Networking core

/// Everything network-related, confined to one serial queue.
final class LinkCore: @unchecked Sendable {
    typealias LinkState = MotionSender.LinkState

    var onState: ((LinkState) -> Void)?
    var onDiscovered: (([String]) -> Void)?
    var onCounters: ((Int, Int) -> Void)?

    private let queue = DispatchQueue(label: "com.motioncues.ios.net", qos: .userInteractive)
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var endpoints: [NWEndpoint] = []
    private var preferredPeer: String?
    private var running = false
    private var streaming = false
    private var lastHeartbeat: Double = 0
    private var watchdog: DispatchSourceTimer?
    private var retryDelay: TimeInterval = 0.25
    private var sendsInFlight = 0
    private var sent = 0
    private var dropped = 0
    private var lastCounterPush: Double = 0

    /// Backpressure guard: if the radio stalls, drop new samples rather than
    /// queue a backlog that would arrive stale anyway. Freshness > completeness.
    private let maxSendsInFlight = 8

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            retryDelay = 0.25
            publish(.searching)
            startBrowser()
            startWatchdog()
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            streaming = false
            watchdog?.cancel(); watchdog = nil
            browser?.cancel(); browser = nil
            connection?.cancel(); connection = nil
            endpoints = []
            onDiscovered?([])
            publish(.idle)
        }
    }

    func setPreferredPeer(_ name: String?) {
        queue.async { [self] in
            preferredPeer = name
            // Switch immediately if a different Mac was picked.
            if streaming, let name, currentName != name {
                connection?.cancel()
                connection = nil
                streaming = false
                connect()
            }
        }
    }

    /// Hot path. Encoding happens on the caller's (Core Motion) thread; only
    /// the send itself is serialised onto `queue`.
    func send(_ frame: MotionFrame) {
        let data = MotionFrameCodec.encode(frame)
        queue.async { [self] in
            guard streaming, let connection, sendsInFlight < maxSendsInFlight else {
                if streaming { dropped += 1 }
                return
            }
            sendsInFlight += 1
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    self.sendsInFlight -= 1
                    if let error {
                        self.drop(reason: error.localizedDescription)
                    } else {
                        self.sent += 1
                        self.pushCountersIfDue()
                    }
                }
            })
        }
    }

    // MARK: - Discovery

    private func startBrowser() {
        let params = NWParameters.udp
        params.includePeerToPeer = true

        let browser = NWBrowser(for: .bonjour(type: MotionCuesService.bonjourType, domain: nil),
                                using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.queue.async { self.handle(results: results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                if case .failed(let error) = state {
                    self.publish(.failed(error.localizedDescription))
                    self.browser?.cancel()
                    self.browser = nil
                    self.retry { self.startBrowser() }
                }
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    private func handle(results: Set<NWBrowser.Result>) {
        endpoints = results.map(\.endpoint)
        onDiscovered?(endpoints.map(Self.name(of:)).sorted())
        if connection == nil, running { connect() }
    }

    private var currentName = ""

    private func connect() {
        guard running, connection == nil else { return }

        let chosen: NWEndpoint?
        if let preferredPeer, let match = endpoints.first(where: { Self.name(of: $0) == preferredPeer }) {
            chosen = match
        } else {
            chosen = endpoints.first
        }
        guard let endpoint = chosen else {
            publish(.searching)
            return
        }

        let name = Self.name(of: endpoint)
        currentName = name
        publish(.connecting(name))

        let params = NWParameters.udp
        params.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: params)

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                guard self.connection === connection else { return }
                switch state {
                case .ready:
                    self.retryDelay = 0.25
                    self.lastHeartbeat = hostUptime()
                    self.streaming = true
                    self.publish(.streaming(name))
                    self.receive(on: connection)
                case .failed(let error):
                    self.drop(reason: error.localizedDescription)
                case .waiting(let error):
                    self.publish(.connecting("\(name) — \(error.localizedDescription)"))
                default:
                    break
                }
            }
        }
        self.connection = connection
        connection.start(queue: queue)
    }

    private func drop(reason: String) {
        connection?.cancel()
        connection = nil
        streaming = false
        sendsInFlight = 0
        guard running else { return }
        publish(.failed(reason))
        retry { self.connect() }
    }

    private func retry(_ work: @escaping () -> Void) {
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 2.0)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running else { return }
            work()
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            self.queue.async {
                guard self.connection === connection else { return }
                if let data, HeartbeatPacket.decode(data) != nil {
                    self.lastHeartbeat = hostUptime()
                }
                if error == nil, self.running {
                    self.receive(on: connection)
                }
            }
        }
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self, self.running, self.streaming else { return }
            if hostUptime() - self.lastHeartbeat > MotionCuesService.peerTimeout {
                self.drop(reason: "Mac stopped responding")
            }
        }
        watchdog = timer
        timer.resume()
    }

    // MARK: - Plumbing

    private func publish(_ state: LinkState) { onState?(state) }

    private func pushCountersIfDue() {
        let now = hostUptime()
        guard now - lastCounterPush > 0.5 else { return }
        lastCounterPush = now
        onCounters?(sent, dropped)
    }

    private static func name(of endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .service(let name, _, _, _): name
        case .hostPort(let host, let port): "\(host):\(port.rawValue)"
        default: "\(endpoint)"
        }
    }
}

/// Same monotonic clock the Mac uses.
func hostUptime() -> Double {
    ProcessInfo.processInfo.systemUptime
}
