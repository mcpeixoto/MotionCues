//
//  OverlayController.swift
//
//  Owns one overlay window per screen and keeps that set in sync with
//  reality: external displays plugged and unplugged, resolution changes,
//  scale-factor changes, display arrangement changes.
//
//  `NSApplication.didChangeScreenParametersNotification` is the single source
//  of truth for all of those — macOS coalesces them into that one
//  notification. We rebuild from `NSScreen.screens` each time rather than try
//  to diff, because screens have no stable public identity across
//  reconfiguration that is worth trusting.
//

import AppKit
import Combine

@MainActor
final class OverlayController {
    private var windows: [OverlayWindow] = []
    private var views: [OverlayView] = []
    private let state: MotionStateBox
    private var settings: RenderSettings
    private var hideFromCapture = false
    private var isVisible = false
    /// Kept with the centre each token came from — workspace notifications
    /// live on `NSWorkspace.shared.notificationCenter`, not the default one,
    /// and handing a token back to the wrong centre silently does nothing.
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(state: MotionStateBox, settings: RenderSettings) {
        self.state = state
        self.settings = settings

        let app = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter

        observe(app, NSApplication.didChangeScreenParametersNotification) { $0.rebuild() }
        // Coming back from sleep can leave windows on the wrong space/level.
        observe(workspace, NSWorkspace.didWakeNotification) { $0.rebuild() }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.reassertLevel() }
    }

    private func observe(_ center: NotificationCenter,
                         _ name: Notification.Name,
                         _ action: @escaping @MainActor (OverlayController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            // `queue: .main` guarantees we are already on the main thread.
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }

    deinit {
        for (center, token) in observers { center.removeObserver(token) }
    }

    func show() {
        isVisible = true
        rebuild()
    }

    func hide() {
        isVisible = false
        for view in views { view.stopDisplayLink() }
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
    }

    func update(settings: RenderSettings) {
        self.settings = settings
        for view in views { view.update(settings: settings) }
    }

    func setHiddenFromCapture(_ hidden: Bool) {
        hideFromCapture = hidden
        for window in windows { window.setExcludedFromCapture(hidden) }
    }

    /// Kick the display links when fresh motion arrives after an idle spell.
    func wake() {
        for view in views { view.wake() }
    }

    // MARK: - Window set

    private func rebuild() {
        guard isVisible else { return }

        for view in views { view.stopDisplayLink() }
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        views.removeAll()

        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen)
            let view = OverlayView(state: state, settings: settings)
            view.frame = NSRect(origin: .zero, size: screen.frame.size)
            view.autoresizingMask = [.width, .height]
            window.contentView = view
            window.setExcludedFromCapture(hideFromCapture)

            // `orderFrontRegardless` puts it up without activating the app,
            // which `orderFront(_:)` would otherwise ask for.
            window.orderFrontRegardless()

            windows.append(window)
            views.append(view)
        }
    }

    /// Switching Spaces can quietly demote a floating panel; re-stating the
    /// level and behaviour is cheap insurance.
    private func reassertLevel() {
        for window in windows {
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                         .fullScreenAuxiliary, .ignoresCycle]
            window.orderFrontRegardless()
        }
    }
}
