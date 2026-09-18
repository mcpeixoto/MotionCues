//
//  WelcomeView.swift
//
//  First run. A menu-bar app with no Dock icon and no window is invisible on
//  launch: nothing happens, and the one visual affordance is a small icon in a
//  bar most people do not look at. Without this the honest description of the
//  first-run experience is "nothing appears to happen".
//
//  It also does the one thing this app genuinely needs explaining: the reason
//  there is a phone involved at all.
//

import SwiftUI
import CoreMotion

struct WelcomeView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView { steps.padding(24) }
            Divider()
            footer
        }
        .frame(width: 560, height: 620)
        .id(settings.language)
    }

    private var header: some View {
        let lang = settings.language
        return VStack(spacing: 10) {
            Image(systemName: "car.side.rear.and.collision.and.car.side.front")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tint)
            Text(L10n.t(.appName, lang))
                .font(.title.weight(.semibold))
            Text(L10n.t(.welcomeBlurb, lang))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 26)
    }

    private var steps: some View {
        let lang = settings.language
        return VStack(alignment: .leading, spacing: 22) {
            step(1, L10n.t(.welcomeStep1Title, lang), L10n.t(.welcomeStep1Body, lang)) {
                EmptyView()
            }

            step(2, L10n.t(.welcomeStep2Title, lang), L10n.t(.welcomeStep2Body, lang)) {
                if coordinator.linkStatus.connected {
                    Label(L10n.t(.iPhoneConnected, lang), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label(L10n.t(.waitingForPhone, lang), systemImage: "clock")
                        .foregroundStyle(.secondary)
                }
            }

            step(3, L10n.t(.welcomeStep3Title, lang), L10n.t(.welcomeStep3Body, lang)) {
                EmptyView()
            }

            step(4, L10n.t(.welcomeStep4Title, lang), L10n.t(.welcomeStep4Body, lang)) {
                EmptyView()
            }

            if coordinator.headphonesAvailable {
                step(5, L10n.t(.welcomeStep5Title, lang), L10n.t(.welcomeStep5Body, lang)) {
                    Label(L10n.t(.motionPermissionLabel, lang,
                                 coordinator.motionAuthorizationDescription),
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func step<Accessory: View>(_ number: Int, _ title: String, _ body: String,
                                       @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.tint))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                accessory().font(.caption)
            }
        }
    }

    private var footer: some View {
        let lang = settings.language
        return HStack {
            Button(L10n.t(.tryWithoutCar, lang)) {
                settings.sourceKind = .simulator
                if !coordinator.isRunning { coordinator.start() }
            }
            Spacer()
            Button(L10n.t(.settingsEllipsis, lang)) { openWindow(id: SettingsWindowID.value) }
            Button(L10n.t(.done, lang)) {
                settings.hasSeenWelcome = true
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}
