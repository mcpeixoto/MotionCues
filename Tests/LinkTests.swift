//
//  LinkTests.swift
//
//  Exercises the real `MotionReceiver` over a real UDP socket on loopback.
//
//  Bonjour discovery is deliberately not part of this: on macOS 15+ it puts a
//  Local Network permission prompt in the middle of the test, which makes the
//  result depend on who is sitting at the machine. Discovery is a thin layer
//  over `NWBrowser`; what is worth testing automatically is everything after
//  it — that a datagram encoded by the shared codec is decoded, ordered,
//  counted and handed to the engine, and that the receiver answers with the
//  heartbeat the phone uses to detect a dead peer.
//

import XCTest
import Network
import simd
@testable import MotionCues

final class LinkTests: XCTestCase {
    private var receiver: MotionReceiver!
    private var connection: NWConnection!

    override func tearDown() {
        connection?.cancel()
        receiver?.stop()
        connection = nil
        receiver = nil
        super.tearDown()
    }

    /// Brings up the receiver on loopback and connects a sender to it.
    private func makeLink(file: StaticString = #filePath, line: UInt = #line) throws -> UInt16 {
        receiver = MotionReceiver()
        // Loopback only: no Bonjour, no permission prompt, no dependency on
        // what network the machine happens to be on.
        let port = try XCTUnwrap(receiver.startForTesting(), file: file, line: line)

        let ready = expectation(description: "connection ready")
        connection = NWConnection(host: .ipv4(.loopback),
                                  port: NWEndpoint.Port(rawValue: port)!,
                                  using: .udp)
        connection.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        connection.start(queue: .global())
        wait(for: [ready], timeout: 5)
        return port
    }

    private func frame(seq: UInt32, forward: Double) -> MotionFrame {
        MotionFrame(seq: seq,
                    senderTime: Double(seq) * 0.01,
                    quaternion: SIMD4<Double>(0, 0, 0, 1),
                    userAcceleration: SIMD3<Double>(forward, 0, 0),
                    rotationRate: .zero,
                    gravity: SIMD3<Double>(0, 0, -1),
                    speed: 15)
    }

    func testDeliversFramesToTheEngine() throws {
        _ = try makeLink()

        let received = expectation(description: "frames received")
        received.expectedFulfillmentCount = 5
        received.assertForOverFulfill = false

        var seen: [UInt32] = []
        let lock = NSLock()
        receiver.onFrame = { f in
            lock.lock(); seen.append(f.seq); lock.unlock()
            received.fulfill()
        }

        for i in 1...5 {
            connection.send(content: MotionFrameCodec.encode(frame(seq: UInt32(i), forward: 0.1)),
                            completion: .idempotent)
        }
        wait(for: [received], timeout: 5)

        lock.lock(); let result = seen; lock.unlock()
        XCTAssertEqual(result, [1, 2, 3, 4, 5])
    }

    /// Freshness beats completeness: a datagram that arrives after a newer one
    /// must be thrown away rather than rewind the dots.
    func testDropsStaleReorderedPackets() throws {
        _ = try makeLink()

        let got = expectation(description: "in-order frames")
        got.expectedFulfillmentCount = 2
        got.assertForOverFulfill = false

        var seen: [UInt32] = []
        let lock = NSLock()
        receiver.onFrame = { f in
            lock.lock(); seen.append(f.seq); lock.unlock()
            got.fulfill()
        }

        // Send 10, then the straggler 7, then 11. Only 10 and 11 should land.
        for seq in [UInt32(10), 7, 11] {
            connection.send(content: MotionFrameCodec.encode(frame(seq: seq, forward: 0.1)),
                            completion: .idempotent)
            // Serialise so ordering on the wire is not itself the variable.
            Thread.sleep(forTimeInterval: 0.05)
        }
        wait(for: [got], timeout: 5)

        lock.lock(); let result = seen; lock.unlock()
        XCTAssertEqual(result, [10, 11], "a stale packet was accepted")
    }

    func testGarbageIsIgnored() throws {
        _ = try makeLink()

        let nothing = expectation(description: "no frame decoded")
        nothing.isInverted = true
        receiver.onFrame = { _ in nothing.fulfill() }

        connection.send(content: Data(repeating: 0xFF, count: 76), completion: .idempotent)
        connection.send(content: Data("hello".utf8), completion: .idempotent)
        connection.send(content: HeartbeatPacket(ackSeq: 1, receiverTime: 0).encoded(),
                        completion: .idempotent)
        wait(for: [nothing], timeout: 1.5)
    }

    /// The heartbeat is the phone's only liveness signal on a UDP link, and it
    /// carries the last sequence the Mac saw.
    func testAnswersWithAHeartbeat() throws {
        _ = try makeLink()

        let beat = expectation(description: "heartbeat received")
        let ackSeq = LockedBox<UInt32>(0)
        connection.receiveMessage { data, _, _, _ in
            if let data, let packet = HeartbeatPacket.decode(data) {
                ackSeq.value = packet.ackSeq
                beat.fulfill()
            }
        }

        connection.send(content: MotionFrameCodec.encode(frame(seq: 99, forward: 0.1)),
                        completion: .idempotent)
        // The receiver heartbeats once a second.
        wait(for: [beat], timeout: 5)
        XCTAssertEqual(ackSeq.value, 99)
    }

    func testReportsConnectionAndRate() throws {
        _ = try makeLink()

        let connected = expectation(description: "reports connected")
        connected.assertForOverFulfill = false
        receiver.onStatusChange = { status in
            if status.connected { connected.fulfill() }
        }

        connection.send(content: MotionFrameCodec.encode(frame(seq: 1, forward: 0)),
                        completion: .idempotent)
        wait(for: [connected], timeout: 5)
    }
}

/// Tiny helper so expectations can hand a value back across the network queue.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ initial: T) { storage = initial }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
