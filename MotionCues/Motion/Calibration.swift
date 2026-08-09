//
//  Calibration.swift
//
//  Finding the vehicle's forward axis.
//
//  After `ReferenceFrameResolver` we have acceleration in a frame whose Z is
//  vertical but whose heading is arbitrary (Core Motion's
//  `.xArbitraryZVertical` deliberately avoids the magnetometer — inside a car
//  body the magnetometer is useless anyway). One unknown remains: the yaw
//  angle ψ between that arbitrary X axis and the direction the car points.
//
//  ψ is estimated from the data itself, primarily by regressing horizontal
//  acceleration onto the yaw rate.
//
//  The physics: while cornering, lateral acceleration is a_lat ≈ v·ω_z, and a
//  car's speed is always positive. So over any window containing turns,
//
//      cov(a_horizontal, ω_z) ≈ (v̄ / g) · left̂
//
//  because the longitudinal component is not correlated with which way you
//  happen to be turning. Normalising that covariance vector gives the "left"
//  axis directly, and because v̄ > 0 the *sign* comes out of the same
//  calculation — there is no 180° ambiguity to resolve afterwards. Forward is
//  then left̂ rotated by −90°.
//
//  An earlier version of this used PCA on the horizontal acceleration cloud,
//  assuming braking and accelerating dominate the variance. That assumption is
//  wrong often enough to matter: in town, a few roundabouts produce far more
//  lateral energy than the longitudinal traffic shuffle, and the estimate then
//  locks on to the lateral axis and is 90° out. PCA survives only as the
//  fallback for the one case the regression cannot handle — a long motorway
//  stretch with no cornering at all — where it is reported at low confidence
//  and the 180° ambiguity genuinely cannot be settled.
//
//  The same estimator keeps running in the background at a very slow blend
//  rate, which absorbs the gyro heading drift that `.xArbitraryZVertical`
//  accumulates (a few degrees per minute) and copes with the phone being
//  nudged in its holder.
//
//  A manual offset on top lets you nudge it by hand if you want to.
//

import Foundation

struct CalibrationQuality: Sendable, Equatable {
    /// 0…1, how confident we are in the forward axis.
    var confidence: Double = 0
    /// How much longitudinal action we have seen, 0…1.
    var longitudinalCoverage: Double = 0
    /// How much cornering we have seen, 0…1.
    var lateralCoverage: Double = 0
    /// Estimated yaw, radians.
    var yaw: Double = 0
    var sampleCount: Int = 0

    var isUsable: Bool { confidence > 0.35 && lateralCoverage > 0.2 }
}

/// Rolling estimator over horizontal acceleration and yaw rate.
final class YawEstimator {
    private struct Sample {
        var ax: Double
        var ay: Double
        var wz: Double
    }

    private var ring: [Sample]
    private var head = 0
    private var filled = 0
    private let capacity: Int
    /// Only accumulate samples where something is actually happening; idling
    /// at a red light must not dilute the estimate.
    private let activityThreshold = 0.012 // g

    init(capacity: Int = 3000) { // ~30 s at 100 Hz
        self.capacity = capacity
        ring = Array(repeating: Sample(ax: 0, ay: 0, wz: 0), count: capacity)
    }

    func reset() {
        head = 0
        filled = 0
    }

    var count: Int { filled }

    func add(ax: Double, ay: Double, yawRate: Double) {
        guard (ax * ax + ay * ay).squareRoot() > activityThreshold || abs(yawRate) > 0.05 else { return }
        ring[head] = Sample(ax: ax, ay: ay, wz: yawRate)
        head = (head + 1) % capacity
        filled = min(filled + 1, capacity)
    }

    /// Yaw rate below this (rad/s RMS) means the window holds no real
    /// cornering and the regression has nothing to work with.
    private let minYawEnergy = 0.02

