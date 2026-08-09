//
//  MotionEngine.swift
//
//  The pipeline. Raw device-frame samples in, filtered vehicle-frame
//  acceleration out.
//
//      provider  →  reference frame  →  yaw calibration  →  vehicle frame
//                →  bias removal     →  One Euro         →  lateral fusion
//                →  MotionStateBox   →  (read at vsync by the renderer)
//
//  Threading: everything up to `MotionStateBox` runs on the provider's own
//  queue at sensor rate. Nothing here touches the main actor, and the renderer
//  never blocks on it — the box is a single lock-protected struct copy.
//

import Foundation
import simd

/// Lock-protected latest-value slot. The sensor thread writes at up to 100 Hz,
/// the display link reads at 60/120 Hz; neither ever waits on the other for
/// more than the few nanoseconds it takes to copy a small struct. This is why
/// SwiftUI is not in the loop: no observation, no diffing, no invalidation.
final class MotionStateBox: @unchecked Sendable {
    private var value = VehicleMotion.zero
    private let lock = NSLock()

    func store(_ motion: VehicleMotion) {
        lock.lock(); value = motion; lock.unlock()
    }

    func load() -> VehicleMotion {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

final class MotionEngine {
    let state = MotionStateBox()

    /// Called on the sensor queue, roughly twice a second, with calibration
    /// progress. Marshal to the main actor yourself.
    var onCalibrationUpdate: ((CalibrationQuality) -> Void)?

    private(set) var calibration = CalibrationState()

    private var resolver = ReferenceFrameResolver()
    private let yawEstimator = YawEstimator()

    private var forwardFilter = OneEuroFilter()
    private var lateralFilter = OneEuroFilter()
    private var verticalFilter = OneEuroFilter()
    private var yawRateFilter = OneEuroFilter(minCutoff: 0.8, beta: 0.3)

    private var forwardBias = BiasTracker()
    private var lateralBias = BiasTracker()
    private var verticalBias = BiasTracker()

    private var lateralFusion = LateralFusion()

    private var lastSenderTime: Double?
    /// Both of these are driven off the *sample* timebase rather than the wall
    /// clock, so calibration behaves identically whether samples arrive in real
    /// time or are replayed as fast as a test can push them.
    private var sinceCalibrationPush: Double = 0
    /// Seconds left in a guided-calibration session, or nil when none is running.
    private var calibrationRemaining: Double?

    // MARK: - Tuning

    /// Widened for AirPods: head motion is fast and large, so we trade lag for
    /// stability on that source.
    var sourceKind: MotionSourceKind = .simulator {
        didSet { applyTuning() }
    }

    var smoothing: Double = 0.5 {   // 0 = snappy, 1 = very smooth
        didSet { applyTuning() }
    }

    var sensitivity: Double = 0.5 { // 0 = sluggish response to fast changes
        didSet { applyTuning() }
    }

    init() { applyTuning() }

    private func applyTuning() {
        // Ranges chosen from the sweep documented on `OneEuroFilter.init`:
        // outside roughly minCutoff 0.2–0.5 / beta 2–6 you trade away either
        // stillness at rest or step response, with nothing gained.
        let base = 0.55 - 0.43 * max(0, min(1, smoothing))
        // AirPods: head movement is fast and large, so buy stability with lag
        // on that source specifically.
        let headphonePenalty = (sourceKind == .mac) ? 0.5 : 1.0
        let minCutoff = base * headphonePenalty

        // sensitivity maps to beta: how far the cutoff opens under fast change.
        let beta = (1.0 + 5.0 * max(0, min(1, sensitivity))) * headphonePenalty

        forwardFilter.minCutoff = minCutoff;  forwardFilter.beta = beta
        lateralFilter.minCutoff = minCutoff;  lateralFilter.beta = beta
        verticalFilter.minCutoff = minCutoff; verticalFilter.beta = beta
        // Yaw rate feeds the lateral fusion, where lag hurts more than noise.
        yawRateFilter.minCutoff = max(0.6, minCutoff * 2)
        yawRateFilter.beta = beta
    }

    // MARK: - Calibration control

    func loadCalibration(_ state: CalibrationState) {
        calibration = state
    }

    /// Start a guided calibration. Feed it ~20 s of normal driving that
    /// includes at least one bend.
    func beginCalibration(duration: TimeInterval = 25) {
        yawEstimator.reset()
        calibrationRemaining = duration
    }

    func cancelCalibration() {
        calibrationRemaining = nil
    }

    /// Reset everything that has memory, e.g. when switching source.
    func reset() {
        resolver.reset()
        yawEstimator.reset()
        forwardFilter.reset(); lateralFilter.reset(); verticalFilter.reset(); yawRateFilter.reset()
        forwardBias.reset(); lateralBias.reset(); verticalBias.reset()
        lateralFusion.reset()
        lastSenderTime = nil
        state.store(.zero)
    }

    // MARK: - Hot path

    func ingest(_ frame: MotionFrame) {
        let dt: Double
        if let last = lastSenderTime {
            let raw = frame.senderTime - last
            // Guard against a clock jump or a source swap mid-stream.
            dt = (raw > 0 && raw < 0.5) ? raw : 1.0 / MotionCuesService.sensorRateHz
        } else {
            dt = 1.0 / MotionCuesService.sensorRateHz
        }
        lastSenderTime = frame.senderTime

        resolver.observe(quaternion: frame.quaternion, gravity: frame.gravity)
        let rotation = resolver.rotation(quaternion: frame.quaternion, gravity: frame.gravity)

        // Device frame → Z-up reference frame.
        let accelRef = rotation * frame.userAcceleration
        let omegaRef = rotation * frame.rotationRate

        // Yaw rate about the true vertical. Positive = turning left.
        let yawRateRaw = omegaRef.z

        yawEstimator.add(ax: accelRef.x, ay: accelRef.y, yawRate: yawRateRaw)
        updateCalibrationIfNeeded(dt: dt)

        // Reference frame → vehicle frame (+x forward, +y left).
        let psi = calibration.effectiveYaw
        let c = cos(psi), s = sin(psi)
        let forwardRaw = accelRef.x * c + accelRef.y * s
        let lateralRaw = -accelRef.x * s + accelRef.y * c
        let verticalRaw = accelRef.z

        // Strip sustained offsets (road grade, residual tilt error).
        let forwardDC = forwardBias.remove(forwardRaw, dt: dt)
        let lateralDC = lateralBias.remove(lateralRaw, dt: dt)
        let verticalDC = verticalBias.remove(verticalRaw, dt: dt)

        // Adaptive smoothing.
        let yawRate = yawRateFilter.filter(yawRateRaw, dt: dt)
        let forward = forwardFilter.filter(forwardDC, dt: dt)
        var lateral = lateralFilter.filter(lateralDC, dt: dt)
        let vertical = verticalFilter.filter(verticalDC, dt: dt)

        // Roll compensation via v·ω, when the phone can tell us the speed.
        lateral = lateralFusion.fuse(measured: lateral, yawRate: yawRate, speed: frame.speed, dt: dt)

        state.store(VehicleMotion(forward: forward,
                                  lateral: lateral,
                                  vertical: vertical,
                                  yawRate: yawRate,
                                  timestamp: hostUptime()))
    }

    private func updateCalibrationIfNeeded(dt: Double) {
        if calibrationRemaining != nil { calibrationRemaining! -= dt }

        sinceCalibrationPush += dt
        guard sinceCalibrationPush > 0.5 else { return }
        sinceCalibrationPush = 0

        guard let quality = yawEstimator.estimate() else {
            if calibrationRemaining != nil {
                onCalibrationUpdate?(CalibrationQuality())
            }
            return
        }

        if let remaining = calibrationRemaining {
            // Guided session: snap straight to the estimate, and finish early
            // once it is clearly good enough.
            calibration.yaw = quality.yaw
            if quality.confidence > 0.6 && quality.lateralCoverage > 0.4 {
                calibration.isCalibrated = true
                calibrationRemaining = nil
            } else if remaining <= 0 {
                calibration.isCalibrated = quality.isUsable
                calibrationRemaining = nil
            }
            onCalibrationUpdate?(quality)
        } else if calibration.autoRefine && quality.isUsable {
            // Background refinement: slow blend, ~30 s time constant. This is
            // what absorbs the heading drift of `.xArbitraryZVertical`.
            let delta = YawEstimator.angleDelta(calibration.yaw, quality.yaw)
            calibration.yaw = YawEstimator.wrap(calibration.yaw + delta * 0.015 * quality.confidence)
            onCalibrationUpdate?(quality)
        }
    }
}
