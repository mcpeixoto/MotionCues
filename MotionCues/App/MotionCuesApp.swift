//
//  MotionCuesApp.swift
//
//  Menu-bar-only app. `LSUIElement` in Info.plist keeps it out of the Dock and
//  off the menu bar's application menu; the activation policy is set to
//  `.accessory` as well so nothing can promote it to a regular app.
//

import SwiftUI
import AppKit

@main
struct MotionCuesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var coordinator: AppCoordinator

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _coordinator = StateObject(wrappedValue: AppCoordinator(settings: settings))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(coordinator)
                .environmentObject(settings)
        } label: {
            MenuBarLabel(isRunning: coordinator.isRunning)
        }
        .menuBarExtraStyle(.menu)

        Window("MotionCues Settings", id: SettingsWindowID.value) {
            SettingsView()
                .environmentObject(coordinator)
                .environmentObject(settings)
                .frame(minWidth: 520, minHeight: 560)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

enum SettingsWindowID {
    static let value = "motioncues-settings"
    /// Posted when something outside SwiftUI (relaunching the app, clicking it
    /// in the Dock) wants the settings window.
    static let openRequest = Notification.Name("com.motioncues.openSettings")
}

/// The status item's icon. It is also the app's only permanently-alive view,
/// which makes it the natural place to hold the `openWindow` action for
/// requests that originate in AppKit — the menu's contents only exist while
/// the menu is actually open, so they cannot serve that role.
private struct MenuBarLabel: View {
    let isRunning: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: isRunning
              ? "car.side.rear.and.collision.and.car.side.front"
              : "car.side")
        .onReceive(NotificationCenter.default.publisher(for: SettingsWindowID.openRequest)) { _ in
            openWindow(id: SettingsWindowID.value)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces alongside LSUIElement: never a Dock icon, never
        // steals activation from whatever you are actually using.
        NSApp.setActivationPolicy(.accessory)

        // Self-check hook used by the test scripts; no effect in normal use.
        if ProcessInfo.processInfo.environment["MC_PROBE"] != nil { runProbe() }
    }

    /// Launching an already-running menu-bar app looks like nothing happened.
    /// Show the settings window instead, which is the only thing the user
    /// could have wanted.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NotificationCenter.default.post(name: SettingsWindowID.openRequest, object: nil)
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func runProbe() {
        func dump(_ tag: String) {
            let names = NSApp.windows.map { "\(type(of: $0)) level=\($0.level.rawValue) visible=\($0.isVisible) frame=\($0.frame) screen=\(String(describing: $0.screen?.frame))" }
            FileHandle.standardError.write("PROBE \(tag) (\(names.count)): \(names)\n".data(using: .utf8)!)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            dump("launch")
            NotificationCenter.default.post(name: SettingsWindowID.openRequest, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { dump("after-open-settings") }
        }
    }
}
