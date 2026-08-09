//
//  SyntheticDrive.swift
//
//  A ground-truth drive generator for the tests. Unlike
//  `SimulatedMotionProvider` (which is a product feature) this one hands back
//  both the wire frame *and* what the answer should be, so the tests can check
//  the pipeline rather than just watch it run.
//

import Foundation
import simd
@testable import MotionCues

struct DriveSample {
    var frame: MotionFrame
    /// Vehicle-frame ground truth, in g.
    var trueForward: Double
    var trueLateral: Double
    var trueYawRate: Double
    var speed: Double
}

struct SyntheticDrive {
    /// Yaw of the car's forward axis in the sensor reference frame.
    var vehicleYaw: Double = 0.9
    /// How the phone is propped up, so the device frame is not the reference
    /// frame either.
    var devicePitch: Double = 0.4
    var deviceRoll: Double = -0.25
    var rate: Double = 100
    var noise: Double = 0.0
    var includeSpeed = false
    /// Peak longitudinal acceleration, g. 0.25 g is a firm but ordinary brake.
    var forwardAmplitude: Double = 0.22
    /// Peak yaw rate, rad/s. 0.12 at 15 m/s gives ~0.18 g of lateral, which is
    /// a normal sweeping bend. Raise it to model roundabouts and town driving,
    /// where lateral energy can exceed longitudinal.
    var yawAmplitude: Double = 0.12
    /// Set false to model a motorway stretch with no cornering at all.
    var includeCornering = true

    func generate(seconds: Double) -> [DriveSample] {
        let dt = 1.0 / rate
        let n = Int(seconds * rate)
        var out: [DriveSample] = []
        out.reserveCapacity(n)

        var rng = SplitMix64(seed: 0xC0FFEE)
        var speed = 12.0
        var seq: UInt32 = 0

        // device → reference rotation, fixed for the whole run.
        let qDeviceToRef = simd_quatd(angle: devicePitch, axis: SIMD3<Double>(1, 0, 0))
            * simd_quatd(angle: deviceRoll, axis: SIMD3<Double>(0, 1, 0))
        let refToDevice = simd_matrix3x3(qDeviceToRef).transpose

        // reference → vehicle is a yaw of `vehicleYaw`.
        let c = cos(vehicleYaw), s = sin(vehicleYaw)
        let vehicleToRef = simd_double3x3(rows: [
            SIMD3<Double>(c, -s, 0),
            SIMD3<Double>(s,  c, 0),
            SIMD3<Double>(0,  0, 1)
        ])

        for i in 0..<n {
            let t = Double(i) * dt
            let forward = forwardAmplitude * sin(2 * .pi * t / 9.0)
                        + 0.45 * forwardAmplitude * sin(2 * .pi * t / 3.3)
            // Cornering on its own periods, so it is not collinear with the
            // longitudinal signal and the regression has something to separate.
            let yawRate = includeCornering ? yawAmplitude * sin(2 * .pi * t / 17.0) : 0
            speed = max(4, min(30, speed + forward * 9.80665 * dt))
            let lateral = (speed * yawRate) / 9.80665
            let vertical = 0.01 * sin(2 * .pi * t / 1.7)

            var accelVehicle = SIMD3<Double>(forward, lateral, vertical)
            if noise > 0 {
                accelVehicle += SIMD3<Double>(rng.gaussian(), rng.gaussian(), rng.gaussian()) * noise
            }

            let accelRef = vehicleToRef * accelVehicle
            let omegaRef = SIMD3<Double>(0, 0, yawRate)

            seq &+= 1
            let frame = MotionFrame(
                seq: seq,
                senderTime: t,
                quaternion: SIMD4<Double>(qDeviceToRef.imag.x, qDeviceToRef.imag.y,
                                          qDeviceToRef.imag.z, qDeviceToRef.real),
                userAcceleration: refToDevice * accelRef,
                rotationRate: refToDevice * omegaRef,
                gravity: refToDevice * SIMD3<Double>(0, 0, -1),
                speed: includeSpeed ? speed : nil
            )

            out.append(DriveSample(frame: frame,
                                   trueForward: forward,
                                   trueLateral: lateral,
                                   trueYawRate: yawRate,
                                   speed: speed))
        }
        return out
    }
}

func pearson(_ a: [Double], _ b: [Double]) -> Double {
    precondition(a.count == b.count && !a.isEmpty)
    let n = Double(a.count)
    let ma = a.reduce(0, +) / n
    let mb = b.reduce(0, +) / n
    var num = 0.0, da = 0.0, db = 0.0
    for i in 0..<a.count {
        let x = a[i] - ma, y = b[i] - mb
        num += x * y; da += x * x; db += y * y
    }
    guard da > 0, db > 0 else { return 0 }
    return num / (da * db).squareRoot()
}
