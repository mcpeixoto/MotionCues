//
//  MotionCuesProtocol.swift
//  Shared between the macOS app and the iOS companion.
//
//  Wire format for the local-network sensor link. Deliberately tiny and
//  fixed-size: no JSON, no reflection, no allocation churn on the hot path.
//

import Foundation
import simd

public enum MotionCuesService {
    /// Bonjour service type advertised by the Mac (the receiver).
    public static let bonjourType = "_mcues._udp"
    /// Bump when the wire format changes incompatibly.
    public static let protocolVersion: UInt16 = 1
    /// ASCII "MCU1"
    public static let magic: UInt32 = 0x4D43_5531
    /// Sensor rate requested from Core Motion on the phone.
    public static let sensorRateHz: Double = 100
    /// Heartbeat the Mac sends back so the phone can detect a dead peer.
    public static let heartbeatInterval: TimeInterval = 1.0
    /// Phone declares the link dead after this long without a heartbeat.
    public static let peerTimeout: TimeInterval = 3.0
}

public enum PacketKind: UInt8 {
    case motion = 1
    case heartbeat = 2
}

// MARK: - Motion frame

/// One fused motion sample, expressed in the *device* frame of whatever
/// sensor produced it. All frame-of-reference work happens on the Mac so the
/// phone stays a dumb, cheap sensor bridge.
public struct MotionFrame: Sendable, Equatable {
    /// Monotonically increasing sequence number from the sender.
    public var seq: UInt32
    /// Sender-local timebase, seconds (`CMLogItem.timestamp`, i.e. uptime).
    public var senderTime: Double
    /// Attitude quaternion reported by Core Motion (x, y, z, w).
    /// The rotation *convention* is resolved empirically on the Mac — see
    /// `ReferenceFrameResolver`.
    public var quaternion: SIMD4<Double>
    /// Gravity-removed acceleration in the device frame, in g.
    public var userAcceleration: SIMD3<Double>
    /// Rotation rate in the device frame, rad/s.
    public var rotationRate: SIMD3<Double>
    /// Gravity vector in the device frame, in g.
    public var gravity: SIMD3<Double>
    /// Ground speed in m/s if the sender has a usable GPS fix, else `nil`.
    public var speed: Double?

    public init(seq: UInt32,
                senderTime: Double,
                quaternion: SIMD4<Double>,
                userAcceleration: SIMD3<Double>,
                rotationRate: SIMD3<Double>,
                gravity: SIMD3<Double>,
                speed: Double? = nil) {
        self.seq = seq
        self.senderTime = senderTime
        self.quaternion = quaternion
        self.userAcceleration = userAcceleration
        self.rotationRate = rotationRate
        self.gravity = gravity
        self.speed = speed
    }
}

// MARK: - Byte writer / reader

private struct ByteWriter {
    private(set) var bytes: [UInt8]
    private var offset = 0

    init(count: Int) { bytes = [UInt8](repeating: 0, count: count) }

    mutating func u8(_ v: UInt8) { bytes[offset] = v; offset += 1 }
    mutating func u16(_ v: UInt16) { raw(v.littleEndian, 2) }
    mutating func u32(_ v: UInt32) { raw(v.littleEndian, 4) }
    mutating func f32(_ v: Double) { raw(Float(v).bitPattern.littleEndian, 4) }
    mutating func f64(_ v: Double) { raw(v.bitPattern.littleEndian, 8) }

    private mutating func raw<T>(_ value: T, _ count: Int) {
        withUnsafeBytes(of: value) { src in
            for i in 0..<count { bytes[offset + i] = src[i] }
        }
        offset += count
    }
}

private struct ByteReader {
    private let bytes: [UInt8]
    private var offset = 0

    /// Copies once up front so every subsequent field read is a plain
    /// unaligned load out of contiguous storage.
    init(_ data: Data) { bytes = [UInt8](data) }

    var count: Int { bytes.count }

    mutating func u8() -> UInt8 { defer { offset += 1 }; return bytes[offset] }
    mutating func u16() -> UInt16 { UInt16(littleEndian: load()) }
    mutating func u32() -> UInt32 { UInt32(littleEndian: load()) }
    mutating func f32() -> Double { Double(Float(bitPattern: UInt32(littleEndian: load()))) }
    mutating func f64() -> Double { Double(bitPattern: UInt64(littleEndian: load())) }

    private mutating func load<T>() -> T {
        let start = offset
        offset += MemoryLayout<T>.size
        return bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: start, as: T.self) }
    }
}

