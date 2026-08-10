//
//  ParticleField.swift
//
//  The cue, rebuilt as a three-dimensional field of particles.
//
//  WHY THIS REPLACED THE PREVIOUS MODEL
//
//  Version 1 offset dots in proportion to instantaneous acceleration. Too
//  weak: a firm brake is 0.3 g, twenty-odd points of travel, invisible in
//  peripheral vision.
//
//  Version 2 made drift *speed* proportional to acceleration, which was much
//  better, but it was still a flat field sliding around, and it had an
//  awkward asymmetry: dots could stream freely along an edge but had almost
//  no room across it, so cornering had to be a bounded excursion that
//  saturated. That asymmetry was a symptom of the model being wrong, not of
//  the screen being small.
//
//  This version fixes the underlying mistake. Forward motion does not look
//  like things sliding downwards — it looks like the world *expanding* past
//  you, radially, away from the point you are heading towards. That is the
//  actual optic-flow signature of translation, and it is what the visual
//  system is tuned to. So the field has depth, the particles are projected
//  through a pinhole, and accelerating pushes the field towards the viewer:
//  particles spread outwards from the centre and grow, braking pulls them
//  back in, and cornering slides the whole field sideways.
//
//  Because the grid wraps in all three axes, there is no edge to run out of
//  and no excursion to bound. The asymmetry is simply gone.
//
//  THE INTEGRATION
//
//  Acceleration is integrated to a velocity, and velocity to a position, with
//  a friction term whose strength depends on how much acceleration there
//  currently is. Standing still, friction is high and the field comes to a
//  complete stop, which is the hard requirement: a parked car must show a
//  static field. Under sustained acceleration friction drops and the flow
//  builds and persists. That is a leaky double integration, and it behaves
//  like a physical body rather than like a number being multiplied.
//
//  Independently reimplemented. The idea of a wrapping 3-D particle grid with
//  perspective, motion trails and paired light/dark dots is one I took from
//  reading Kalabasa's EasyQueasy (Android, GPL-3.0); none of its code is used
//  here.
//

import Foundation
import simd
import CoreGraphics

/// One particle, already projected to screen space.
struct Particle {
    var position: CGPoint
    /// Where it was on the previous frame, for the motion trail.
    var previous: CGPoint
    var radius: Double
    /// 0…1, before the global opacity setting is applied.
    var alpha: Double
}

/// Wrapping 3-D grid of particles, in *screen-ish* units: x and y are points,
/// z is points of depth behind the glass.
struct ParticleField {
    // MARK: Geometry

    /// Spacing of the grid in points. y is derived so the lattice is roughly
    /// hexagonal, which looks less like graph paper than a square grid.
    var cellX: Double = 108
    /// Depth spacing. Kept coarse on purpose: with planes close together the
    /// field reads as speckle rather than structure, and a boundary between
    /// two planes shows up as a visible seam.
    var cellZ: Double = 200
    /// How deep the field extends behind the screen. Two or three planes is
    /// enough to sell depth; more is just noise.
    var depth: Double = 420
    /// Distance from the eye to the glass. Sets how strong the perspective is.
    var eye: Double = 950

    var cellY: Double { cellX * 2 * 3.0.squareRoot() / 3.0 }

    // The lattice is periodic, and the field's offset is wrapped into one
    // period so the numbers stay small. Getting the period wrong does not look
    // like drift — it looks like a glitch.
    //
    // Alternate *rows* are staggered by half a cell in x, and alternate
    // *planes* by a quarter. So the pattern only repeats after TWO cells in y
    // and two in z, not one. Wrapping by a single cell (which is what this did
    // originally) flips the stagger every time it wraps, and the entire field
    // jumps sideways by half a cell — about 54 points, instantaneously, every
    // 250 points of vertical travel. That is the "buggy" jitter.
    var periodX: Double { cellX }
    var periodY: Double { cellY * 2 }
    var periodZ: Double { cellZ * 2 }

    // MARK: State

