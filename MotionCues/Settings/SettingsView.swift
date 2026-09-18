//
//  SettingsView.swift
//

import SwiftUI
import CoreMotion

struct SettingsView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let lang = settings.language
        TabView {
            AppearanceSettings()
                .tabItem { Label(L10n.t(.tabAppearance, lang), systemImage: "circle.grid.3x3") }
            MotionSettings()
                .tabItem { Label(L10n.t(.tabMotion, lang), systemImage: "waveform.path.ecg") }
            CalibrationView()
                .tabItem { Label(L10n.t(.tabCalibration, lang), systemImage: "gyroscope") }
            SensorSettings()
                .tabItem { Label(L10n.t(.tabSensors, lang), systemImage: "antenna.radiowaves.left.and.right") }
        }
        .padding(16)
        .id(lang)
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let lang = settings.language
        Form {
            Section {
                Picker(L10n.t(.language, lang), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.menuTitle).tag(option)
                    }
                }
            }

            Section {
                slider(L10n.t(.dotSize, lang), value: $settings.dotDiameter, range: 3...22, unit: "pt")
                slider(L10n.t(.opacity, lang), value: $settings.opacity, range: 0.05...1.0, unit: "")
                slider(L10n.t(.howFarInFromEdge, lang), value: $settings.peripherySize,
                       range: 90...520, unit: "pt")
            } footer: {
                Text(L10n.t(.peripheryFooter, lang))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker(L10n.t(.contrast, lang), selection: $settings.appearance) {
                    ForEach(CueAppearance.allCases) {
                        Text($0.localizedName(lang)).tag($0)
                    }
                }
                Toggle(L10n.t(.includeVerticalCues, lang), isOn: $settings.verticalCues)
                Toggle(L10n.t(.fadeDotsWhenStill, lang), isOn: $settings.idleFade)
                Toggle(L10n.t(.hideFromScreenCapture, lang),
                       isOn: $settings.hideFromScreenCapture)
            } footer: {
                Text(L10n.t(.contrastFooter, lang))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(L10n.t(.resetToDefaults, lang)) { settings.resetToDefaults() }
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
        let lang = settings.language
        Form {
            Section {
                Picker(L10n.t(.intensity, lang), selection: $settings.intensity) {
                    ForEach(CueIntensity.allCases) {
                        Text($0.localizedName(lang)).tag($0)
                    }
                }
            } footer: {
                Text(L10n.t(.intensityFooter, lang, Int(settings.intensity.flowGain)))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L10n.t(.filtering, lang)) {
                LabeledContent(L10n.t(.smoothing, lang)) {
                    Slider(value: $settings.smoothing, in: 0...1)
                }
                LabeledContent(L10n.t(.sensitivity, lang)) {
                    Slider(value: $settings.sensitivity, in: 0...1)
                }
                LabeledContent(L10n.t(.responsiveness, lang)) {
                    Slider(value: $settings.responsiveness, in: 0...1)
                }
            }

            Section {
                Text(L10n.t(.filteringEssay, lang))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.t(.liveReading, lang)) {
                MotionMeter()
            }
        }
        .formStyle(.grouped)
    }
}

/// A small live meter so you can sanity-check the pipeline without a car.
private struct MotionMeter: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var settings: AppSettings
    @State private var motion = VehicleMotion.zero
    private let tick = Timer.publish(every: 1.0 / 20.0, on: .main, in: .common).autoconnect()

    var body: some View {
        let lang = settings.language
        VStack(alignment: .leading, spacing: 6) {
            bar(L10n.t(.longitudinal, lang), motion.forward, L10n.t(.hintBrakeAccel, lang))
            bar(L10n.t(.lateral, lang), motion.lateral, L10n.t(.hintRightLeft, lang))
            bar(L10n.t(.vertical, lang), motion.vertical, L10n.t(.hintDownUp, lang))
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
    @EnvironmentObject private var settings: AppSettings
    @State private var enabled = LoginItem.isEnabled
    @State private var problem: String?

    var body: some View {
        let lang = settings.language
        Toggle(L10n.t(.openAtLogin, lang), isOn: Binding(
            get: { enabled },
            set: { newValue in
                problem = LoginItem.setEnabled(newValue)
                enabled = LoginItem.isEnabled
            }
        ))
        if LoginItem.isBlockedByUser {
            Text(L10n.t(.loginItemBlocked, lang))
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
        let lang = settings.language
        Form {
            Section {
                Picker(L10n.t(.language, lang), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.menuTitle).tag(option)
                    }
                }
            }

            Section(L10n.t(.source, lang)) {
                Picker(L10n.t(.sensor, lang), selection: $settings.sourceKind) {
                    ForEach(MotionSourceKind.allCases, id: \.self) {
                        Text($0.localizedName(lang)).tag($0)
                    }
                }
                Toggle(L10n.t(.startCuesOnLaunch, lang),
                       isOn: $settings.startOnLaunch)
                Toggle(L10n.t(.onlyShowWhileMoving, lang),
                       isOn: $settings.onlyWhileDriving)
                LaunchAtLoginToggle()
            }

            Section(L10n.t(.linkStatus, lang)) {
                LabeledContent(L10n.t(.activeSource, lang),
                               value: coordinator.activeSource.localizedName(lang))
                LabeledContent(L10n.t(.connected, lang),
                               value: coordinator.linkStatus.connected
                               ? L10n.t(.yes, lang) : L10n.t(.no, lang))
                LabeledContent(L10n.t(.sampleRate, lang),
                               value: String(format: "%.0f Hz", coordinator.linkStatus.rateHz))
                if let jitter = coordinator.linkStatus.latencyMs {
                    LabeledContent(L10n.t(.transportJitter, lang),
                                   value: String(format: "%.1f ms", jitter))
                }
                LabeledContent(L10n.t(.droppedPackets, lang),
                               value: "\(coordinator.linkStatus.dropped)")
                LabeledContent(L10n.t(.inAVehicle, lang),
                               value: coordinator.isDriving.map {
                                   $0 ? L10n.t(.yes, lang) : L10n.t(.no, lang)
                               } ?? L10n.t(.notReported, lang))
                if !coordinator.linkStatus.detail.isEmpty {
                    Text(coordinator.linkStatus.detail)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent(L10n.t(.motionPermission, lang),
                               value: coordinator.motionAuthorizationDescription)
                LabeledContent(L10n.t(.headphoneMotionAvailable, lang),
                               value: coordinator.headphonesAvailable
                               ? L10n.t(.yes, lang) : L10n.t(.no, lang))
            } header: {
                Text(L10n.t(.macSensors, lang))
            } footer: {
                Text(L10n.t(.macSensorsFooter, lang))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text(L10n.t(.privacyFooter, lang))
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text(L10n.t(.privacy, lang))
            }
        }
        .formStyle(.grouped)
    }
}
