//
//  MotionCuesTests.swift
//
//  These check the parts that are easy to get quietly, invisibly wrong: the
//  wire format, the attitude convention, the calibration recovery, the filter
//  behaviour, and the direction the dots actually move.
//

import XCTest
import simd
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

// MARK: - Visual mapping

final class DotLayoutTests: XCTestCase {
    private let settings: RenderSettings = {
        var s = RenderSettings()
        s.gain = 48
        s.verticalCues = false
        return s
    }()

    /// Dots follow the pseudo-force, i.e. they move the way a loose object on
    /// the dashboard would. Getting these signs backwards would make the app
    /// actively worse than nothing.
    func testAcceleratingPushesDotsDown() {
        let m = VehicleMotion(forward: 0.2, lateral: 0, vertical: 0, yawRate: 0, timestamp: 0)
        XCTAssertLessThan(DotLayout.offset(for: m, settings: settings).y, 0)
    }

    func testBrakingPushesDotsUp() {
        let m = VehicleMotion(forward: -0.2, lateral: 0, vertical: 0, yawRate: 0, timestamp: 0)
        XCTAssertGreaterThan(DotLayout.offset(for: m, settings: settings).y, 0)
    }

    func testTurningLeftPushesDotsRight() {
        // +lateral = accelerating leftwards = a left turn.
        let m = VehicleMotion(forward: 0, lateral: 0.2, vertical: 0, yawRate: 0.3, timestamp: 0)
        XCTAssertGreaterThan(DotLayout.offset(for: m, settings: settings).x, 0)
    }

    func testTurningRightPushesDotsLeft() {
        let m = VehicleMotion(forward: 0, lateral: -0.2, vertical: 0, yawRate: -0.3, timestamp: 0)
        XCTAssertLessThan(DotLayout.offset(for: m, settings: settings).x, 0)
    }

    func testTravelIsClamped() {
        let violent = VehicleMotion(forward: 40, lateral: -40, vertical: 0, yawRate: 0, timestamp: 0)
        let offset = DotLayout.offset(for: violent, settings: settings)
        XCTAssertLessThanOrEqual(abs(offset.x), 140)
        XCTAssertLessThanOrEqual(abs(offset.y), 140)
    }

    func testDotCountMatchesPlacement() {
        var s = RenderSettings()
        s.dotsPerEdge = 8
        s.placement = .sides
        XCTAssertEqual(DotLayout.positions(in: CGSize(width: 1440, height: 900), settings: s).count, 16)
        s.placement = .sidesAndTopBottom
        XCTAssertEqual(DotLayout.positions(in: CGSize(width: 1440, height: 900), settings: s).count, 32)
    }

