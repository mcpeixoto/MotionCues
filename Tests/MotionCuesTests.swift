//
//  MotionCuesTests.swift
//
//  These check the parts that are easy to get quietly, invisibly wrong: the
//  wire format, the attitude convention, the calibration recovery, the filter
//  behaviour, and the direction the dots actually move.
//

import XCTest
import simd
import Metal
@testable import MotionCues

final class WireFormatTests: XCTestCase {
    func testMotionFrameRoundTrip() throws {
        let original = MotionFrame(
            seq: 123_456,
            senderTime: 987.654321,
            quaternion: SIMD4<Double>(0.1, -0.2, 0.3, 0.927),
            userAcceleration: SIMD3<Double>(0.01, -0.5, 0.25),
            rotationRate: SIMD3<Double>(-1.5, 0.75, 0.125),
            gravity: SIMD3<Double>(0, 0, -1),
            speed: 23.5
        )
        let data = MotionFrameCodec.encode(original)
        XCTAssertEqual(data.count, MotionFrameCodec.byteCount)

        let decoded = try XCTUnwrap(MotionFrameCodec.decode(data))
        XCTAssertEqual(decoded.seq, original.seq)
        // senderTime is the one field carried at full double precision,
        // because dt accuracy feeds every filter.
        XCTAssertEqual(decoded.senderTime, original.senderTime, accuracy: 1e-12)
        XCTAssertEqual(decoded.quaternion.w, original.quaternion.w, accuracy: 1e-6)
        XCTAssertEqual(decoded.userAcceleration.y, original.userAcceleration.y, accuracy: 1e-6)
        XCTAssertEqual(decoded.rotationRate.x, original.rotationRate.x, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(decoded.speed), 23.5, accuracy: 1e-4)
    }

    /// Three states, not two: detecting-and-driving, detecting-and-parked,
    /// and not-detecting-at-all. The Mac treats the third very differently
    /// from the second, so it must survive the wire.
    func testDriveStateRoundTripsAsThreeStates() throws {
        func roundTrip(_ value: Bool?) throws -> Bool?? {
            var frame = MotionFrame(seq: 1, senderTime: 0,
                                    quaternion: SIMD4<Double>(0, 0, 0, 1),
                                    userAcceleration: .zero, rotationRate: .zero,
                                    gravity: SIMD3<Double>(0, 0, -1))
            frame.isDriving = value
            return try XCTUnwrap(MotionFrameCodec.decode(MotionFrameCodec.encode(frame))).isDriving
        }
        XCTAssertEqual(try roundTrip(true), true)
        XCTAssertEqual(try roundTrip(false), false)
        XCTAssertNil(try roundTrip(nil) ?? nil)
    }

    /// The flags byte carries speed validity and drive state independently.
    func testSpeedAndDriveFlagsDoNotInterfere() throws {
        var frame = MotionFrame(seq: 1, senderTime: 0,
                                quaternion: SIMD4<Double>(0, 0, 0, 1),
                                userAcceleration: .zero, rotationRate: .zero,
                                gravity: SIMD3<Double>(0, 0, -1),
                                speed: nil, isDriving: true)
        var decoded = try XCTUnwrap(MotionFrameCodec.decode(MotionFrameCodec.encode(frame)))
        XCTAssertNil(decoded.speed)
        XCTAssertEqual(decoded.isDriving, true)

        frame.speed = 18
        frame.isDriving = false
        decoded = try XCTUnwrap(MotionFrameCodec.decode(MotionFrameCodec.encode(frame)))
        XCTAssertEqual(try XCTUnwrap(decoded.speed), 18, accuracy: 1e-4)
        XCTAssertEqual(decoded.isDriving, false)
    }

    func testAbsentSpeedStaysAbsent() throws {
        var frame = MotionFrame(seq: 1, senderTime: 0,
                                quaternion: SIMD4<Double>(0, 0, 0, 1),
                                userAcceleration: .zero, rotationRate: .zero,
                                gravity: SIMD3<Double>(0, 0, -1))
        frame.speed = nil
        let decoded = try XCTUnwrap(MotionFrameCodec.decode(MotionFrameCodec.encode(frame)))
        XCTAssertNil(decoded.speed)
    }

