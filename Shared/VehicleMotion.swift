//
//  VehicleMotion.swift
//
//  The engine's output: acceleration already resolved into the *vehicle*
//  frame and already filtered. This is the only thing the renderer sees.
//

import Foundation

/// Vehicle frame is right-handed:
///   +x = forward (direction of travel)
///   +y = left
///   +z = up
public struct VehicleMotion: Sendable, Equatable {
    /// Longitudinal acceleration, g. Positive = speeding up.
    public var forward: Double
    /// Lateral acceleration, g. Positive = accelerating to the left
    /// (i.e. the car is turning left).
    public var lateral: Double
    /// Vertical acceleration, g. Positive = up (bump / crest).
    public var vertical: Double
    /// Yaw rate about the vertical axis, rad/s. Positive = turning left.
    public var yawRate: Double
    /// Host uptime, seconds, at which this state was computed.
    public var timestamp: Double

    public static let zero = VehicleMotion(forward: 0, lateral: 0, vertical: 0, yawRate: 0, timestamp: 0)

    public init(forward: Double, lateral: Double, vertical: Double, yawRate: Double, timestamp: Double) {
        self.forward = forward
        self.lateral = lateral
        self.vertical = vertical
        self.yawRate = yawRate
        self.timestamp = timestamp
    }

    /// Rough "how much is going on" scalar, used for idle detection and for
    /// modulating dot emphasis.
    public var magnitude: Double {
        (forward * forward + lateral * lateral + vertical * vertical).squareRoot()
    }
}

/// Health/telemetry for the menu bar. Cheap to copy, published at ~2 Hz.
public struct MotionLinkStatus: Sendable, Equatable {
    public enum Source: String, Sendable {
        case none = "None"
        case simulator = "Simulator"
        case headphones = "AirPods"
        case iPhone = "iPhone"
    }

    public var source: Source = .none
    public var connected: Bool = false
    /// Measured sample rate, Hz.
    public var rateHz: Double = 0
    /// Transport jitter in milliseconds: how late this packet was compared to
    /// the best-case packet observed so far. Absolute one-way latency is not
    /// measurable across two unsynchronised uptime clocks, and jitter is the
    /// part that actually causes visible stutter anyway.
    public var latencyMs: Double?
    /// Packets dropped since start (gaps in the sequence numbers).
    public var dropped: Int = 0
    /// Human-readable detail, e.g. peer name or error.
    public var detail: String = ""
    /// What the sender thinks about whether you are in a moving vehicle.
    /// `nil` when the sender does not detect that.
    public var isDriving: Bool?

    public init() {}
}
