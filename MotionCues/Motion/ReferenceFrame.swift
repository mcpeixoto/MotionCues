//
//  ReferenceFrame.swift
//
//  Turning a device-frame sample into a world-ish frame with Z pointing up.
//
//  Apple's documentation for `CMAttitude.rotationMatrix` / `.quaternion` does
//  not state the rotation direction unambiguously, and the two possible
//  conventions differ by a transpose. Rather than guess, we *measure*: gravity
//  is known in the device frame, and in any Z-vertical reference frame it must
//  come out as (0, 0, -1). We try both conventions on live data and keep the
//  one that satisfies that. If neither does (which is what happens with
//  `CMHeadphoneMotionManager`, whose attitude reference is head-relative and
//  not documented as Z-vertical), we fall back to a gravity-only tilt
//  compensation.
//

import Foundation
import simd

enum FrameConvention: String {
    /// R maps device-frame vectors into the reference frame.
    case deviceToReference
    /// R maps reference-frame vectors into the device frame (use Rᵀ).
    case referenceToDevice
    /// Attitude unusable; build the transform from the gravity vector alone.
    /// Heading is then undefined and rotates with the device.
    case gravityOnly
}

struct ReferenceFrameResolver {
    private(set) var convention: FrameConvention?
    private var scoreDeviceToRef: Double = 0
    private var scoreRefToDevice: Double = 0
    private var samples = 0
    private static let samplesNeeded = 30

    mutating func reset() {
        convention = nil
        scoreDeviceToRef = 0
        scoreRefToDevice = 0
        samples = 0
    }

    /// Feed live samples until a convention is settled on.
    mutating func observe(quaternion q: SIMD4<Double>, gravity: SIMD3<Double>) {
        guard convention == nil else { return }

        let norm = simd_length(q)
        let gNorm = simd_length(gravity)
        guard norm > 0.5, gNorm > 0.5 else { return }

        let rot = simd_matrix3x3(simd_quatd(ix: q.x / norm, iy: q.y / norm, iz: q.z / norm, r: q.w / norm))
        let g = gravity / gNorm
        let expected = SIMD3<Double>(0, 0, -1)

        // Lower is better: distance from the expected reference-frame gravity.
        scoreDeviceToRef += simd_distance(rot * g, expected)
        scoreRefToDevice += simd_distance(rot.transpose * g, expected)
        samples += 1

        guard samples >= Self.samplesNeeded else { return }

        let avgA = scoreDeviceToRef / Double(samples)
        let avgB = scoreRefToDevice / Double(samples)
        // 0.35 ≈ 20° of persistent mismatch. Anything worse means the attitude
        // reference simply is not Z-vertical.
        if min(avgA, avgB) > 0.35 {
            convention = .gravityOnly
        } else {
            convention = avgA <= avgB ? .deviceToReference : .referenceToDevice
        }
    }

    /// Rotation that takes a device-frame vector into the Z-up reference frame.
    func rotation(quaternion q: SIMD4<Double>, gravity: SIMD3<Double>) -> simd_double3x3 {
        switch convention {
        case .deviceToReference:
            return Self.matrix(from: q)
        case .referenceToDevice:
            return Self.matrix(from: q).transpose
        case .gravityOnly, nil:
            return Self.tiltOnlyRotation(gravity: gravity)
        }
    }

    private static func matrix(from q: SIMD4<Double>) -> simd_double3x3 {
        let n = simd_length(q)
        guard n > 1e-6 else { return matrix_identity_double3x3 }
        return simd_matrix3x3(simd_quatd(ix: q.x / n, iy: q.y / n, iz: q.z / n, r: q.w / n))
    }

    /// Builds a rotation that maps the measured gravity direction onto
    /// (0, 0, -1). Roll and pitch are correct; heading is arbitrary and will
    /// drift with the device, which is why this is only a fallback.
    static func tiltOnlyRotation(gravity: SIMD3<Double>) -> simd_double3x3 {
        let len = simd_length(gravity)
        guard len > 1e-6 else { return matrix_identity_double3x3 }
        let from = gravity / len
        let to = SIMD3<Double>(0, 0, -1)

        let dot = simd_dot(from, to)
        if dot > 0.999999 { return matrix_identity_double3x3 }
        if dot < -0.999999 {
            // 180° flip: any axis perpendicular to `from` will do.
            let axis = simd_normalize(simd_cross(from, SIMD3<Double>(1, 0, 0)).lengthSquaredSafe > 1e-6
                                      ? simd_cross(from, SIMD3<Double>(1, 0, 0))
                                      : simd_cross(from, SIMD3<Double>(0, 1, 0)))
            return simd_matrix3x3(simd_quatd(angle: .pi, axis: axis))
        }
        let axis = simd_normalize(simd_cross(from, to))
        let angle = acos(max(-1, min(1, dot)))
        return simd_matrix3x3(simd_quatd(angle: angle, axis: axis))
    }
}

private extension SIMD3 where Scalar == Double {
    var lengthSquaredSafe: Double { x * x + y * y + z * z }
}