    /// Where the field currently is, in points. Wrapped into one cell.
    private(set) var offset = SIMD3<Double>(repeating: 0)
    /// Field velocity in points per second.
    private(set) var velocity = SIMD3<Double>(repeating: 0)
    /// Previous offset, so the renderer can draw a trail.
    private(set) var previousOffset = SIMD3<Double>(repeating: 0)
    /// 0…1. Rises when there is motion worth showing, decays to nothing when
    /// there is not, and scales both size and opacity.
    private(set) var intensity: Double = 0

    init() {}

    mutating func reset() {
        offset = .init(repeating: 0)
        velocity = .init(repeating: 0)
        previousOffset = .init(repeating: 0)
        intensity = 0
    }

    // MARK: Update

    /// - Parameter settings: `flowGain` scales acceleration into the field's
    ///   response; everything else here is fixed geometry.
    mutating func update(motion: VehicleMotion, settings: RenderSettings, dt: Double) {
        guard dt > 0, dt < 0.5 else { return }

        // Vehicle acceleration → field acceleration, following the
        // pseudo-force: the field moves the way a loose object in the cabin
        // would.
        //
        //   forward  → field comes towards the viewer (+z) → radial expansion
        //   left     → field slides right (+x)
        //   up       → field slides down (−y); screen +y is up
        let g = settings.flowGain
        var accel = SIMD3<Double>(g * motion.lateral,
                                  settings.verticalCues ? -g * 0.33 * motion.vertical : 0,
                                  g * motion.forward)

        // A pothole must not fling the whole field.
        let cap = g * 1.2
        let mag = simd_length(accel)
        if mag > cap, mag > 0 { accel *= cap / mag }

        velocity += accel * dt

        // Adaptive friction. Strong when nothing is happening, so the field
        // parks itself; weak under sustained acceleration, so flow builds.
        let planar = (accel.x * accel.x + accel.z * accel.z).squareRoot()
        let damping = 1.6 + 9.0 / (1.0 + planar * 0.02)
        velocity *= 1.0 / (1.0 + dt * damping)

        previousOffset = offset
        offset += velocity * dt

        // Wrap into a single cell in each axis. Everything downstream is
        // periodic, so this keeps the numbers small and the field seamless.
        offset.x = Self.wrap(offset.x, periodX)
        offset.y = Self.wrap(offset.y, periodY)
        offset.z = Self.wrap(offset.z, periodZ)

        // Keep the trail short and continuous across a wrap.
        previousOffset.x = offset.x - Self.shortest(offset.x - previousOffset.x, periodX)
        previousOffset.y = offset.y - Self.shortest(offset.y - previousOffset.y, periodY)
        previousOffset.z = offset.z - Self.shortest(offset.z - previousOffset.z, periodZ)

        // Intensity follows speed, not acceleration: it should stay up through
        // a long steady corner, and fall away when the car actually settles.
        //
        // A sigmoid is wrong here however steep it is, because it never
        // reaches zero — an earlier version floored at 0.39 and would have
        // left the overlay permanently visible on a parked car, which is the
        // one thing this must never do. `smoothstep` is exactly zero below its
        // lower bound.
        let speed = simd_length(velocity)
        let target = Self.smoothstep(6, 45, speed)
        let rate = target > intensity ? 5.0 : 0.9   // quick to appear, slow to leave
        intensity += (target - intensity) * min(1, dt * rate)
    }

    // MARK: Projection

