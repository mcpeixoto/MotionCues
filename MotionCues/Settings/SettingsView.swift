//
//  SettingsView.swift
//

import SwiftUI
import CoreMotion

struct SettingsView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "circle.grid.3x3") }
            MotionSettings()
                .tabItem { Label("Motion", systemImage: "waveform.path.ecg") }
            CalibrationView()
                .tabItem { Label("Calibration", systemImage: "gyroscope") }
            SensorSettings()
                .tabItem { Label("Sensors", systemImage: "antenna.radiowaves.left.and.right") }
        }
        .padding(16)
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                slider("Dot size", value: $settings.dotDiameter, range: 3...22, unit: "pt")
                slider("Opacity", value: $settings.opacity, range: 0.05...1.0, unit: "")
                slider("How far in from the edge", value: $settings.peripherySize,
                       range: 90...520, unit: "pt")
            } footer: {
                Text("The cue lives in your peripheral vision. The middle of the screen is left clear, because that is where you are reading.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Contrast", selection: $settings.appearance) {
                    ForEach(CueAppearance.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Include vertical (bump) cues", isOn: $settings.verticalCues)
                Toggle("Fade dots down when the car is still", isOn: $settings.idleFade)
                Toggle("Hide overlay from screenshots and screen sharing",
                       isOn: $settings.hideFromScreenCapture)
            } footer: {
                Text("The overlay cannot read what is behind it without Screen Recording permission. Rather than guess, every particle is drawn twice — once light, once dark, slightly offset — so whichever one contrasts with your content is the one you see.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Reset to defaults") { settings.resetToDefaults() }
            }
        }
        .formStyle(.grouped)
    }

    private func slider(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, unit: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range)
                Text(unit.isEmpty
                     ? String(format: "%.2f", value.wrappedValue)
                     : String(format: "%.0f %@", value.wrappedValue, unit))
                    .monospacedDigit()
                    .frame(width: 60, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Motion

private struct MotionSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        Form {
            Section {
                Picker("Intensity", selection: $settings.intensity) {
                    ForEach(CueIntensity.allCases) { Text($0.displayName).tag($0) }
                }
            } footer: {
                Text("How hard the car's motion drives the field: \(Int(settings.intensity.flowGain)) pt/s² per g. Start at Low.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Filtering") {
                LabeledContent("Smoothing") {
                    Slider(value: $settings.smoothing, in: 0...1)
                }
                LabeledContent("Sensitivity") {
                    Slider(value: $settings.sensitivity, in: 0...1)
                }
                LabeledContent("Responsiveness") {
                    Slider(value: $settings.responsiveness, in: 0...1)
                }
            }

            Section {
                Text("Smoothing sets how still the dots are at rest (the One Euro filter's cutoff floor). Sensitivity sets how far that cutoff opens under a fast manoeuvre, i.e. how little lag you get during hard braking. Responsiveness is the render-side spring: higher is snappier, lower is more fluid.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Live reading") {
                MotionMeter()
            }
        }
        .formStyle(.grouped)
    }
}

/// A small live meter so you can sanity-check the pipeline without a car.
private struct MotionMeter: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var motion = VehicleMotion.zero
    private let tick = Timer.publish(every: 1.0 / 20.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            bar("Longitudinal", motion.forward, "brake ← → accelerate")
            bar("Lateral", motion.lateral, "right ← → left")
            bar("Vertical", motion.vertical, "down ← → up")
        }
        .onReceive(tick) { _ in motion = coordinator.currentMotion }
    }

    private func bar(_ title: String, _ value: Double, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: "%+.3f g", value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let half = geo.size.width / 2
                let clamped = max(-0.5, min(0.5, value))
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 6)
                    Capsule()
                        .fill(.tint)
                        .frame(width: abs(CGFloat(clamped) * 2 * half), height: 6)
                        .offset(x: clamped >= 0 ? half : half - abs(CGFloat(clamped) * 2 * half))
                }
            }
            .frame(height: 8)
            Text(hint).font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

/// The system owns the login-item state, so this reads it live rather than
/// mirroring it into UserDefaults where the two could drift apart.
private struct LaunchAtLoginToggle: View {
    @State private var enabled = LoginItem.isEnabled
    @State private var problem: String?

    var body: some View {
        Toggle("Open MotionCues at login", isOn: Binding(
            get: { enabled },
            set: { newValue in
                problem = LoginItem.setEnabled(newValue)
                enabled = LoginItem.isEnabled
            }
        ))
        if LoginItem.isBlockedByUser {
            Text("Turned off in System Settings › General › Login Items.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let problem {
            Text(problem).font(.caption).foregroundStyle(.red)
        }
    }
}

// MARK: - Sensors

private struct SensorSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        Form {
            Section("Source") {
                Picker("Sensor", selection: $settings.sourceKind) {
                    ForEach(MotionSourceKind.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                Toggle("Start cues automatically when the app launches",
                       isOn: $settings.startOnLaunch)
                LaunchAtLoginToggle()
            }

            Section("Link status") {
                LabeledContent("Active source", value: coordinator.activeSource.displayName)
                LabeledContent("Connected", value: coordinator.linkStatus.connected ? "Yes" : "No")
                LabeledContent("Sample rate",
                               value: String(format: "%.0f Hz", coordinator.linkStatus.rateHz))
                if let jitter = coordinator.linkStatus.latencyMs {
                    LabeledContent("Transport jitter", value: String(format: "%.1f ms", jitter))
                }
                LabeledContent("Dropped packets", value: "\(coordinator.linkStatus.dropped)")
                if !coordinator.linkStatus.detail.isEmpty {
                    Text(coordinator.linkStatus.detail)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Motion permission", value: coordinator.motionAuthorizationDescription)
                LabeledContent("Headphone motion available",
                               value: coordinator.headphonesAvailable ? "Yes" : "No")
            } header: {
                Text("Mac sensors")
            } footer: {
                Text("This Mac has no built-in accelerometer or gyroscope — Core Motion's CMMotionManager is marked API_UNAVAILABLE(macos), and Apple Silicon Macs ship no inertial hardware. The only inertial source macOS exposes is head motion from AirPods (CMHeadphoneMotionManager, macOS 14+). It works, but head movement contaminates it, so the iPhone companion is the accurate path.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text("All sensor data stays on this Mac and on your phone. There is no account, no cloud, no analytics and no Internet access of any kind — the link is a direct UDP stream over your local network or over peer-to-peer Wi-Fi.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Privacy")
            }
        }
        .formStyle(.grouped)
    }
}
