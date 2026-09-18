//
//  CalibrationView.swift
//

import SwiftUI

struct CalibrationView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var settings: AppSettings
    @State private var manualDegrees: Double = 0

    var body: some View {
        let lang = settings.language
        Form {
            Section {
                Text(L10n.t(.howItWorksBody, lang))
                    .font(.callout)
                Text(L10n.t(.howItWorksDetail, lang))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(L10n.t(.howItWorks, lang))
            }

            Section(L10n.t(.status, lang)) {
                LabeledContent(L10n.t(.calibrated, lang),
                               value: coordinator.currentCalibration.isCalibrated
                               ? L10n.t(.yes, lang) : L10n.t(.notYet, lang))
                LabeledContent(L10n.t(.forwardAxis, lang),
                               value: String(format: "%.0f°",
                                             coordinator.currentCalibration.yaw * 180 / .pi))
                LabeledContent(L10n.t(.confidence, lang),
                               value: String(format: "%.0f%%",
                                             coordinator.calibrationQuality.confidence * 100))

                if coordinator.isCalibrating {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: coordinator.calibrationQuality.confidence)
                        HStack {
                            coverage(L10n.t(.accelBrakeSeen, lang),
                                     coordinator.calibrationQuality.longitudinalCoverage)
                            coverage(L10n.t(.corneringSeen, lang),
                                     coordinator.calibrationQuality.lateralCoverage)
                        }
                        Text(L10n.t(.keepDrivingHint, lang))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                HStack {
                    if coordinator.isCalibrating {
                        Button(L10n.t(.cancel, lang)) { coordinator.cancelCalibration() }
                    } else {
                        Button(L10n.t(.calibrate, lang)) { coordinator.beginCalibration() }
                            .disabled(!coordinator.isRunning)
                    }
                    Spacer()
                    Button(L10n.t(.clearCalibration, lang), role: .destructive) {
                        coordinator.clearCalibration()
                        manualDegrees = 0
                    }
                }
                if !coordinator.isRunning {
                    Text(L10n.t(.startFirstForCalibration, lang))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle(L10n.t(.keepRefining, lang), isOn: Binding(
                    get: { settings.calibration.autoRefine },
                    set: { newValue in
                        var state = settings.calibration
                        state.autoRefine = newValue
                        settings.calibration = state
                        coordinator.persistCalibration()
                    }
                ))
                LabeledContent(L10n.t(.manualAdjustment, lang)) {
                    HStack {
                        Slider(value: $manualDegrees, in: -180...180, step: 1)
                            .onChange(of: manualDegrees) { _, new in
                                coordinator.setManualYawOffset(new)
                            }
                        Text(String(format: "%+.0f°", manualDegrees))
                            .monospacedDigit()
                            .frame(width: 50, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(L10n.t(.fineTuning, lang))
            } footer: {
                Text(L10n.t(.fineTuningFooter, lang))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            manualDegrees = settings.calibration.manualOffset * 180 / .pi
        }
    }

    private func coverage(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            ProgressView(value: min(1, value))
        }
    }
}
