//
//  DotRenderer.swift
//
//  One CALayer per dot, positions written inside a CATransaction with implicit
//  animation disabled, driven by a display link.
//
//  Why CALayer and not Metal: with 16–80 small circles the entire per-frame
//  cost is writing `position` on a handful of layers — well under 0.1 ms, and
//  the WindowServer composites them on the GPU anyway. A Metal pipeline would
//  add a device, a command queue and a drawable dance for no measurable win.
//  `DotRendering` exists so a Metal implementation can slot in later if the
//  dot count ever grows by an order of magnitude.
//
//  Why not SwiftUI: it would mean invalidating a view hierarchy at up to
//  120 Hz. The renderer instead pulls the latest state at vsync and writes
//  layer geometry directly. SwiftUI is used only for the menu and the settings
//  window, which change at human speed.
//

import AppKit
import QuartzCore

protocol DotRendering: AnyObject {
    func configure(settings: RenderSettings, size: CGSize, scale: CGFloat, isDark: Bool)
    func render(motion: VehicleMotion, dt: Double)
}

final class LayerDotRenderer: DotRendering {
    private let root: CALayer
    private var dotLayers: [CALayer] = []
    private var positions: [DotPosition] = []
    private var springsX: [SpringFollower] = []
    private var springsY: [SpringFollower] = []
    private var flows: [DotFlowState] = []

    private var settings = RenderSettings()
    private var currentOpacity: Double = 0

    init(root: CALayer) {
        self.root = root
    }

    func configure(settings: RenderSettings, size: CGSize, scale: CGFloat, isDark: Bool) {
        self.settings = settings
        positions = DotLayout.positions(in: size, settings: settings)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Grow or shrink the layer pool rather than rebuilding it.
        while dotLayers.count < positions.count {
            let layer = CALayer()
            layer.actions = ["position": NSNull(), "opacity": NSNull(),
                             "bounds": NSNull(), "transform": NSNull()]
            layer.shadowOpacity = 1
            layer.shadowRadius = 3
            layer.shadowOffset = .zero
            root.addSublayer(layer)
            dotLayers.append(layer)
        }
        while dotLayers.count > positions.count {
            dotLayers.removeLast().removeFromSuperlayer()
        }

        springsX = positions.map { SpringFollower(omega: settings.springOmega * $0.springScale) }
        springsY = positions.map { SpringFollower(omega: settings.springOmega * $0.springScale) }
        // Stagger the fade phase deterministically so the field never recycles
        // as one block.
        flows = positions.enumerated().map { i, _ in
            DotFlowState(phase: Double((i &* 7919) % 1000) / 1000.0)
        }


        let d = CGFloat(settings.dotDiameter)
        let useLight: Bool
        switch settings.appearance {
        case .automatic: useLight = isDark
        case .light: useLight = false   // dark dots on light backgrounds
        case .dark: useLight = true     // light dots on dark backgrounds
        }
        let fill = useLight ? NSColor.white : NSColor.black
        // Contrasting halo so the dot survives being over the "wrong"
        // background — we cannot sample the pixels underneath without Screen
        // Recording permission, so we make each dot self-contrasting instead.
        let halo = useLight ? NSColor.black : NSColor.white

        // Giving Core Animation an explicit shadow path stops it deriving the
        // silhouette from the layer's alpha channel on every commit. For a
        // circle we know the answer, so hand it over.
        let circle = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: d, height: d), transform: nil)

        for (i, layer) in dotLayers.enumerated() {
            layer.contentsScale = scale
            layer.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            layer.cornerRadius = d / 2
            layer.backgroundColor = fill.cgColor
            layer.shadowColor = halo.cgColor
            layer.shadowPath = circle
            layer.position = positions[i].home
            layer.opacity = Float(settings.opacity)
        }
        currentOpacity = settings.opacity
    }

    func render(motion: VehicleMotion, dt: Double) {
        guard !dotLayers.isEmpty else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Instantaneous displacement: keeps the field responsive to the very
        // start of a manoeuvre, before drift has had time to accumulate.
        let offset = DotLayout.offset(for: motion, settings: settings)
        // Flow: the dominant cue. See DotFlow.
        let speed = DotFlow.speed(for: motion, settings: settings)
        let emphasis = min(1.0, motion.magnitude / 0.25)

        // Emphasis lifts opacity a little while things are happening, so the
        // dots recede almost completely when the car is standing still.
        let targetOpacity = settings.idleFadeEnabled
            ? settings.opacity * (0.55 + 0.45 * min(1, emphasis))
            : settings.opacity
        currentOpacity += (targetOpacity - currentOpacity) * min(1, dt * 6)

        for i in 0..<dotLayers.count {
            let p = positions[i]

            // Each dot streams along its own edge and is bounded across it,
            // by the room it actually has.
            let vertical = p.edge.isVertical
            let alongSpeed = (vertical ? speed.along : speed.across) * p.gainScale
            let acrossSpeed = (vertical ? speed.across : speed.along) * p.gainScale
            flows[i].step(alongSpeed: alongSpeed,
                          acrossSpeed: acrossSpeed,
                          band: p.band,
                          acrossLimit: min(settings.flowAcrossLimit, p.acrossRoom.positive),
                          acrossLimitNegative: min(settings.flowAcrossLimit, p.acrossRoom.negative),
                          dt: dt)

            let tx = Double(offset.x) * p.gainScale
            let ty = Double(offset.y) * p.gainScale
            let sx = springsX[i].step(target: tx, dt: dt)
            let sy = springsY[i].step(target: ty, dt: dt)

            // `offset` is (across, along); map it back to screen axes.
            let f = flows[i].offset
            let flow = vertical ? CGPoint(x: f.x, y: f.y) : CGPoint(x: f.y, y: f.x)
            let layer = dotLayers[i]
            layer.position = CGPoint(x: p.home.x + flow.x + CGFloat(sx),
                                     y: p.home.y + flow.y + CGFloat(sy))
            layer.opacity = Float(currentOpacity * flows[i].envelope(band: p.band))
        }

        CATransaction.commit()
    }

    /// True when every dot has effectively stopped, so the display link can be
    /// parked until the next non-trivial sample arrives.
    var isSettled: Bool {
        for i in 0..<springsX.count {
            if abs(springsX[i].position) > 0.05 || abs(springsY[i].position) > 0.05 { return false }
            if abs(flows[i].offset.x) > 0.05 || abs(flows[i].offset.y) > 0.05 { return false }
        }
        return true
    }

    /// Send every dot home. Used when the source changes and the accumulated
    /// drift no longer means anything.
    func resetFlow() {
        for i in 0..<flows.count { flows[i].reset() }
    }
}
