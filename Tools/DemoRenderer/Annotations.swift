//
//  Annotations.swift
//
//  Demo-only overlay drawn on top of the real dots.
//
//  None of this exists in the app. It is here because a 24-second clip of
//  small grey dots, compressed and autoplaying at timeline size, does not
//  explain itself: you cannot tell what the dots are, what they are tracking,
//  or that they moved at all.
//
//  Two annotations, both honest:
//
//  * Rest-position ticks. A faint mark at each dot's home position, so the
//    displacement is legible instead of having to be remembered. The dots
//    themselves are not exaggerated — the gain is the app's real High setting,
//    80 pt per g. The ticks give the eye a reference; they do not inflate the
//    motion.
//  * A state panel driven by the *same* `VehicleMotion` the dots are driven
//    by. It cannot disagree with them, because it is the same numbers.
//

import AppKit

enum Annotations {

    // MARK: - Rest-position ticks

    /// A faint ring at each dot's home position.
    static func drawRestMarks(_ positions: [DotPosition], diameter: CGFloat, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        ctx.setLineWidth(1)
        for p in positions {
            let r = diameter * 0.72
            ctx.strokeEllipse(in: CGRect(x: p.home.x - r, y: p.home.y - r, width: r * 2, height: r * 2))
        }
        ctx.restoreGState()
    }

    // MARK: - State panel

    /// Bottom-left panel: what the simulated car is doing right now, in the
    /// same units the engine works in.
    static func drawPanel(motion: VehicleMotion, in ctx: CGContext, canvas: CGSize) {
        // Bottom-centre: the dot columns own both margins, and covering one
        // of them with the explanation would be self-defeating.
        let w: CGFloat = 340, h: CGFloat = 168
        let rect = CGRect(x: (canvas.width - w) / 2, y: 40, width: w, height: h)

        ctx.saveGState()
        let path = CGPath(roundedRect: rect, cornerWidth: 14, cornerHeight: 14, transform: nil)
        ctx.addPath(path)
        // Fully opaque. At 95 % the editor text behind still showed through
        // enough to tangle with the panel's own labels.
        ctx.setFillColor(NSColor(white: 0.055, alpha: 1.0).cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()

        text("SIMULATED DRIVE", at: CGPoint(x: rect.minX + 18, y: rect.maxY - 30),
             size: 11, weight: .semibold, color: NSColor.white.withAlphaComponent(0.45),
             tracking: 1.6, in: ctx)

        text(label(for: motion), at: CGPoint(x: rect.minX + 18, y: rect.maxY - 62),
             size: 21, weight: .bold, color: .white, in: ctx)

        bar("Longitudinal", motion.forward,
            at: CGPoint(x: rect.minX + 18, y: rect.minY + 52), width: w - 36, in: ctx)
        bar("Lateral", motion.lateral,
            at: CGPoint(x: rect.minX + 18, y: rect.minY + 14), width: w - 36, in: ctx)

        ctx.restoreGState()
    }

    /// Hysteresis-free but deliberately coarse: below 0.04 g nothing worth
    /// naming is happening, and the label should not flicker on noise.
    private static func label(for m: VehicleMotion) -> String {
        let f = m.forward, l = m.lateral
        if abs(f) < 0.04 && abs(l) < 0.04 { return "Cruising" }
        if abs(f) >= abs(l) { return f > 0 ? "Accelerating" : "Braking" }
        return l > 0 ? "Turning left" : "Turning right"
    }

    private static func bar(_ title: String, _ value: Double,
                            at origin: CGPoint, width: CGFloat, in ctx: CGContext) {
        text(title, at: CGPoint(x: origin.x, y: origin.y + 15),
             size: 10.5, weight: .medium, color: NSColor.white.withAlphaComponent(0.5), in: ctx)
        text(String(format: "%+.2f g", value), at: CGPoint(x: origin.x + width - 52, y: origin.y + 15),
             size: 10.5, weight: .medium, color: NSColor.white.withAlphaComponent(0.75), in: ctx)

        let track = CGRect(x: origin.x, y: origin.y, width: width, height: 5)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.13).cgColor)
        ctx.fill(track)

        // Centre-out fill, saturating at 0.35 g — a firm manoeuvre.
        let mid = track.midX
        let frac = CGFloat(max(-1, min(1, value / 0.35)))
        let half = width / 2
        let bar = CGRect(x: frac >= 0 ? mid : mid + frac * half,
                         y: origin.y, width: abs(frac) * half, height: 5)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.fill(bar)

        ctx.setFillColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        ctx.fill(CGRect(x: mid - 0.5, y: origin.y - 2, width: 1, height: 9))
    }

    // MARK: - Caption

    static func drawCaption(_ string: String, in ctx: CGContext, canvas: CGSize) {
        let font = NSFont.systemFont(ofSize: 17, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.92)
        ]
        let s = NSAttributedString(string: string, attributes: attrs)
        let size = s.size()
        let pad: CGFloat = 16
        let rect = CGRect(x: (canvas.width - size.width) / 2 - pad,
                          y: canvas.height - 74,
                          width: size.width + pad * 2, height: size.height + 14)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.setFillColor(NSColor(white: 0.055, alpha: 1.0).cgColor)
        ctx.fillPath()
        draw(s, at: CGPoint(x: rect.minX + pad, y: rect.minY + 7), in: ctx)
        ctx.restoreGState()
    }

    // MARK: - Text helpers

    private static func text(_ string: String, at point: CGPoint, size: CGFloat,
                             weight: NSFont.Weight, color: NSColor,
                             tracking: CGFloat = 0, in ctx: CGContext) {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color
        ]
        if tracking != 0 { attrs[.kern] = tracking }
        draw(NSAttributedString(string: string, attributes: attrs), at: point, in: ctx)
    }

    private static func draw(_ s: NSAttributedString, at point: CGPoint, in ctx: CGContext) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        s.draw(at: point)
        NSGraphicsContext.current = previous
    }
}