    func testHeartbeatRoundTrip() throws {
        let beat = HeartbeatPacket(ackSeq: 42, receiverTime: 1234.5)
        let decoded = try XCTUnwrap(HeartbeatPacket.decode(beat.encoded()))
        XCTAssertEqual(decoded, beat)
    }

    func testRejectsForeignAndTruncatedData() {
        XCTAssertNil(MotionFrameCodec.decode(Data(repeating: 0xAB, count: 76)))
        XCTAssertNil(MotionFrameCodec.decode(Data(repeating: 0, count: 10)))
        XCTAssertNil(HeartbeatPacket.decode(Data()))
    }

    func testKindDiscrimination() {
        let motion = MotionFrameCodec.encode(
            MotionFrame(seq: 1, senderTime: 0, quaternion: SIMD4<Double>(0, 0, 0, 1),
                        userAcceleration: .zero, rotationRate: .zero,
                        gravity: SIMD3<Double>(0, 0, -1)))
        XCTAssertEqual(MotionFrameCodec.kind(of: motion), .motion)
        XCTAssertEqual(MotionFrameCodec.kind(of: HeartbeatPacket(ackSeq: 0, receiverTime: 0).encoded()),
                       .heartbeat)
        // A heartbeat must not decode as a motion frame.
        XCTAssertNil(MotionFrameCodec.decode(HeartbeatPacket(ackSeq: 0, receiverTime: 0).encoded()))
    }
}

// MARK: - Attitude convention

final class ReferenceFrameTests: XCTestCase {
    /// The whole point of the resolver: it must work out which way Core
    /// Motion's quaternion rotates, by checking gravity, instead of us
    /// guessing.
    func testResolvesDeviceToReferenceConvention() {
        var resolver = ReferenceFrameResolver()
        let q = simd_quatd(angle: 0.4, axis: simd_normalize(SIMD3<Double>(1, 0.3, 0.1)))
        let refToDevice = simd_matrix3x3(q).transpose
        let gravityDevice = refToDevice * SIMD3<Double>(0, 0, -1)
        let quat = SIMD4<Double>(q.imag.x, q.imag.y, q.imag.z, q.real)

        for _ in 0..<60 { resolver.observe(quaternion: quat, gravity: gravityDevice) }
        XCTAssertEqual(resolver.convention, .deviceToReference)

        let back = resolver.rotation(quaternion: quat, gravity: gravityDevice) * gravityDevice
        XCTAssertEqual(back.z, -1, accuracy: 1e-6)
        XCTAssertEqual(back.x, 0, accuracy: 1e-6)
    }

    func testResolvesReferenceToDeviceConvention() {
        var resolver = ReferenceFrameResolver()
        // Same rotation, but published the other way round.
        let q = simd_quatd(angle: 0.4, axis: simd_normalize(SIMD3<Double>(1, 0.3, 0.1)))
        let inverse = q.inverse
        let gravityDevice = simd_matrix3x3(q).transpose * SIMD3<Double>(0, 0, -1)
        let quat = SIMD4<Double>(inverse.imag.x, inverse.imag.y, inverse.imag.z, inverse.real)

        for _ in 0..<60 { resolver.observe(quaternion: quat, gravity: gravityDevice) }
        XCTAssertEqual(resolver.convention, .referenceToDevice)

        let back = resolver.rotation(quaternion: quat, gravity: gravityDevice) * gravityDevice
        XCTAssertEqual(back.z, -1, accuracy: 1e-6)
    }

    /// AirPods: attitude is head-relative, so neither convention lines up with
    /// gravity and we must fall back rather than produce nonsense.
    func testFallsBackWhenAttitudeIsNotVerticalAligned() {
        var resolver = ReferenceFrameResolver()
        let junk = SIMD4<Double>(0, 0, 0, 1) // identity
        // Gravity well away from -Z in the device frame: identity attitude
        // cannot possibly be the right transform.
        let gravity = simd_normalize(SIMD3<Double>(0.8, 0.2, -0.3))
        for _ in 0..<60 { resolver.observe(quaternion: junk, gravity: gravity) }
        XCTAssertEqual(resolver.convention, .gravityOnly)

        let back = resolver.rotation(quaternion: junk, gravity: gravity) * gravity
        XCTAssertEqual(back.z, -1, accuracy: 1e-6)
        XCTAssertEqual(simd_length(SIMD2(back.x, back.y)), 0, accuracy: 1e-6)
    }
}

