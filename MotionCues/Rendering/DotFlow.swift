//
//  DotFlow.swift
//
//  The motion model behind each dot.
//
//  The first version only offset each dot from a fixed home position, in
//  proportion to instantaneous acceleration. That is a weak cue: a firm brake
//  is 0.3 g, which at the High setting is about 24 points of travel, and 24
//  points of displacement that then springs back is close to invisible in
//  peripheral vision — which is exactly where these dots live.
//
//  What the visual system responds to is **optic flow**: sustained motion
//  across the visual field. So the dominant term is not displacement but
//  *velocity*. A dot's drift speed is proportional to the vehicle's
//  acceleration, which gives:
//
//    * standing still  → no acceleration → no flow at all, so the field is
//      genuinely static at rest;
//    * a sustained brake → continuous drift for as long as it lasts, rather
//      than one small hop;
//    * harder braking → faster flow, not merely further.
//
//  Integrating acceleration gives a change in velocity, and flow speed is what
//  the eye reads as "I am moving". Matching flow speed to Δv is a closer
//  analogue of what the inner ear reports than matching displacement to
//  acceleration is.
//
//  THE TWO AXES ARE NOT SYMMETRIC, deliberately:
//
//  * **Longitudinal** (accelerating / braking) drives motion *along* the edge
//    columns, where there is a whole screen height of room. Dots stream up or
//    down continuously, fading out at the end of the column and reappearing at
//    the other end. The flow never runs out and never leaves a gap.
//
//  * **Lateral** (cornering) drives motion *across* the columns, where there
//    is almost no room — a dot 40 points from the left edge can only go 40
//    points left before it is off the screen. So lateral motion is a bounded
//    excursion that saturates smoothly and decays back to the edge when the
//    corner ends, rather than a wrapping flow. An earlier version let it drift
//    freely and the right-hand column simply vanished off-screen for about a
//    second during any sustained turn.
//

import Foundation
import CoreGraphics

/// One dot's drift state. Positions are relative to the dot's home.
struct DotFlowState {
    /// Distance travelled along the column, in points. Wraps within the band.
    private(set) var along: Double = 0
    /// Excursion across the column, in points. Bounded, and decays back.
    private(set) var across: Double = 0
    /// Deterministic per-dot offset so the field does not fade in lockstep.
    let phase: Double

    init(phase: Double) { self.phase = phase }

    mutating func reset() {
        along = 0
        across = 0
    }

    /// - Parameters:
    ///   - alongSpeed: points per second along the column (screen +y is up).
    ///   - acrossSpeed: points per second across it.
    ///   - band: half the length of the run the dot may roam along its edge.
    ///   - acrossLimit: maximum excursion across it — already reduced to the
    ///     room this particular dot has, so nothing leaves the screen.
    mutating func step(alongSpeed: Double, acrossSpeed: Double,
                       band: Double, acrossLimit: Double,
                       acrossLimitNegative: Double, dt: Double) {
        guard band > 1 else { return }

        along += alongSpeed * dt
        // Wrap: leaving one end of the column brings the dot back at the
        // other, so a long manoeuvre keeps producing flow with no gap.
        let span = band * 2
        while along > band { along -= span }
        while along < -band { along += span }

        // Across: integrate, saturate smoothly, and relax back to the edge so
        // a finished corner does not leave the field permanently displaced.
        across += acrossSpeed * dt
        across -= across * min(1, dt / 1.8)
        // Saturate towards whichever limit this dot is heading for. The two
        // are not equal: a dot 40 points from the left edge has 40 points of
        // room to its left and most of the screen to its right.
        let limit = across >= 0 ? acrossLimit : acrossLimitNegative
        across = limit > 1e-6 ? limit * tanh(across / limit) : 0
    }

    /// Opacity multiplier. Full through the middle of the column, easing to
    /// zero at both ends so the wrap is never seen.
    func envelope(band: Double) -> Double {
        guard band > 1 else { return 1 }
        // Per-dot variation in the fade zone, so they do not blink together.
        let zone = band * (0.20 + 0.10 * phase)
        let remaining = band - abs(along)
        guard remaining < zone else { return 1 }
        let t = max(0, remaining / zone)
        return t * t * (3 - 2 * t)   // smoothstep
    }

    var offset: CGPoint { CGPoint(x: across, y: along) }
}

enum DotFlow {
    /// Drift speed in points per second for a given vehicle motion.
    ///
    /// Direction follows the pseudo-force, identical to `DotLayout.offset` —
    /// the way a loose object on the dashboard moves. Only the magnitude is
    /// interpreted differently: as a speed rather than a displacement.
    ///
    /// - Returns: (along the column, across it). Screen +y is up, +x is right.
    static func speed(for motion: VehicleMotion, settings: RenderSettings) -> (along: Double, across: Double) {
        var along = -settings.flowGain * motion.forward
        if settings.verticalCues {
            along += -settings.flowGain * 0.33 * motion.vertical
        }
        let across = settings.flowGain * motion.lateral

        // Cap so a pothole spike cannot make the whole field jump.
        let cap = settings.flowGain * 0.8
        return (clamp(along, cap), clamp(across, cap))
    }

    private static func clamp(_ v: Double, _ limit: Double) -> Double {
        max(-limit, min(limit, v))
    }
}
