//
//  OverlayWindow.swift
//
//  A borderless, click-through, non-activating panel that floats above
//  everything.
//
//  What each piece buys us, and what it does NOT buy us:
//
//  * `.borderless` + `.nonactivatingPanel` — no chrome, and clicking near it
//    never makes MotionCues the active app.
//  * `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false` —
//    only the dots are drawn; everything else is a hole.
//  * `ignoresMouseEvents = true` — every click, scroll and gesture goes to
//    whatever is underneath. There is no hit-testing at all.
//  * `level = .screenSaver` — above normal windows, above `.floating`, above
//    the Dock and menu bar. Requires no permissions.
//  * `collectionBehavior`:
//      - `.canJoinAllSpaces`   → follows you between Spaces
//      - `.stationary`         → does not slide around in Mission Control
//      - `.fullScreenAuxiliary`→ allowed to be shown alongside a full-screen
//                                window
//      - `.ignoresCycle`       → never appears in Cmd-Tab / window cycling
//
//  Honest limitations (macOS, public API, no private calls):
//
//  * Native full-screen apps: `.fullScreenAuxiliary` plus a `.screenSaver`
//    level works for the great majority of them (Safari, VS Code, Netflix in
//    the browser). It is not a guarantee. Some apps take an exclusive
//    display — notably games using a captured display, and Keynote's
//    presenter mode — and nothing at this API level will draw above those.
//  * Secure input / the login window / the screen saver / Fast User Switching
//    hide all application windows including this one. Expected and correct.
//  * DRM-protected video (e.g. Apple TV+ in Safari) renders in a protected
//    path; the overlay still draws above it, but the *capture* of that
//    combination is blocked by the system, not by us.
//  * We cannot read what is behind the overlay without Screen Recording
//    permission, so dot colour follows the system appearance rather than the
//    actual pixels underneath. Each dot therefore carries a contrasting halo
//    so it stays legible either way.
//

import AppKit

final class OverlayWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        worksWhenModal = true
        animationBehavior = .none

        level = NSWindow.Level.screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        // Displaying over other apps must never move focus.
        setFrame(screen.frame, display: false)
    }

    // A borderless panel refuses key/main status by default; make that explicit
    // so nothing can accidentally focus it.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    /// `.none` keeps the dots out of screenshots and screen recordings, which
    /// matters if you share your screen while this is running.
    func setExcludedFromCapture(_ excluded: Bool) {
        sharingType = excluded ? .none : .readOnly
    }
}
