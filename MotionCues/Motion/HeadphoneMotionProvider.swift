//
//  HeadphoneMotionProvider.swift
//
//  The ONLY inertial sensor a modern Mac can reach through a public API.
//
//  Verified against the macOS 26.5 SDK:
//    CMMotionManager             -> API_UNAVAILABLE(macos)
//    CMHeadphoneMotionManager    -> API_AVAILABLE(macos(14.0), ios(14.0), watchos(7.0))
//    CMBatchedSensorManager      -> API_UNAVAILABLE(macos)
//
//  So: no built-in accelerometer or gyroscope, ever. Apple Silicon Macs have
//  no IMU at all (there is no SMCMotionSensor / accelerometer node in the
//  IORegistry — that hardware was the hard-drive parking sensor and died with
//  spinning disks).
//
//  What we get instead is head motion from AirPods (Pro, Max, 3rd gen and
//  later — anything with the head-tracking IMU), at a fixed rate Core Motion
//  does not let us change, around 25 Hz. It is a genuinely inertial signal and
//  the car's acceleration does reach it, but it is superimposed on head
//  movement, which is large and fast. Treat this as the degraded fallback,
//  never the preferred source.
//
//  Mitigations applied here:
//    * heavier smoothing downstream (the engine widens its filter for this
//      source);
//    * a head-motion gate: while the head is clearly rotating, we stop
//      trusting the sample and hold the last one, because head yaw is
//      indistinguishable from a turn otherwise.
//

import Foundation
import CoreMotion
import simd

final class HeadphoneMotionProvider: NSObject, MotionProvider, CMHeadphoneMotionManagerDelegate {
    let kind: MotionSourceKind = .mac

    var onFrame: ((MotionFrame) -> Void)?
    var onStatusChange: ((MotionLinkStatus) -> Void)?
    /// Touched from the Core Motion queue and from start/stop; published to
    /// consumers via `onStatusChange` rather than read directly.
    private var status = MotionLinkStatus()

    private let manager = CMHeadphoneMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.motioncues.headphones"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()

    private var seq: UInt32 = 0
    private var meter = RateMeter()
    private var running = false

    /// rad/s. Above this the head is clearly moving and the sample is not
    /// telling us anything about the car.
    private let headMotionGate = 0.55

    static var isSupportedOnThisMac: Bool {
        CMHeadphoneMotionManager().isDeviceMotionAvailable
    }

    static var authorization: CMAuthorizationStatus {
        CMHeadphoneMotionManager.authorizationStatus()
    }

    override init() {
        super.init()
        manager.delegate = self
    }

    func start() {
        guard !running else { return }
        running = true
        seq = 0
        meter.reset()
        status.source = .headphones

        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .denied, .restricted:
            status.connected = false
            status.detail = "Motion access denied — enable it in System Settings › Privacy & Security › Motion & Fitness."
            onStatusChange?(status)
            return
        default:
            break
        }

        guard manager.isDeviceMotionAvailable else {
            status.connected = false
            status.detail = "No motion-capable headphones connected."
            onStatusChange?(status)
            return
        }

        manager.startConnectionStatusUpdates()
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, error in
            guard let self else { return }
            if let error {
                self.status.connected = false
                self.status.detail = error.localizedDescription
                self.onStatusChange?(self.status)
                return
            }
            guard let motion else { return }
            self.handle(motion)
        }

        status.detail = "Waiting for headphones…"
        onStatusChange?(status)
    }

    func stop() {
        guard running else { return }
        running = false
        manager.stopDeviceMotionUpdates()
        manager.stopConnectionStatusUpdates()
        status.connected = false
        status.rateHz = 0
        onStatusChange?(status)
    }

    private var lastGoodFrame: MotionFrame?

    private func handle(_ motion: CMDeviceMotion) {
        seq &+= 1
        let q = motion.attitude.quaternion
        let omega = SIMD3<Double>(motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z)

        var frame = MotionFrame(
            seq: seq,
            senderTime: motion.timestamp,
            quaternion: SIMD4<Double>(q.x, q.y, q.z, q.w),
            userAcceleration: SIMD3<Double>(motion.userAcceleration.x,
                                            motion.userAcceleration.y,
                                            motion.userAcceleration.z),
            rotationRate: omega,
            gravity: SIMD3<Double>(motion.gravity.x, motion.gravity.y, motion.gravity.z),
            speed: nil
        )

        // Head-motion gate: hold the previous sample rather than let a head
        // turn masquerade as the car turning.
        if simd_length(omega) > headMotionGate, var held = lastGoodFrame {
            held.seq = seq
            held.senderTime = motion.timestamp
            frame = held
        } else {
            lastGoodFrame = frame
        }

        if !status.connected {
            status.connected = true
            status.detail = "AirPods head motion (degraded source)"
            onStatusChange?(status)
        }
        onFrame?(frame)

        if meter.record(seq: seq, now: hostUptime()) {
            status.rateHz = meter.rateHz
            status.dropped = meter.dropped
            onStatusChange?(status)
        }
    }

    // MARK: - CMHeadphoneMotionManagerDelegate

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        status.connected = true
        status.detail = "AirPods head motion (degraded source)"
        onStatusChange?(status)
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        status.connected = false
        status.rateHz = 0
        status.detail = "Headphones disconnected."
        onStatusChange?(status)
    }
}
