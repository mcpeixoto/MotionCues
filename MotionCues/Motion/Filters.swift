//
//  Filters.swift
//
//  Signal conditioning for the cue pipeline.
//
//  Why these filters, and not others:
//
//  * We do NOT run a complementary or Kalman filter on raw accel+gyro.
//    `CMDeviceMotion` is already the output of Apple's own sensor-fusion
//    estimator: it hands us `gravity` and `userAcceleration` separated, plus a
//    drift-corrected attitude. Re-fusing raw sensors on top of that would be
//    strictly worse and would add latency.
//
//  * A fixed low-pass forces one global jitter-vs-lag compromise. We need dots
//    to be *dead still* at rest (so a stationary Mac shows nothing) yet track a
//    hard brake with minimal lag. Those two requirements conflict for any fixed
//    cutoff. The One Euro filter solves exactly this: cutoff adapts to the
//    signal's own rate of change — low cutoff when slow (max smoothing),
//    higher cutoff when fast (min lag).
//    Casiez, Roussel & Vogel, CHI 2012.
//
//  * On top of that we run a very slow bias tracker (tens of seconds). Road
//    grade, an imperfect calibration and gyro heading drift all leak a small
//    DC offset into the longitudinal channel; without removal the dots would
//    sit permanently off-centre on a long hill. Its time constant is chosen far
//    above the 0.05–1 Hz band real manoeuvres live in, so a genuine 6-second
//    acceleration still reads at full strength.
//
//  * The lateral channel additionally gets a complementary fusion with
//    v·ω_z when GPS speed is available — see `LateralFusion`. That one *is* a
//    complementary filter, and it is justified: measured lateral acceleration
//    is contaminated by body roll (gravity leaking into the horizontal plane),
//    while yaw rate is clean but needs speed to become an acceleration.
//

import Foundation

// MARK: - One Euro

/// Single-pole low-pass with an explicit, settable cutoff.
struct LowPass {
    private var value: Double = 0
    private(set) var hasValue = false

    mutating func reset() { hasValue = false; value = 0 }

    /// - Parameter alpha: smoothing factor in (0, 1]; 1 = passthrough.
    mutating func filter(_ x: Double, alpha: Double) -> Double {
        if !hasValue {
            hasValue = true
            value = x
        } else {
            value += alpha * (x - value)
        }
        return value
    }

    var current: Double { value }
}

/// Adaptive low-pass. `minCutoff` sets the floor (how still things are at
/// rest); `beta` sets how aggressively the cutoff opens up with speed of
/// change (how little lag under a hard manoeuvre).
struct OneEuroFilter {
    var minCutoff: Double
    var beta: Double
    var derivativeCutoff: Double

    private var x = LowPass()
    private var dx = LowPass()
    private var lastRaw: Double = 0

    /// Defaults come from a parameter sweep against three criteria at 100 Hz:
    /// residual noise on a parked car (< 0.004 g of the 0.01 g input), time to
    /// 90 % of a 0.3 g braking step (~130 ms), and amplitude retention on a
    /// 0.25 Hz manoeuvre (> 97 %). A low derivative cutoff matters more than
    /// it looks: it is what stops sensor hash from opening the main cutoff and
    /// letting jitter through at rest.
    init(minCutoff: Double = 0.3, beta: Double = 3.0, derivativeCutoff: Double = 0.6) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    mutating func reset() {
        x.reset(); dx.reset(); lastRaw = 0
    }

    mutating func filter(_ value: Double, dt: Double) -> Double {
        guard dt > 0, dt.isFinite else { return x.hasValue ? x.current : value }

        let rate = x.hasValue ? (value - lastRaw) / dt : 0
        lastRaw = value

        let edx = dx.filter(rate, alpha: Self.alpha(cutoff: derivativeCutoff, dt: dt))
        let cutoff = minCutoff + beta * abs(edx)
        return x.filter(value, alpha: Self.alpha(cutoff: cutoff, dt: dt))
    }

    /// Exact one-pole alpha for a given -3 dB cutoff and sample interval.
    static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * .pi * max(cutoff, 1e-4))
        return 1.0 / (1.0 + tau / dt)
    }
}