// MARK: - Encoding

/// Byte layout, little-endian, 76 bytes total:
///
///     0  u32  magic
///     4  u16  version
///     6  u8   kind
///     7  u8   flags   (bit0: speed valid)
///     8  u32  seq
///    12  f64  senderTime
///    20  f32  quaternion x,y,z,w
///    36  f32  userAcceleration x,y,z
///    48  f32  rotationRate x,y,z
///    60  f32  gravity x,y,z
///    72  f32  speed (m/s, ignore if flag clear)
public enum MotionFrameCodec {
    public static let byteCount = 76
    private static let flagSpeedValid: UInt8 = 1 << 0

    public static func encode(_ frame: MotionFrame) -> Data {
        var w = ByteWriter(count: byteCount)
        w.u32(MotionCuesService.magic)
        w.u16(MotionCuesService.protocolVersion)
        w.u8(PacketKind.motion.rawValue)
        w.u8(frame.speed == nil ? 0 : flagSpeedValid)
        w.u32(frame.seq)
        w.f64(frame.senderTime)
        w.f32(frame.quaternion.x); w.f32(frame.quaternion.y)
        w.f32(frame.quaternion.z); w.f32(frame.quaternion.w)
        w.f32(frame.userAcceleration.x); w.f32(frame.userAcceleration.y); w.f32(frame.userAcceleration.z)
        w.f32(frame.rotationRate.x); w.f32(frame.rotationRate.y); w.f32(frame.rotationRate.z)
        w.f32(frame.gravity.x); w.f32(frame.gravity.y); w.f32(frame.gravity.z)
        w.f32(frame.speed ?? 0)
        return Data(w.bytes)
    }

    public static func decode(_ data: Data) -> MotionFrame? {
        guard data.count >= byteCount else { return nil }
        var r = ByteReader(data)
        guard r.u32() == MotionCuesService.magic,
              r.u16() == MotionCuesService.protocolVersion,
              r.u8() == PacketKind.motion.rawValue else { return nil }
        let flags = r.u8()
        let seq = r.u32()
        let time = r.f64()
        let q = SIMD4<Double>(r.f32(), r.f32(), r.f32(), r.f32())
        let ua = SIMD3<Double>(r.f32(), r.f32(), r.f32())
        let rr = SIMD3<Double>(r.f32(), r.f32(), r.f32())
        let g = SIMD3<Double>(r.f32(), r.f32(), r.f32())
        let rawSpeed = r.f32()
        let speed = (flags & flagSpeedValid) != 0 ? rawSpeed : nil
        return MotionFrame(seq: seq, senderTime: time, quaternion: q,
                           userAcceleration: ua, rotationRate: rr,
                           gravity: g, speed: speed)
    }

    /// Peek at the packet kind without a full decode.
    public static func kind(of data: Data) -> PacketKind? {
        guard data.count >= 8 else { return nil }
        var r = ByteReader(data)
        guard r.u32() == MotionCuesService.magic else { return nil }
        _ = r.u16()
        return PacketKind(rawValue: r.u8())
    }
}

// MARK: - Heartbeat

/// 20 bytes: header (8) + ackSeq (4) + receiverTime f64 (8).
/// Sent Mac → phone so the phone can tell a live peer from a dead one.
public struct HeartbeatPacket: Sendable, Equatable {
    public var ackSeq: UInt32
    public var receiverTime: Double

    public init(ackSeq: UInt32, receiverTime: Double) {
        self.ackSeq = ackSeq
        self.receiverTime = receiverTime
    }

    public static let byteCount = 20

    public func encoded() -> Data {
        var w = ByteWriter(count: Self.byteCount)
        w.u32(MotionCuesService.magic)
        w.u16(MotionCuesService.protocolVersion)
        w.u8(PacketKind.heartbeat.rawValue)
        w.u8(0)
        w.u32(ackSeq)
        w.f64(receiverTime)
        return Data(w.bytes)
    }

    public static func decode(_ data: Data) -> HeartbeatPacket? {
        guard data.count >= byteCount else { return nil }
        var r = ByteReader(data)
        guard r.u32() == MotionCuesService.magic,
              r.u16() == MotionCuesService.protocolVersion,
              r.u8() == PacketKind.heartbeat.rawValue else { return nil }
        _ = r.u8()
        return HeartbeatPacket(ackSeq: r.u32(), receiverTime: r.f64())
    }
}
