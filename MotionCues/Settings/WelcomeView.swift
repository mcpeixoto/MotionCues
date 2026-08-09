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
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "car.side.rear.and.collision.and.car.side.front")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tint)
            Text("MotionCues")
                .font(.title.weight(.semibold))
            Text("Small particles at the edges of the screen move with the car, so what your eyes see matches what your inner ear feels.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 26)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 22) {
            step(1, "Your Mac has no motion sensor",
                 "Not a limitation of this app: macOS exposes no accelerometer, and Apple Silicon Macs have no inertial hardware at all. So an iPhone does the sensing and streams it over, a hundred times a second.") {
                EmptyView()
            }

            step(2, "Install the companion on your iPhone",
                 "Build the MotionCuesIOS target onto your phone, open it and tap Start streaming. Your Mac will appear in its list within a second or two.") {
                if coordinator.linkStatus.connected {
                    Label("iPhone connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Waiting for a phone", systemImage: "clock")
                        .foregroundStyle(.secondary)
                }
            }

            step(3, "Allow the local network",
                 "Both devices will ask once. The link is a direct connection between your own two devices — nothing goes to the Internet, here or ever.") {
                EmptyView()
            }

            step(4, "Calibrate on your first journey",
                 "Put the phone anywhere it will stay put; orientation does not matter. Press Calibrate and drive normally for about twenty seconds, including at least one bend. MotionCues works out which way the car points from the driving itself.") {
                EmptyView()
            }

            if coordinator.headphonesAvailable {
                step(5, "AirPods will do at a pinch",
                     "If the phone is not to hand, MotionCues can fall back to head motion from AirPods. It is a real inertial signal, but your head moves too, so treat it as the lesser option.") {
                    Label("Motion permission: \(coordinator.motionAuthorizationDescription)",
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
        HStack {
            Button("Try it without a car") {
                settings.sourceKind = .simulator
                if !coordinator.isRunning { coordinator.start() }
            }
            Spacer()
            Button("Settings…") { openWindow(id: SettingsWindowID.value) }
            Button("Done") {
                settings.hasSeenWelcome = true
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}
