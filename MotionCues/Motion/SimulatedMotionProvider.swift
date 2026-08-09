//
//  SimulatedMotionProvider.swift
//
//  A synthetic drive so the whole pipeline — calibration included — can be
//  exercised at a desk. It emits genuine device-frame samples (with a
//  deliberately misaligned "phone" orientation and a plausible amount of road
//  vibration), not pre-baked screen offsets, so what you see here is what the
//  real path will do.
//

import Foundation
import simd

final class SimulatedMotionProvider: MotionProvider {
    let kind: MotionSourceKind = .simulator

    var onFrame: ((MotionFrame) -> Void)?
    var onStatusChange: ((MotionLinkStatus) -> Void)?
    /// Owned by `queue`; published to consumers via `onStatusChange`.
    private var status = MotionLinkStatus()

    /// Deliberate misalignment of the fake sensor relative to the fake car,
    /// so the calibration step has real work to do.
    var deviceYawOffset: Double = 0.9   // rad
    var devicePitch: Double = 0.35      // rad, phone propped in a cradle
    var vibration: Double = 0.02        // g RMS of road noise

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.motioncues.simulator", qos: .userInteractive)
    private var seq: UInt32 = 0
    private var t: Double = 0
    private var meter = RateMeter()
    private var noiseState = SIMD3<Double>.zero
    private var rng = SplitMix64(seed: 0x5EED_1234_ABCD_0001)

    private let interval = 1.0 / MotionCuesService.sensorRateHz

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.t = 0
            self.seq = 0
            self.meter.reset()

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: self.interval, leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer

            self.status.source = .simulator
            self.status.connected = true
            self.status.detail = "Synthetic drive"
            self.onStatusChange?(self.status)
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.status.connected = false
            self.status.rateHz = 0
            self.onStatusChange?(self.status)
        }
    }

    // MARK: - Scripted drive

    /// Longitudinal and lateral acceleration of the imaginary car, in g,
    /// plus the yaw rate that must be consistent with them.
    private func drive(at time: Double) -> (forward: Double, yawRate: Double, speed: Double) {
        // A 60-second loop: pull away, cruise, sweeping left bend, brake,
        // roundabout, hard acceleration, gentle stop.
        let phase = time.truncatingRemainder(dividingBy: 60)
        var forward = 0.0
        var yawRate = 0.0

        switch phase {
        case 0..<5:    forward = 0.18 * smoothPulse(phase / 5)           // pulling away
        case 5..<12:   forward = 0.01 * sin(phase * 0.9)                 // cruising
        case 12..<20:  yawRate = 0.22 * smoothPulse((phase - 12) / 8)    // long left bend
                       forward = -0.02
        case 20..<25:  forward = -0.26 * smoothPulse((phase - 20) / 5)   // braking
        case 25..<34:  yawRate = -0.55 * smoothPulse((phase - 25) / 9)   // roundabout, right
                       forward = -0.03
        case 34..<41:  forward = 0.30 * smoothPulse((phase - 34) / 7)    // hard acceleration
        case 41..<47:  yawRate = 0.35 * sin((phase - 41) * 1.05)         // S bends
        case 47..<53:  forward = -0.20 * smoothPulse((phase - 47) / 6)   // slowing
        default:       forward = 0.02 * sin(phase * 0.4)
        }

        // Speed integrated crudely, clamped to something sane.
        speedState = max(2, min(30, speedState + forward * 9.80665 * interval - 0.02 * interval))

        // Cap the yaw rate so lateral acceleration stays inside what a road
        // car actually pulls (~0.35 g). Without this, a roundabout-rate yaw at
        // motorway speed would synthesise 2 g and peg the visual clamp — the
        // simulator has to stay inside the envelope it is standing in for.
        let maxYaw = (0.35 * 9.80665) / max(speedState, 1)
        yawRate = max(-maxYaw, min(maxYaw, yawRate))

        return (forward, yawRate, speedState)
    }

    private var speedState: Double = 8

    private func smoothPulse(_ x: Double) -> Double {
        // Smooth 0→1→0 bump, C1 continuous, so nothing ever steps.
        let c = max(0, min(1, x))
        return sin(.pi * c)
    }

    /// Advance the synthetic drive by exactly one sample, synchronously.
    ///
    /// The normal path is a `DispatchSourceTimer`, which is right for the app
    /// and wrong for anything that needs frame-exact, reproducible output. The
    /// offline demo renderer in `Tools/DemoRenderer` drives the simulator
    /// through this instead, so the generated asset is identical on every run.
    func step() {
        tick()
    }

    private func tick() {
        t += interval
        let d = drive(at: t)

        // Lateral acceleration consistent with the yaw rate: a = v * omega.
        let lateralG = (d.speed * d.yawRate) / 9.80665
        // A little vertical road input.
        let verticalG = 0.015 * sin(t * 6.1) + 0.008 * sin(t * 13.7)

        // Vehicle frame: +x forward, +y left, +z up.
        var accelVehicle = SIMD3<Double>(d.forward, lateralG, verticalG)

        // Correlated road vibration (an OU process, not white noise — real
        // vibration is band-limited, and this is what the filters must reject).
        noiseState = noiseState * 0.75 + SIMD3<Double>(rng.gaussian(), rng.gaussian(), rng.gaussian()) * vibration
        accelVehicle += noiseState

        // Rotate vehicle → sensor reference frame (yaw only; the "car" is level).
        let yaw = deviceYawOffset
        let refToVehicle = simd_double3x3(rows: [
            SIMD3<Double>( cos(yaw), sin(yaw), 0),
            SIMD3<Double>(-sin(yaw), cos(yaw), 0),
            SIMD3<Double>( 0,        0,        1)
        ])
        let vehicleToRef = refToVehicle.transpose
        let accelRef = vehicleToRef * accelVehicle
        let omegaRef = SIMD3<Double>(0, 0, d.yawRate)

        // The phone sits pitched back in a cradle. `deviceToRef` maps a
        // device-frame vector into the reference frame, which is exactly the
        // attitude quaternion we put on the wire.
        let deviceToRef = simd_quatd(angle: devicePitch, axis: SIMD3<Double>(1, 0, 0))
        let refToDevice = simd_matrix3x3(deviceToRef).transpose
        let accelDevice = refToDevice * accelRef
        let omegaDevice = refToDevice * omegaRef
        let gravityDevice = refToDevice * SIMD3<Double>(0, 0, -1)
        let q = deviceToRef

        seq &+= 1
        let now = hostUptime()
        let frame = MotionFrame(seq: seq,
                                senderTime: now,
                                quaternion: SIMD4<Double>(q.imag.x, q.imag.y, q.imag.z, q.real),
                                userAcceleration: accelDevice,
                                rotationRate: omegaDevice,
                                gravity: gravityDevice,
                                speed: d.speed)
        onFrame?(frame)

        if meter.record(seq: seq, now: now) {
            status.rateHz = meter.rateHz
            status.dropped = meter.dropped
            status.latencyMs = 0
            onStatusChange?(status)
        }
    }
}

// MARK: - Deterministic noise

/// Small, fast, reproducible PRNG. Deterministic so the simulator behaves the
/// same on every run, which makes tuning the filters possible.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Box–Muller, one value at a time (the discarded half is cheap enough).
    mutating func gaussian() -> Double {
        let u1 = max(uniform(), 1e-12)
        let u2 = uniform()
        return (-2 * Foundation.log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
