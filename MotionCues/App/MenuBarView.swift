//
//  MenuBarView.swift
//

import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Vehicle Motion Cues")
        Text(statusLine)

        Divider()

        if coordinator.isRunning {
            Button("Stop") { coordinator.stop() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        } else {
            Button("Start") { coordinator.start() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }

        Divider()

        Picker("Intensity", selection: $settings.intensity) {
            ForEach(CueIntensity.allCases) { level in
                Text(level.displayName).tag(level)
            }
        }

        Picker("Sensor", selection: $settings.sourceKind) {
            Text("Automatic").tag(MotionSourceKind.automatic)
            Text("Mac (AirPods)").tag(MotionSourceKind.mac)
            Text("iPhone").tag(MotionSourceKind.iPhone)
            Text("Simulator").tag(MotionSourceKind.simulator)
        }

        Divider()

        Button("Settings…") {
            openWindow(id: SettingsWindowID.value)
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    private var statusLine: String {
        guard coordinator.isRunning else { return "Status: Inactive" }
        let s = coordinator.linkStatus
        if s.connected {
            let rate = s.rateHz > 0 ? String(format: " · %.0f Hz", s.rateHz) : ""
            return "Status: Active — \(coordinator.activeSource.displayName)\(rate)"
        }
        return "Status: Active — waiting for \(coordinator.activeSource.displayName)"
    }
}