// MARK: - Bias tracker

/// Extremely slow low-pass whose output is subtracted from the signal.
/// Removes sustained offsets (hill grade, calibration tilt error) without
/// eating a real manoeuvre.
struct BiasTracker {
    /// Time constant in seconds.
    var tau: Double
    private var bias: Double = 0
    private var count = 0
    /// Bias adaptation is slowed right down while the signal is large, so a
    /// genuine long acceleration is not absorbed into the baseline.
    var freezeThreshold: Double = 0.06 // g

    init(tau: Double = 45) { self.tau = tau }

    mutating func reset() { bias = 0; count = 0 }

    mutating func remove(_ x: Double, dt: Double) -> Double {
        count += 1
        let effectiveTau = abs(x - bias) > freezeThreshold ? tau * 8 : tau
        // Seeding the baseline from the very first sample would bake that one
        // sample's noise (or that instant's real acceleration) into the output
        // as a constant offset for a whole time constant. Running the first
        // samples as a plain cumulative mean instead converges in a fraction
        // of a second and then hands over to the exponential filter.
        let alpha = max(dt / max(effectiveTau, 1e-3), 1.0 / Double(count))
        bias += min(1, alpha) * (x - bias)
        return x - bias
    }

    var value: Double { bias }
}

// MARK: - Lateral fusion

/// Fuses measured lateral acceleration with the kinematic estimate v·ω.
///
/// * measured: correct magnitude, but polluted by body roll — when the car
///   leans into a corner, part of gravity rotates into the lateral axis.
/// * v·ω: geometrically clean, no gravity leak, but needs a speed estimate
///   and goes to zero if speed is unknown.
///
/// Classic complementary split: trust v·ω at low frequency (steady cornering,
/// where roll error is worst) and the accelerometer at high frequency (sharp
/// swerves, where speed updates from GPS are too slow).
struct LateralFusion {
    /// Crossover frequency, Hz.
    var crossover: Double = 0.25

    private var lowFromKinematic = LowPass()
    private var lowFromMeasured = LowPass()

    mutating func reset() { lowFromKinematic.reset(); lowFromMeasured.reset() }

    /// - Parameters:
    ///   - measured: lateral acceleration in g from the IMU.
    ///   - yawRate: rad/s, positive = left turn.
    ///   - speed: m/s, or nil if unknown.
    mutating func fuse(measured: Double, yawRate: Double, speed: Double?, dt: Double) -> Double {
        guard let speed, speed > 2.0 else {
            // No usable speed: pass the measurement through untouched.
            lowFromKinematic.reset()
            lowFromMeasured.reset()
            return measured
        }
        // a_lat = v * omega, converted from m/s^2 to g.
        let kinematic = (speed * yawRate) / 9.80665
        let alpha = OneEuroFilter.alpha(cutoff: crossover, dt: dt)
        let lowK = lowFromKinematic.filter(kinematic, alpha: alpha)
        let lowM = lowFromMeasured.filter(measured, alpha: alpha)
        let highM = measured - lowM
        return lowK + highM
    }
}

// MARK: - Critically damped spring

/// Frame-rate independent second-order follower used on the render side.
/// Keeps dot motion continuous across dropped packets and across a change of
/// refresh rate (60 Hz vs 120 Hz ProMotion) with no visible difference.
struct SpringFollower {
    /// Natural frequency, rad/s. Higher = snappier.
    var omega: Double
    private(set) var position: Double = 0
    private(set) var velocity: Double = 0

    init(omega: Double = 18) { self.omega = omega }

    mutating func reset(to value: Double = 0) { position = value; velocity = 0 }

    /// Exact analytic step of a critically damped spring — unconditionally
    /// stable for any `dt`, unlike explicit Euler integration.
    mutating func step(target: Double, dt: Double) -> Double {
        guard dt > 0 else { return position }
        let clampedDt = min(dt, 0.1)
        let w = omega
        let exp = Foundation.exp(-w * clampedDt)
        let dp = position - target
        let c = velocity + w * dp
        position = target + (dp + c * clampedDt) * exp
        velocity = (velocity - c * w * clampedDt) * exp
        return position
    }
}