    func testDotsStayInsideTheScreen() {
        var s = RenderSettings()
        s.dotsPerEdge = 10
        s.edgeInset = 30
        s.placement = .sidesAndTopBottom
        let size = CGSize(width: 1440, height: 900)
        for p in DotLayout.positions(in: size, settings: s) {
            XCTAssertTrue((0...size.width).contains(p.home.x))
            XCTAssertTrue((0...size.height).contains(p.home.y))
        }
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

// MARK: - Flow model

/// The flow model is the dominant cue, so its properties matter more than the
/// instantaneous offset's: silent at rest, continuous under a sustained
/// manoeuvre, never a gap, and never a dot stranded off-screen.
final class DotFlowTests: XCTestCase {
    private var settings: RenderSettings {
        var s = RenderSettings()
        s.flowGain = 620
        s.flowAcrossLimit = 90
        s.verticalCues = false
        return s
    }
    private let band = 380.0        // half of 0.8 × 956 pt, a typical screen

    func testNoFlowAtRest() {
        let v = DotFlow.speed(for: .zero, settings: settings)
        XCTAssertEqual(v.along, 0, accuracy: 1e-9)
        XCTAssertEqual(v.across, 0, accuracy: 1e-9)
    }

    /// Same convention as the static offset: dots follow the pseudo-force.
    func testFlowFollowsThePseudoForce() {
        let accelerating = VehicleMotion(forward: 0.2, lateral: 0, vertical: 0, yawRate: 0, timestamp: 0)
        XCTAssertLessThan(DotFlow.speed(for: accelerating, settings: settings).along, 0)

        let braking = VehicleMotion(forward: -0.2, lateral: 0, vertical: 0, yawRate: 0, timestamp: 0)
        XCTAssertGreaterThan(DotFlow.speed(for: braking, settings: settings).along, 0)

        let left = VehicleMotion(forward: 0, lateral: 0.2, vertical: 0, yawRate: 0.3, timestamp: 0)
        XCTAssertGreaterThan(DotFlow.speed(for: left, settings: settings).across, 0)
    }

    func testFlowSpeedIsCapped() {
        let violent = VehicleMotion(forward: 12, lateral: -12, vertical: 0, yawRate: 0, timestamp: 0)
        let v = DotFlow.speed(for: violent, settings: settings)
        XCTAssertLessThanOrEqual(abs(v.along), settings.flowGain * 0.8 + 1e-6)
        XCTAssertLessThanOrEqual(abs(v.across), settings.flowGain * 0.8 + 1e-6)
    }

    /// The whole point: a dot must keep moving under a sustained brake instead
    /// of hopping once and stopping.
    func testSustainedBrakingKeepsProducingFlow() {
        var flow = DotFlowState(phase: 0.5)
        var travelled = 0.0
        var wraps = 0
        var previous = flow.offset.y

        for _ in 0..<300 {              // 5 s at 60 fps
            flow.step(alongSpeed: 200, acrossSpeed: 0, band: band,
                      acrossLimit: settings.flowAcrossLimit,
                      acrossLimitNegative: settings.flowAcrossLimit, dt: 1.0 / 60.0)
            let y = Double(flow.offset.y)
            if y < previous { wraps += 1 } else { travelled += y - previous }
            previous = y
        }
        // 5 s at 200 pt/s is 1000 pt of flow; the column is 760 pt, so it must
        // have wrapped at least once and kept going.
        XCTAssertGreaterThan(wraps, 0, "flow ran out instead of wrapping")
        XCTAssertGreaterThan(travelled + Double(wraps) * band * 2, 900)
    }

    /// The wrap must happen while the dot is invisible.
    func testDotIsInvisibleWhenItWraps() {
        var flow = DotFlowState(phase: 0.0)
        var previous = Double(flow.offset.y)
        for _ in 0..<600 {
            flow.step(alongSpeed: 200, acrossSpeed: 0, band: band,
                      acrossLimit: settings.flowAcrossLimit,
                      acrossLimitNegative: settings.flowAcrossLimit, dt: 1.0 / 60.0)
            let y = Double(flow.offset.y)
            if y < previous {           // just wrapped
                XCTAssertLessThan(flow.envelope(band: band), 0.05,
                                  "the dot jumped while still visible")
                return
            }
            previous = y
        }
        XCTFail("never wrapped")
    }

    /// A dot must never end up further sideways than the screen allows —
    /// letting it drift freely made the right-hand column disappear.
    func testLateralExcursionIsBounded() {
        var flow = DotFlowState(phase: 0.4)
        for _ in 0..<1200 {             // 20 s of hard, sustained cornering
            flow.step(alongSpeed: 0, acrossSpeed: 400, band: band,
                      acrossLimit: settings.flowAcrossLimit,
                      acrossLimitNegative: settings.flowAcrossLimit, dt: 1.0 / 60.0)
        }
        XCTAssertLessThanOrEqual(Double(flow.offset.x), settings.flowAcrossLimit + 1e-6)
        XCTAssertGreaterThan(Double(flow.offset.x), settings.flowAcrossLimit * 0.5,
                             "the excursion should saturate near the limit, not collapse")
    }

    /// When the corner ends the field must come home, not stay displaced.
    func testLateralExcursionDecaysBack() {
        var flow = DotFlowState(phase: 0.4)
        for _ in 0..<300 {
            flow.step(alongSpeed: 0, acrossSpeed: 400, band: band,
                      acrossLimit: settings.flowAcrossLimit,
                      acrossLimitNegative: settings.flowAcrossLimit, dt: 1.0 / 60.0)
        }
        XCTAssertGreaterThan(Double(flow.offset.x), 40)
        for _ in 0..<600 {              // 10 s straight afterwards
            flow.step(alongSpeed: 0, acrossSpeed: 0, band: band,
                      acrossLimit: settings.flowAcrossLimit,
                      acrossLimitNegative: settings.flowAcrossLimit, dt: 1.0 / 60.0)
        }
        XCTAssertLessThan(abs(Double(flow.offset.x)), 2, "the field never returned to the edge")
    }

    /// The real bug this replaced: with a uniform sideways limit, the column
    /// nearest the direction of drift walked straight off the screen.
    func testExcursionRespectsTheRoomTheDotActuallyHas() {
        var flow = DotFlowState(phase: 0.4)
        // A dot 40 pt from the left edge: plenty of room right, almost none left.
        for _ in 0..<900 {
            flow.step(alongSpeed: 0, acrossSpeed: -400, band: band,
                      acrossLimit: 90, acrossLimitNegative: 25, dt: 1.0 / 60.0)
        }
        XCTAssertGreaterThanOrEqual(Double(flow.offset.x), -25 - 1e-6,
                                    "the dot walked off the near edge")
    }

    func testDotLayoutGivesEdgeDotsTheirRealRoom() {
        var s = RenderSettings()
        s.dotsPerEdge = 4
        s.edgeInset = 40
        s.dotDiameter = 10
        let size = CGSize(width: 1470, height: 956)
        let dots = DotLayout.positions(in: size, settings: s)

        let left = try! XCTUnwrap(dots.first { $0.edge == .left })
        XCTAssertEqual(left.acrossRoom.negative, 30, accuracy: 0.001)   // 40 − 10
        XCTAssertGreaterThan(left.acrossRoom.positive, 1000)

        let right = try! XCTUnwrap(dots.first { $0.edge == .right })
        XCTAssertEqual(right.acrossRoom.positive, 30, accuracy: 0.001)
        XCTAssertGreaterThan(right.acrossRoom.negative, 1000)

        // Side dots stream vertically; top/bottom dots stream horizontally.
        XCTAssertTrue(left.edge.isVertical)
        s.placement = .sidesAndTopBottom
        let all = DotLayout.positions(in: size, settings: s)
        XCTAssertFalse(try! XCTUnwrap(all.first { $0.edge == .top }).edge.isVertical)
    }

    /// A parked car must not shimmer.
    func testRestIsStaticAndFullyVisible() {
        var flow = DotFlowState(phase: 0.3)
        for _ in 0..<600 {
            flow.step(alongSpeed: 0, acrossSpeed: 0, band: band,
                      acrossLimit: settings.flowAcrossLimit,
                      acrossLimitNegative: settings.flowAcrossLimit, dt: 1.0 / 60.0)
        }
        XCTAssertEqual(Double(flow.offset.y), 0, accuracy: 1e-9)
        XCTAssertEqual(Double(flow.offset.x), 0, accuracy: 1e-9)
        XCTAssertEqual(flow.envelope(band: band), 1.0, accuracy: 1e-9)
    }

    /// Dots must not all fade on the same frame, or the field strobes.
    func testFadingIsStaggeredAcrossDots() {
        var flows = (0..<14).map { DotFlowState(phase: Double(($0 &* 7919) % 1000) / 1000.0) }
        var firstFadeFrame: [Int: Int] = [:]
        for frame in 0..<600 {
            for i in flows.indices {
                flows[i].step(alongSpeed: 150, acrossSpeed: 0, band: band,
                              acrossLimit: settings.flowAcrossLimit,
                      acrossLimitNegative: settings.flowAcrossLimit, dt: 1.0 / 60.0)
                if flows[i].envelope(band: band) < 0.5, firstFadeFrame[i] == nil {
                    firstFadeFrame[i] = frame
                }
            }
        }
        XCTAssertEqual(firstFadeFrame.count, flows.count, "some dots never faded")
        XCTAssertGreaterThan(Set(firstFadeFrame.values).count, 5,
                             "dots faded in lockstep — the field would strobe")
    }
}