    /// Projects the wrapping grid into screen space for one viewport.
    ///
    /// - Parameter body: called once per visible particle. Called rather than
    ///   returning an array so the render loop allocates nothing.
    func forEachParticle(viewport: CGSize,
                         settings: RenderSettings,
                         _ body: (Particle) -> Void) {
        guard intensity > 0.002, viewport.width > 1, viewport.height > 1 else { return }

        let w = Double(viewport.width), h = Double(viewport.height)
        let cx = w / 2, cy = h / 2

        // How far the grid must extend past the glass to still cover the
        // screen once the nearest plane is magnified by perspective.
        //
        // The +2 / +4 slack is not cosmetic: `offset` is wrapped into a whole
        // period, which is two cells in y and z, so the indices have to reach
        // two cells further than the viewport alone would suggest or particles
        // vanish at one edge of the screen while the offset is in the upper
        // half of its period.
        let nearScale = eye / max(eye - depth, 1)
        let marginX = Int((w * nearScale / cellX).rounded(.up)) / 2 + 2
        let marginY = Int((h * nearScale / cellY).rounded(.up)) / 2 + 4
        let planes = Int((depth / cellZ).rounded(.up)) + 1

        let baseRadius = settings.dotDiameter / 2
        let periphery = settings.peripherySize * (0.35 + 0.65 * intensity)

        for iz in -1...(planes + 2) {
            // Depth of this plane, in front of the far wall.
            let z = Double(iz) * cellZ - offset.z
            guard z > -cellZ, z < depth + cellZ else { continue }
            let scale = eye / max(eye + z, 1)
            let previousScale = eye / max(eye + z + (offset.z - previousOffset.z), 1)

            // Fade planes in as they appear at the back and out as they pass
            // the glass, so nothing pops.
            let depthFade = Self.smoothstep(0, cellZ, z + cellZ) * Self.smoothstep(0, cellZ, depth - z)
            guard depthFade > 0.004 else { continue }

            for ix in -marginX...marginX {
                for iy in -marginY...marginY {
                    // Stagger alternate rows and planes so the lattice is
                    // hexagonal rather than square.
                    let stagger = (iy & 1 == 0 ? 0.0 : 0.5) + (iz & 1 == 0 ? 0.0 : 0.25)
                    let wx = (Double(ix) + stagger) * cellX + offset.x
                    let wy = Double(iy) * cellY + offset.y

                    let px = cx + wx * scale
                    let py = cy + wy * scale
                    guard px > -40, px < w + 40, py > -40, py < h + 40 else { continue }

                    // Peripheral falloff: the middle of the screen is where
                    // you are trying to read, so the cue lives at the edges.
                    let edge = Self.edgeDistance(x: px, y: py, width: w, height: h)
                    // Cubed, and cut off well above zero.
                    //
                    // A square law still leaves ~7 % alpha halfway to the
                    // middle of the screen, and a 2 % cut-off keeps it. Several
                    // hundred faint dots scattered over the text is what made
                    // this read as a rendering fault rather than as a cue —
                    // and it defeats the entire point of a *peripheral* cue,
                    // which is that the middle stays clear enough to read.
                    //
                    // Cubed with a 0.05 floor confines the field to the outer
                    // ~55 % of `peripherySize`: a band, with a clean inner edge.
                    let linear = 1 - Self.smoothstep(0, periphery, edge)
                    let peripheral = linear * linear * linear
                    let alpha = peripheral * depthFade * intensity
                    guard alpha > 0.05 else { continue }

                    let prevX = cx + (wx - (offset.x - previousOffset.x)) * previousScale
                    let prevY = cy + (wy - (offset.y - previousOffset.y)) * previousScale

                    body(Particle(position: CGPoint(x: px, y: py),
                                  previous: CGPoint(x: prevX, y: prevY),
                                  radius: baseRadius * scale * (0.55 + 0.45 * intensity),
                                  alpha: alpha))
                }
            }
        }
    }

    // MARK: Maths

    /// Distance from the nearest screen edge.
    static func edgeDistance(x: Double, y: Double, width: Double, height: Double) -> Double {
        min(min(x, width - x), min(y, height - y))
    }

    static func wrap(_ v: Double, _ period: Double) -> Double {
        guard period > 0 else { return v }
        let r = v.truncatingRemainder(dividingBy: period)
        return r < 0 ? r + period : r
    }

    /// The representative of `delta` closest to zero, modulo `period`.
    static func shortest(_ delta: Double, _ period: Double) -> Double {
        guard period > 0 else { return delta }
        var d = delta.truncatingRemainder(dividingBy: period)
        if d > period / 2 { d -= period }
        if d < -period / 2 { d += period }
        return d
    }

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        guard b > a else { return x >= b ? 1 : 0 }
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}
