//
//  MenuBarView.swift
//

import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let lang = settings.language
        Text(L10n.t(.vehicleMotionCues, lang))
        Text(statusLine(lang))

        Divider()

        if coordinator.isRunning {
            Button(L10n.t(.menuStop, lang)) { coordinator.stop() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        } else {
            Button(L10n.t(.menuStart, lang)) { coordinator.start() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }

        Divider()

        Picker(L10n.t(.intensity, lang), selection: $settings.intensity) {
            ForEach(CueIntensity.allCases) { level in
                Text(level.localizedName(lang)).tag(level)
            }
        }

        Picker(L10n.t(.sensor, lang), selection: $settings.sourceKind) {
            Text(L10n.t(.automatic, lang)).tag(MotionSourceKind.automatic)
            Text(L10n.t(.macAirPods, lang)).tag(MotionSourceKind.mac)
            Text(L10n.t(.iPhone, lang)).tag(MotionSourceKind.iPhone)
            Text(L10n.t(.simulator, lang)).tag(MotionSourceKind.simulator)
        }

        Picker(L10n.t(.language, lang), selection: $settings.language) {
            ForEach(AppLanguage.allCases) { option in
                Text(option.menuTitle).tag(option)
            }
        }

        Divider()

        Button(L10n.t(.welcomeAndSetup, lang)) {
            openWindow(id: WelcomeWindowID.value)
            NSApp.activate(ignoringOtherApps: true)
        }

        Button(L10n.t(.settingsEllipsis, lang)) {
            openWindow(id: SettingsWindowID.value)
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)

        Button(L10n.t(.quit, lang)) { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    private func statusLine(_ lang: AppLanguage) -> String {
        guard coordinator.isRunning else { return L10n.t(.statusInactive, lang) }
        let s = coordinator.linkStatus
        let source = coordinator.activeSource.localizedName(lang)
        if s.connected {
            let rate = s.rateHz > 0 ? L10n.t(.statusRateSuffix, lang, s.rateHz) : ""
            return L10n.t(.statusActiveConnected, lang, source) + rate
        }
        return L10n.t(.statusActiveWaiting, lang, source)
    }
}