// MARK: - Filters

final class FilterTests: XCTestCase {
    func testOneEuroIsQuietAtRest() {
        var f = OneEuroFilter(minCutoff: 0.4, beta: 0.6)
        var rng = SplitMix64(seed: 7)
        var peak = 0.0
        for i in 0..<2000 {
            let noisy = 0.01 * rng.gaussian()          // ±0.01 g of sensor hash
            let out = f.filter(noisy, dt: 0.01)
            if i > 200 { peak = max(peak, abs(out)) }  // let it settle first
        }
        // The residual must be a fraction of the input noise, or the dots
        // would jitter on a parked car.
        XCTAssertLessThan(peak, 0.004, "One Euro let too much rest noise through")
    }

    func testOneEuroTracksAStepQuickly() {
        var f = OneEuroFilter()
        for _ in 0..<200 { _ = f.filter(0, dt: 0.01) }
        var samplesToReach90 = Int.max
        for i in 0..<200 {
            if f.filter(0.3, dt: 0.01) >= 0.27 {      // a firm braking step
                samplesToReach90 = i
                break
            }
        }
        // Under 200 ms to 90%. The adaptive cutoff is what buys this: a fixed
        // low-pass quiet enough to pass `testOneEuroIsQuietAtRest` would need
        // well over a second.
        XCTAssertLessThan(samplesToReach90, 20,
                          "step response too slow (\(samplesToReach90) samples)")
    }

    func testOneEuroKeepsManoeuvreAmplitude() {
        // A 0.25 Hz swerve must come out at nearly full size, or the cue would
        // understate what the body is feeling.
        var f = OneEuroFilter()
        var rng = SplitMix64(seed: 11)
        var peak = 0.0
        for i in 0..<4000 {
            let t = Double(i) * 0.01
            let out = f.filter(0.25 * sin(2 * .pi * 0.25 * t) + 0.01 * rng.gaussian(), dt: 0.01)
            if i > 1000 { peak = max(peak, out) }
        }
        XCTAssertGreaterThan(peak / 0.25, 0.9, "manoeuvre amplitude was attenuated")
    }

    func testBiasTrackerRemovesSlowOffsetButKeepsManoeuvre() {
        var tracker = BiasTracker(tau: 45)
        // Two minutes sitting on a hill: a constant 0.05 g must fade out.
        var out = 0.0
        for _ in 0..<12_000 { out = tracker.remove(0.05, dt: 0.01) }
        XCTAssertLessThan(abs(out), 0.01, "sustained grade was not absorbed")

        // A real six-second acceleration on top must still come through.
        var peak = 0.0
        for _ in 0..<600 { peak = max(peak, tracker.remove(0.05 + 0.25, dt: 0.01)) }
        XCTAssertGreaterThan(peak, 0.2, "a real manoeuvre was eaten by the bias tracker")
    }

    func testSpringIsStableAtAnyTimestep() {
        for dt in [1.0 / 120.0, 1.0 / 60.0, 1.0 / 30.0, 0.25, 1.0] {
            var s = SpringFollower(omega: 18)
            var last = 0.0
            for _ in 0..<200 { last = s.step(target: 10, dt: dt) }
            XCTAssertEqual(last, 10, accuracy: 0.01, "spring diverged or stalled at dt=\(dt)")
        }
    }

    func testSpringDoesNotOvershoot() {
        var s = SpringFollower(omega: 18)
        var peak = 0.0
        for _ in 0..<400 { peak = max(peak, s.step(target: 1, dt: 1.0 / 60.0)) }
        // Critically damped: it must approach from below, never ring.
        XCTAssertLessThanOrEqual(peak, 1.0001)
    }

    func testLateralFusionPassesThroughWithoutSpeed() {
        var fusion = LateralFusion()
        let out = fusion.fuse(measured: 0.2, yawRate: 0.3, speed: nil, dt: 0.01)
        XCTAssertEqual(out, 0.2, accuracy: 1e-9)
    }