    /// Returns nil until there is enough signal to say anything.
    func estimate() -> CalibrationQuality? {
        guard filled >= 200 else { return nil }
        let n = Double(filled)

        var sumX = 0.0, sumY = 0.0, sumW = 0.0
        for i in 0..<filled {
            sumX += ring[i].ax
            sumY += ring[i].ay
            sumW += ring[i].wz
        }
        let mx = sumX / n, my = sumY / n, mw = sumW / n

        var sxx = 0.0, syy = 0.0, sxy = 0.0, sww = 0.0, sxw = 0.0, syw = 0.0
        for i in 0..<filled {
            let dx = ring[i].ax - mx
            let dy = ring[i].ay - my
            let dw = ring[i].wz - mw
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
            sww += dw * dw; sxw += dx * dw; syw += dy * dw
        }
        sxx /= n; syy /= n; sxy /= n; sww /= n; sxw /= n; syw /= n

        let yawRMS = sww.squareRoot()

        var q = CalibrationQuality()
        q.sampleCount = filled
        q.lateralCoverage = min(1, yawRMS / 0.12)

        if yawRMS > minYawEnergy {
            // --- Primary: regress horizontal acceleration onto yaw rate. ---
            // b ≈ (mean speed / g) · left̂, sign included.
            let bx = sxw / sww
            let by = syw / sww
            let bLen = (bx * bx + by * by).squareRoot()

            // |b| is a mean speed in g·s/rad; below ~0.1 the car is basically
            // stationary and the regression is measuring nothing.
            if bLen > 0.1 {
                let lx = bx / bLen, ly = by / bLen
                // forward = left rotated by −90°, so ψ = atan2(−lx, ly).
                q.yaw = Self.wrap(atan2(-lx, ly))

                // How well the fitted lateral channel actually explains the
                // yaw rate: this is the confidence.
                var latEnergy = 0.0, cross = 0.0, fwdEnergy = 0.0
                let fx = ly, fy = -lx
                for i in 0..<filled {
                    let dx = ring[i].ax - mx, dy = ring[i].ay - my, dw = ring[i].wz - mw
                    let lat = dx * lx + dy * ly
                    let fwd = dx * fx + dy * fy
                    latEnergy += lat * lat
                    fwdEnergy += fwd * fwd
                    cross += lat * dw
                }
                let stdLat = (latEnergy / n).squareRoot()
                let rho = (stdLat * yawRMS) > 1e-12 ? (cross / n) / (stdLat * yawRMS) : 0

                q.longitudinalCoverage = min(1, (fwdEnergy / n).squareRoot() / 0.05)
                q.confidence = max(0, min(1, rho)) * min(1, q.lateralCoverage * 2)
                return q
            }
        }

        // --- Fallback: no cornering to learn from. Principal axis of the
        // horizontal acceleration cloud, which cannot resolve forwards from
        // backwards, so it is reported at deliberately low confidence.
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        let mean = (sxx + syy) / 2
        let diff = (sxx - syy) / 2
        let radius = (diff * diff + sxy * sxy).squareRoot()
        let lambda1 = mean + radius
        let lambda2 = max(mean - radius, 1e-12)
        let anisotropy = 1.0 - (lambda2 / lambda1)

        q.yaw = Self.wrap(theta)
        q.longitudinalCoverage = min(1, lambda1.squareRoot() / 0.05)
        q.lateralCoverage = 0
        // Capped: without a turn the 180° ambiguity is genuinely unresolvable,
        // so this must never satisfy `isUsable`.
        q.confidence = min(0.3, anisotropy * q.longitudinalCoverage)
        return q
    }

    static func wrap(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a > .pi { a -= 2 * .pi }
        if a < -.pi { a += 2 * .pi }
        return a
    }

    /// Shortest signed difference from `a` to `b`.
    static func angleDelta(_ a: Double, _ b: Double) -> Double { wrap(b - a) }
}

/// Persisted calibration state.
struct CalibrationState: Codable, Equatable, Sendable {
    /// Yaw of the vehicle's forward axis in the sensor reference frame, rad.
    var yaw: Double = 0
    /// Extra user offset applied on top, rad.
    var manualOffset: Double = 0
    /// True once a guided calibration has succeeded at least once.
    var isCalibrated: Bool = false
    /// Whether the background estimator may keep refining `yaw`.
    var autoRefine: Bool = true

    var effectiveYaw: Double { YawEstimator.wrap(yaw + manualOffset) }
}
