//
//  OverlayView.swift
//
//  Layer-backed host for the dots, driven by a per-screen CADisplayLink.
//
//  `NSView.displayLink(target:selector:)` is macOS 14+ (verified in the
//  AppKit headers of the macOS 26.5 SDK, alongside the same method on NSWindow
//  and NSScreen). It fires in step with the display the view is actually on,
//  which is what we want with mixed 60 Hz / 120 Hz ProMotion setups: each
//  overlay ticks at its own screen's rate with no manual timer maths.
//

import AppKit
import QuartzCore

final class OverlayView: NSView {
    private let state: MotionStateBox
    private var renderer: LayerDotRenderer!
    private var activeLink: CADisplayLink?
    private var settings: RenderSettings
    private var lastTick: CFTimeInterval = 0
    private var idleFrames = 0

    /// Once the field has been still for this many frames we park the display
    /// link entirely; a stationary Mac then costs zero CPU.
    private let idleFramesBeforePark = 180

    init(state: MotionStateBox, settings: RenderSettings) {
        self.state = state
        self.settings = settings
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layerContentsRedrawPolicy = .never
        renderer = LayerDotRenderer(root: layer!)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // AppKit's default is a flipped-if-you-say-so coordinate space; we keep
    // the standard bottom-left origin so the maths in DotLayout reads normally.
    override var isFlipped: Bool { false }

    // Belt and braces on top of the window's `ignoresMouseEvents`.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    func update(settings: RenderSettings) {
        self.settings = settings
        reconfigure()
        wake()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopDisplayLink()
        } else {
            reconfigure()
            startDisplayLink()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reconfigure()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reconfigure()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        reconfigure()
    }

    private func reconfigure() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.contentsScale = scale
        layer?.frame = bounds
        renderer.configure(settings: settings, size: bounds.size, scale: scale, isDark: isDark)
    }

    // MARK: - Display link

    private func startDisplayLink() {
        guard activeLink == nil else { return }
        // NSView.displayLink(target:selector:) — macOS 14+, ties the callback to
        // whichever display this view is currently on.
        let link = self.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        activeLink = link
        lastTick = CACurrentMediaTime()
        idleFrames = 0
    }

    func stopDisplayLink() {
        activeLink?.invalidate()
        activeLink = nil
    }

    /// Called when new motion arrives after an idle period.
    func wake() {
        idleFrames = 0
        if activeLink == nil, window != nil { startDisplayLink() }
        activeLink?.isPaused = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = lastTick == 0 ? (1.0 / 60.0) : min(now - lastTick, 0.1)
        lastTick = now

        let motion = state.load()
        renderer.render(motion: motion, dt: dt)

        // Park when nothing has moved for a while. The AppCoordinator calls
        // `wake()` as soon as a non-trivial sample shows up again.
        if motion.magnitude < 0.004 && renderer.isSettled {
            idleFrames += 1
            if idleFrames > idleFramesBeforePark { link.isPaused = true }
        } else {
            idleFrames = 0
        }
    }
}