    func testLateralFusionCancelsRollBias() {
        // Steady cornering at 20 m/s and 0.25 rad/s: true lateral is
        // 20*0.25/9.81 = 0.51 g. Pretend the accelerometer reads 0.1 g high
        // because the car is leaning.
        var fusion = LateralFusion()
        let truth = (20.0 * 0.25) / 9.80665
        var out = 0.0
        for _ in 0..<3000 {
            out = fusion.fuse(measured: truth + 0.1, yawRate: 0.25, speed: 20, dt: 0.01)
        }
        XCTAssertEqual(out, truth, accuracy: 0.02,
                       "roll bias survived the complementary fusion")
    }
}

// MARK: - Calibration

final class CalibrationTests: XCTestCase {
    func testRecoversForwardAxisFromDrivingAlone() {
        for trueYaw in [0.0, 0.9, -2.1, 2.9] {
            let drive = SyntheticDrive(vehicleYaw: trueYaw, noise: 0.01)
            let samples = drive.generate(seconds: 40)

            var resolver = ReferenceFrameResolver()
            let estimator = YawEstimator()
            for s in samples {
                resolver.observe(quaternion: s.frame.quaternion, gravity: s.frame.gravity)
                let r = resolver.rotation(quaternion: s.frame.quaternion, gravity: s.frame.gravity)
                let a = r * s.frame.userAcceleration
                let w = r * s.frame.rotationRate
                estimator.add(ax: a.x, ay: a.y, yawRate: w.z)
            }

            let q = try! XCTUnwrap(estimator.estimate())
            let error = abs(YawEstimator.angleDelta(q.yaw, trueYaw))
            XCTAssertLessThan(error, 0.20,
                              "yaw error \(error * 180 / .pi)° for true yaw \(trueYaw * 180 / .pi)°")
            XCTAssertGreaterThan(q.confidence, 0.3)
        }
    }

    /// Forwards vs backwards: the regression must never land 180° out, because
    /// that would invert every single cue.
    func testResolvesForwardBackwardAmbiguity() {
        let q = run(SyntheticDrive(vehicleYaw: 0.0, noise: 0.005))
        XCTAssertLessThan(abs(YawEstimator.angleDelta(q.yaw, 0)), 0.2)
    }

    /// Town driving: roundabouts and junctions put more energy into the
    /// lateral axis than into accelerating and braking. A principal-axis
    /// estimator locks on to the wrong axis here and lands 90° out; the
    /// yaw-rate regression does not care about the ratio at all.
    func testHandlesCorneringDominatedDriving() {
        let q = run(SyntheticDrive(vehicleYaw: 0.6, noise: 0.01,
                                   forwardAmplitude: 0.08, yawAmplitude: 0.45))
        let error = abs(YawEstimator.angleDelta(q.yaw, 0.6))
        XCTAssertLessThan(error, 0.20, "yaw error \(error * 180 / .pi)° in town driving")
        XCTAssertGreaterThan(q.confidence, 0.4)
    }

    /// Motorway with no bends: the answer is genuinely unknowable, so the
    /// estimator must say so rather than guess and be confidently 180° wrong.
    func testReportsLowConfidenceWithoutCornering() {
        let q = run(SyntheticDrive(vehicleYaw: 0.6, noise: 0.01, includeCornering: false))
        XCTAssertFalse(q.isUsable, "claimed a usable calibration with no cornering")
        XCTAssertLessThanOrEqual(q.confidence, 0.3)
    }

    private func run(_ drive: SyntheticDrive, seconds: Double = 40) -> CalibrationQuality {
        let samples = drive.generate(seconds: seconds)
        var resolver = ReferenceFrameResolver()
        let estimator = YawEstimator()
        for s in samples {
            resolver.observe(quaternion: s.frame.quaternion, gravity: s.frame.gravity)
            let r = resolver.rotation(quaternion: s.frame.quaternion, gravity: s.frame.gravity)
            let a = r * s.frame.userAcceleration
            let w = r * s.frame.rotationRate
            estimator.add(ax: a.x, ay: a.y, yawRate: w.z)
        }
        return estimator.estimate() ?? CalibrationQuality()
    }

    func testAngleWrapping() {
        XCTAssertEqual(YawEstimator.wrap(3 * .pi), .pi, accuracy: 1e-9)
        XCTAssertEqual(YawEstimator.wrap(-3 * .pi), -.pi, accuracy: 1e-9)
        XCTAssertEqual(YawEstimator.angleDelta(3.0, -3.0), 2 * .pi - 6, accuracy: 1e-9)
    }
}

