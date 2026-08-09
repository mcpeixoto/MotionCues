//
//  MotionProvider.swift
//
//  Everything that can produce raw motion samples hides behind this. The
//  engine never knows whether the numbers came from a phone on the passenger
//  seat, from AirPods, or from a synthetic drive.
//

import Foundation

enum MotionSourceKind: String, CaseIterable, Codable, Sendable {
    case automatic
    case mac        // AirPods head motion — the only IMU a Mac can reach
    case iPhone
    case simulator

    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .mac: "Mac (AirPods)"
        case .iPhone: "iPhone"
        case .simulator: "Simulator"
        }
    }
}

/// Callbacks are delivered on an arbitrary background queue, at sensor rate.
/// Implementations must not touch the main actor from them.
///
/// Note there is deliberately no `status` property to read. Every provider
/// maintains its status on its own queue, so a synchronous getter would be a
/// cross-thread read of a mutating struct. Consumers take the snapshot handed
/// to `onStatusChange` instead, which is a value copy made on the queue that
/// owns it.
protocol MotionProvider: AnyObject {
    var kind: MotionSourceKind { get }

    /// Called at sensor rate on a background queue.
    var onFrame: ((MotionFrame) -> Void)? { get set }
    /// Called when connection state / rate / errors change. Background queue.
    var onStatusChange: ((MotionLinkStatus) -> Void)? { get set }

    func start()
    func stop()
}

/// Shared bookkeeping every provider needs: measured rate, dropped packets.
struct RateMeter {
    private var windowStart: Double = 0
    private var countInWindow = 0
    private(set) var rateHz: Double = 0
    private var lastSeq: UInt32?
    private(set) var dropped = 0

    mutating func reset() {
        windowStart = 0
        countInWindow = 0
        rateHz = 0
        lastSeq = nil
        dropped = 0
    }

    /// - Returns: true when the published rate changed enough to be worth
    ///   pushing to the UI.
    mutating func record(seq: UInt32?, now: Double) -> Bool {
        if let seq, let last = lastSeq, seq > last &+ 1 {
            dropped += Int(seq &- last) - 1
        }
        if let seq { lastSeq = seq }

        countInWindow += 1
        if windowStart == 0 { windowStart = now; return false }
        let elapsed = now - windowStart
        guard elapsed >= 0.5 else { return false }
        rateHz = Double(countInWindow) / elapsed
        countInWindow = 0
        windowStart = now
        return true
    }
}

/// Host uptime in seconds — monotonic, unaffected by wall-clock changes, and
/// the same timebase Core Motion stamps its samples with.
@inline(__always)
func hostUptime() -> Double {
    ProcessInfo.processInfo.systemUptime
}
