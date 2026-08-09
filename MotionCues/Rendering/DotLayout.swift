//
//  DotLayout.swift
//
//  Where the dots live at rest, and how vehicle acceleration turns into screen
//  displacement.
//
//  The mapping is the whole point of the app, so it is worth being explicit
//  about the physics.
//
//  A loose object on the dashboard does not move in the direction the car
//  accelerates — it appears to move *opposite* to it, because it keeps its
//  velocity while the car changes. That apparent motion is exactly what your
//  vestibular system reports. So the dots follow the pseudo-force  f = −a :
//
//      car accelerates forward   → dots slide DOWN  (backwards, "into" you)
//      car brakes                → dots slide UP    (forwards)
//      car turns LEFT            → dots slide RIGHT
//      car turns RIGHT           → dots slide LEFT
//      car goes over a crest     → dots slide DOWN slightly
//
//  Screen axes here are AppKit's: +x right, +y up.
//  Vehicle axes are: +x forward, +y left, +z up.
//
//      screenX = +gain * lateral
//      screenY = -gain * forward
//

import Foundation
import CoreGraphics

/// Which edge a dot belongs to. It decides which axis the dot streams along
/// (the one parallel to its own edge, where there is room) and which axis is
/// a bounded excursion (the one pointing off-screen).
enum DotEdge {
    case left, right, top, bottom
    var isVertical: Bool { self == .left || self == .right }
}

struct DotPosition {
    var home: CGPoint
    var edge: DotEdge
    /// Half the length of the run this dot roams along its edge, in points.
    var band: Double
    /// How far the dot may move across its edge before it would leave the
    /// screen: (towards negative, towards positive) on the across axis.
    var acrossRoom: (negative: Double, positive: Double)
    /// 0.85…1.15, a small deterministic per-dot gain so the field breathes
    /// instead of sliding as one rigid slab.
    var gainScale: Double
    /// 0.85…1.0, per-dot spring stiffness scale for a subtle stagger.
    var springScale: Double
}

enum DotLayout {
    /// Home positions in the view's coordinate space (points, origin
    /// bottom-left, as AppKit gives us).
    static func positions(in size: CGSize, settings: RenderSettings) -> [DotPosition] {
        var result: [DotPosition] = []
        let n = max(2, min(40, settings.dotsPerEdge))
        let inset = settings.edgeInset

        // Keep a dot's whole body on screen when it is at its excursion limit.
        let margin = settings.dotDiameter

        func column(x: CGFloat, edge: DotEdge) {
            // Spread over the middle 80% of the edge; the extreme corners are
            // where the eye is least sensitive and where menu bars live.
            let usable = size.height * 0.8
            let start = (size.height - usable) / 2
            for i in 0..<n {
                let t = n == 1 ? 0.5 : Double(i) / Double(n - 1)
                let y = start + usable * t
                result.append(make(CGPoint(x: x, y: y), index: result.count,
                                   edge: edge, band: Double(usable) / 2,
                                   room: (max(0, Double(x) - margin),
                                          max(0, Double(size.width - x) - margin))))
            }
        }

        func row(y: CGFloat, edge: DotEdge) {
            let usable = size.width * 0.8
            let start = (size.width - usable) / 2
            for i in 0..<n {
                let t = n == 1 ? 0.5 : Double(i) / Double(n - 1)
                let x = start + usable * t
                result.append(make(CGPoint(x: x, y: y), index: result.count,
                                   edge: edge, band: Double(usable) / 2,
                                   room: (max(0, Double(y) - margin),
                                          max(0, Double(size.height - y) - margin))))
            }
        }

        column(x: inset, edge: .left)
        column(x: size.width - inset, edge: .right)

        if settings.placement == .sidesAndTopBottom {
            row(y: inset, edge: .bottom)
            row(y: size.height - inset, edge: .top)
        }

        return result
    }

    private static func make(_ point: CGPoint, index: Int, edge: DotEdge,
                             band: Double,
                             room: (negative: Double, positive: Double)) -> DotPosition {
        // Deterministic pseudo-random variation — same layout every launch.
        let h = Double((index &* 2_654_435_761) % 1000) / 1000.0
        let h2 = Double((index &* 40_503 &+ 17) % 1000) / 1000.0
        return DotPosition(home: point,
                           edge: edge,
                           band: band,
                           acrossRoom: room,
                           gainScale: 0.85 + 0.3 * h,
                           springScale: 0.85 + 0.15 * h2)
    }

    /// Vehicle acceleration → screen offset in points.
    static func offset(for motion: VehicleMotion, settings: RenderSettings) -> CGPoint {
        let x = settings.gain * motion.lateral
        var y = -settings.gain * motion.forward
        if settings.verticalCues {
            // Vertical acceleration also reads as apparent downward motion,
            // but it is a much smaller and much noisier channel, so it only
            // gets a third of the gain.
            y += -settings.gain * 0.33 * motion.vertical
        }
        return CGPoint(x: clamp(x), y: clamp(y))
    }

    /// Hard travel limit so a pothole spike can never fling a dot across the
    /// screen. 1.6 g of longitudinal acceleration is already beyond anything a
    /// road car does.
    private static func clamp(_ v: Double) -> CGFloat {
        CGFloat(max(-140, min(140, v)))
    }
}