// MARK: - End to end

final class MotionEngineTests: XCTestCase {
    /// The real test: unknown phone orientation, unknown car heading, noise on
    /// top — and the engine still recovers longitudinal and lateral
    /// acceleration in the vehicle frame.
    func testEngineRecoversVehicleFrameEndToEnd() throws {
        let drive = SyntheticDrive(vehicleYaw: 1.7, devicePitch: 0.55,
                                   deviceRoll: -0.35, noise: 0.012)
        let samples = drive.generate(seconds: 60)

        let engine = MotionEngine()
        engine.smoothing = 0.4
        engine.sensitivity = 0.6
        engine.beginCalibration(duration: 30)

        var outForward: [Double] = []
        var outLateral: [Double] = []
        var refForward: [Double] = []
        var refLateral: [Double] = []

        for (i, s) in samples.enumerated() {
            engine.ingest(s.frame)
            // Only score the second half, after calibration has converged.
            guard i > samples.count / 2 else { continue }
            let m = engine.state.load()
            outForward.append(m.forward)
            outLateral.append(m.lateral)
            refForward.append(s.trueForward)
            refLateral.append(s.trueLateral)
        }

        XCTAssertTrue(engine.calibration.isCalibrated, "guided calibration never converged")

        let rF = pearson(outForward, refForward)
        let rL = pearson(outLateral, refLateral)
        XCTAssertGreaterThan(rF, 0.9, "longitudinal channel does not track ground truth (r=\(rF))")
        XCTAssertGreaterThan(rL, 0.9, "lateral channel does not track ground truth (r=\(rL))")

        // Cross-talk check: a well-resolved yaw means the forward channel must
        // not be a rotated mixture of the two.
        let crossTalk = abs(pearson(outForward, refLateral))
        XCTAssertLessThan(crossTalk, 0.5, "axes are still mixed (cross-talk r=\(crossTalk))")
    }

    func testEngineIsSilentWhenNothingHappens() {
        let engine = MotionEngine()
        let q = SIMD4<Double>(0, 0, 0, 1)
        let g = SIMD3<Double>(0, 0, -1)
        var t = 0.0
        var rng = SplitMix64(seed: 99)
        var peak = 0.0
        for i in 0..<6000 {
            t += 0.01
            let frame = MotionFrame(
                seq: UInt32(i), senderTime: t, quaternion: q,
                userAcceleration: SIMD3<Double>(0.008 * rng.gaussian(),
                                                0.008 * rng.gaussian(),
                                                0.008 * rng.gaussian()),
                rotationRate: SIMD3<Double>(0.002 * rng.gaussian(), 0, 0),
                gravity: g)
            engine.ingest(frame)
            if i > 1000 { peak = max(peak, engine.state.load().magnitude) }
        }
        // At Medium intensity 0.006 g is under half a pixel of travel.
        XCTAssertLessThan(peak, 0.006, "engine is not quiet on a parked car (peak \(peak) g)")
    }
}

// MARK: - Rate meter

final class RateMeterTests: XCTestCase {
    func testCountsDroppedPackets() {
        var meter = RateMeter()
        _ = meter.record(seq: 1, now: 0)
        _ = meter.record(seq: 2, now: 0.01)
        _ = meter.record(seq: 7, now: 0.02)   // 3, 4, 5, 6 lost
        XCTAssertEqual(meter.dropped, 4)
    }

    func testMeasuresRate() {
        var meter = RateMeter()
        var published = false
        for i in 0..<101 {
            published = meter.record(seq: UInt32(i), now: Double(i) * 0.01) || published
        }
        XCTAssertTrue(published)
        XCTAssertEqual(meter.rateHz, 100, accuracy: 5)
    }
}

// MARK: - Particle field

/// The field is the cue. What has to hold: nothing at rest, radial expansion
/// under acceleration, contraction under braking, lateral slide in corners,
/// a seamless wrap, and no unbounded growth.
final class ParticleFieldTests: XCTestCase {
    private var settings: RenderSettings {
        var s = RenderSettings()
        s.flowGain = 900
        s.dotDiameter = 9
        s.opacity = 1
        s.peripherySize = 240
        s.verticalCues = false
        return s
    }
    private let viewport = CGSize(width: 1470, height: 956)

    private func run(_ motion: VehicleMotion, seconds: Double,
                     field: ParticleField = ParticleField()) -> ParticleField {
        var f = field
        for _ in 0..<Int(seconds * 60) {
            f.update(motion: motion, settings: settings, dt: 1.0 / 60.0)
        }
        return f
    }

    // MARK: Rest

    /// A parked car must show a completely static field, and then nothing.
    func testRestProducesNothing() {
        let f = run(.zero, seconds: 10)
        XCTAssertEqual(simd_length(f.velocity), 0, accuracy: 1e-6)
        XCTAssertLessThan(f.intensity, 0.01)

        var drew = 0
        f.forEachParticle(viewport: viewport, settings: settings) { _ in drew += 1 }
        XCTAssertEqual(drew, 0, "the field drew something on a stationary car")
    }

    /// And it must come back to rest after a manoeuvre, not drift forever.
    func testFieldSettlesAfterAManoeuvre() {
        var f = run(VehicleMotion(forward: 0.25, lateral: 0, vertical: 0, yawRate: 0, timestamp: 0),
                    seconds: 4)
        XCTAssertGreaterThan(f.intensity, 0.3)
        f = run(.zero, seconds: 25, field: f)
        XCTAssertLessThan(simd_length(f.velocity), 0.5, "the field never stopped")
        XCTAssertLessThan(f.intensity, 0.02, "the cue never faded out")
    }

    // MARK: Direction

    /// Accelerating is radial expansion: particles move away from the centre.
    /// This is the whole reason the model has depth.
    func testAcceleratingExpandsTheFieldOutwards() {
        let f = run(VehicleMotion(forward: 0.25, lateral: 0, vertical: 0, yawRate: 0, timestamp: 0),
                    seconds: 2)
        XCTAssertGreaterThan(f.velocity.z, 50, "the field is not coming towards the viewer")

        // Particles must be moving away from the screen centre on average.
        let centre = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        var outward = 0, inward = 0
        f.forEachParticle(viewport: viewport, settings: settings) { p in
            let now = hypot(p.position.x - centre.x, p.position.y - centre.y)
            let before = hypot(p.previous.x - centre.x, p.previous.y - centre.y)
            if now > before { outward += 1 } else if now < before { inward += 1 }
        }
        XCTAssertGreaterThan(outward, 0, "no particles drawn")
        XCTAssertGreaterThan(Double(outward) / Double(outward + inward), 0.85,
                             "acceleration should expand the field, not slide it")
    }

    func testBrakingContractsTheField() {
        let f = run(VehicleMotion(forward: -0.25, lateral: 0, vertical: 0, yawRate: 0, timestamp: 0),
                    seconds: 2)
        XCTAssertLessThan(f.velocity.z, -50)

        let centre = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        var inward = 0, outward = 0
        f.forEachParticle(viewport: viewport, settings: settings) { p in
            let now = hypot(p.position.x - centre.x, p.position.y - centre.y)
            let before = hypot(p.previous.x - centre.x, p.previous.y - centre.y)
            if now < before { inward += 1 } else if now > before { outward += 1 }
        }
        XCTAssertGreaterThan(inward, 0)
        XCTAssertGreaterThan(Double(inward) / Double(inward + outward), 0.85)
    }

    /// Turning left slides the field right — same pseudo-force convention as
    /// everything else.
    func testTurningSlidesTheFieldSideways() {
        let left = run(VehicleMotion(forward: 0, lateral: 0.2, vertical: 0, yawRate: 0.3, timestamp: 0),
                       seconds: 2)
        XCTAssertGreaterThan(left.velocity.x, 30)

        let right = run(VehicleMotion(forward: 0, lateral: -0.2, vertical: 0, yawRate: -0.3, timestamp: 0),
                        seconds: 2)
        XCTAssertLessThan(right.velocity.x, -30)
    }

    // MARK: Behaviour under load

    /// The old model had to bound lateral travel because dots ran out of
    /// screen. A wrapping field must not: twenty seconds of hard cornering
    /// keeps flowing and stays bounded in state.
    func testSustainedCorneringNeverRunsOutOfRoom() {
        let f = run(VehicleMotion(forward: 0, lateral: 0.3, vertical: 0, yawRate: 0.4, timestamp: 0),
                    seconds: 20)
        XCTAssertGreaterThan(f.intensity, 0.5, "the cue faded out during a sustained corner")
        // Offsets are wrapped, so they stay inside one cell however long it runs.
        XCTAssertLessThan(abs(f.offset.x), f.cellX + 1e-6)
        XCTAssertGreaterThan(abs(f.velocity.x), 30, "flow stalled")

        var count = 0
        f.forEachParticle(viewport: viewport, settings: settings) { _ in count += 1 }
        XCTAssertGreaterThan(count, 20, "the field emptied out")
    }

    func testVelocityIsBoundedUnderAbsurdInput() {
        let f = run(VehicleMotion(forward: 40, lateral: -40, vertical: 20, yawRate: 9, timestamp: 0),
                    seconds: 30)
        XCTAssertTrue(simd_length(f.velocity).isFinite)
        // Terminal velocity is set by the acceleration cap over the friction.
        XCTAssertLessThan(simd_length(f.velocity), settings.flowGain * 1.2)
    }

    /// Particle count must not explode with viewport size, or a 6K display
    /// would melt.
    func testParticleCountStaysBounded() {
        let f = run(VehicleMotion(forward: 0.3, lateral: 0.2, vertical: 0, yawRate: 0.2, timestamp: 0),
                    seconds: 3)
        for size in [CGSize(width: 1470, height: 956),
                     CGSize(width: 3840, height: 2160),
                     CGSize(width: 6016, height: 3384)] {
            var count = 0
            f.forEachParticle(viewport: size, settings: settings) { _ in count += 1 }
            XCTAssertGreaterThan(count, 10, "no particles at \(size)")
            XCTAssertLessThan(count, 4000, "runaway particle count at \(size): \(count)")
        }
    }

    /// The middle of the screen is where you are reading; the cue belongs at
    /// the edges.
    func testParticlesStayInThePeriphery() {
        let f = run(VehicleMotion(forward: 0.3, lateral: 0, vertical: 0, yawRate: 0, timestamp: 0),
                    seconds: 3)
        let w = Double(viewport.width), h = Double(viewport.height)
        var maxEdgeDistance = 0.0
        var count = 0
        // Every particle, not just the strong ones. The first version of this
        // test only looked at alpha > 0.25 and so happily passed while a haze
        // of faint dots covered the entire screen — which is exactly what
        // shipped, and exactly what looked broken.
        f.forEachParticle(viewport: viewport, settings: settings) { p in
            count += 1
            maxEdgeDistance = max(maxEdgeDistance,
                                  ParticleField.edgeDistance(x: Double(p.position.x),
                                                             y: Double(p.position.y),
                                                             width: w, height: h))
        }
        XCTAssertGreaterThan(count, 0)
        // The cubic falloff and the 0.05 cut-off put the innermost particle at
        // 0.59 · peripherySize; anything beyond that means the band has leaked.
        XCTAssertLessThan(maxEdgeDistance, 0.62 * settings.peripherySize,
                          "a particle was drawn \(maxEdgeDistance) pt in from the edge")
    }

    /// The middle must be readable, so measure it directly: a generous central
    /// rectangle has to be completely empty.
    func testTheMiddleOfTheScreenIsEmpty() {
        let f = run(VehicleMotion(forward: 0.35, lateral: 0.25, vertical: 0, yawRate: 0.3, timestamp: 0),
                    seconds: 5)
        let inset = 0.7 * settings.peripherySize
        let clear = CGRect(x: inset, y: inset,
                           width: viewport.width - 2 * inset,
                           height: viewport.height - 2 * inset)
        var intruders = 0
        f.forEachParticle(viewport: viewport, settings: settings) { p in
            if clear.contains(p.position) { intruders += 1 }
        }
        XCTAssertEqual(intruders, 0, "\(intruders) particles were drawn over the middle of the screen")
    }

    // MARK: Maths

    func testWrapAndShortest() {
        XCTAssertEqual(ParticleField.wrap(-1, 10), 9, accuracy: 1e-9)
        XCTAssertEqual(ParticleField.wrap(23, 10), 3, accuracy: 1e-9)
        XCTAssertEqual(ParticleField.shortest(9, 10), -1, accuracy: 1e-9)
        XCTAssertEqual(ParticleField.shortest(-9, 10), 1, accuracy: 1e-9)
        XCTAssertEqual(ParticleField.shortest(2, 10), 2, accuracy: 1e-9)
    }

    /// The trail must never stretch across the whole screen when the field
    /// wraps — that was a visible artefact before `shortest` was applied.
    func testTrailStaysShortAcrossAWrap() {
        var f = ParticleField()
        var worst = 0.0
        for _ in 0..<600 {
            f.update(motion: VehicleMotion(forward: 0.35, lateral: 0.25, vertical: 0,
                                           yawRate: 0.3, timestamp: 0),
                     settings: settings, dt: 1.0 / 60.0)
            f.forEachParticle(viewport: viewport, settings: settings) { p in
                worst = max(worst, hypot(p.position.x - p.previous.x, p.position.y - p.previous.y))
            }
        }
        XCTAssertLessThan(worst, 160, "a trail spanned \(worst) pt — the wrap leaked into it")
    }

    /// The field must not jump when the offset wraps.
    ///
    /// This is a regression test for a real, shipped glitch. Alternate rows are
    /// staggered by half a cell and alternate planes by a quarter, so the
    /// lattice only repeats after *two* cells — but the offset was wrapped
    /// after one. Every wrap therefore flipped the stagger and teleported half
    /// the field sideways by tens of points, several times a minute. It reads
    /// as the whole overlay stuttering.
    ///
    /// Detected without needing particle identity: for each particle, the
    /// distance to the nearest particle of the previous frame. Continuous
    /// motion keeps that at roughly one frame of travel; a stagger flip puts
    /// every affected particle midway between two old ones. The median is used
    /// so that particles legitimately fading in or out cannot mask it.
    func testTheFieldDoesNotJumpWhenItWraps() {
        var f = ParticleField()
        // Forward acceleration drives the z offset, which wraps every 400 pt —
        // about every six seconds here, so ten seconds covers several wraps.
        let motion = VehicleMotion(forward: 0.3, lateral: 0, vertical: 0, yawRate: 0, timestamp: 0)

        // Restricted to a band down the left edge purely to keep this O(n²)
        // comparison small; the stagger is global, so a jump shows up anywhere.
        let band = CGRect(x: 0, y: 0, width: 220, height: viewport.height)
        func sample() -> [CGPoint] {
            var points: [CGPoint] = []
            f.forEachParticle(viewport: viewport, settings: settings) { p in
                if band.contains(p.position) { points.append(p.position) }
            }
            return points
        }

        for _ in 0..<120 { f.update(motion: motion, settings: settings, dt: 1.0 / 60.0) }
        var previous = sample()
        var worstMedian = 0.0

        for _ in 0..<600 {
            f.update(motion: motion, settings: settings, dt: 1.0 / 60.0)
            let current = sample()
            guard current.count > 8, previous.count > 8 else { previous = current; continue }

            var nearest: [Double] = []
            nearest.reserveCapacity(current.count)
            for p in current {
                var best = Double.greatestFiniteMagnitude
                for q in previous {
                    best = min(best, Double(hypot(p.x - q.x, p.y - q.y)))
                }
                nearest.append(best)
            }
            nearest.sort()
            worstMedian = max(worstMedian, nearest[nearest.count / 2])
            previous = current
        }

        // One frame of travel is a couple of points. Half a row's stagger is 54,
        // a quarter of a plane's is 27; 12 leaves ample headroom for the former
        // and none for the latter.
        XCTAssertLessThan(worstMedian, 12,
                          "the field teleported by \(worstMedian) pt between two frames")
    }
}

// MARK: - Shader

final class ShaderTests: XCTestCase {
    /// The shader is compiled from source at launch, so a syntax error would
    /// otherwise only show up as a silently missing overlay.
    func testShaderCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device on this machine")
        }
        let library = try device.makeLibrary(source: ParticleShaders.source, options: nil)
        XCTAssertNotNil(library.makeFunction(name: "particle_vertex"))
        XCTAssertNotNil(library.makeFunction(name: "particle_fragment"))
    }

    func testRendererBuildsItsPipeline() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("no Metal device on this machine")
        }
        XCTAssertNotNil(MetalDotRenderer(), "the render pipeline failed to build")
    }
}
