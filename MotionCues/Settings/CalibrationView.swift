//
//  CalibrationView.swift
//

import SwiftUI

struct CalibrationView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var settings: AppSettings
    @State private var manualDegrees: Double = 0

    var body: some View {
        Form {
            Section {
                Text("MotionCues has to know which way the car points relative to the sensor. It works that out from the driving itself — you never have to align anything by hand.")
                    .font(.callout)
                Text("Place the Mac where you normally use it, put the phone wherever it will stay (pocket, cradle, cup holder — orientation does not matter, only that it does not slide around), press Calibrate, then just travel normally for about twenty seconds. Include at least one bend.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("How it works")
            }

            Section("Status") {
                LabeledContent("Calibrated",
                               value: coordinator.currentCalibration.isCalibrated ? "Yes" : "Not yet")
                LabeledContent("Forward axis",
                               value: String(format: "%.0f°",
                                             coordinator.currentCalibration.yaw * 180 / .pi))
                LabeledContent("Confidence",
                               value: String(format: "%.0f%%",
                                             coordinator.calibrationQuality.confidence * 100))

                if coordinator.isCalibrating {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: coordinator.calibrationQuality.confidence)
                        HStack {
                            coverage("Accel / brake seen",
                                     coordinator.calibrationQuality.longitudinalCoverage)
                            coverage("Cornering seen",
                                     coordinator.calibrationQuality.lateralCoverage)
                        }
                        Text("Keep driving. Braking and accelerating fix the axis; a bend resolves which way is forwards.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                HStack {
                    if coordinator.isCalibrating {
                        Button("Cancel") { coordinator.cancelCalibration() }
                    } else {
                        Button("Calibrate") { coordinator.beginCalibration() }
                            .disabled(!coordinator.isRunning)
                    }
                    Spacer()
                    Button("Clear calibration", role: .destructive) {
                        coordinator.clearCalibration()
                        manualDegrees = 0
                    }
                }
                if !coordinator.isRunning {
                    Text("Start MotionCues first — calibration needs live samples.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Keep refining in the background", isOn: Binding(
                    get: { settings.calibration.autoRefine },
                    set: { newValue in
                        var state = settings.calibration
                        state.autoRefine = newValue
                        settings.calibration = state
                        coordinator.persistCalibration()
                    }
                ))
                LabeledContent("Manual adjustment") {
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
                Text("Fine tuning")
            } footer: {
                Text("Background refinement absorbs the gyroscope heading drift that Core Motion's magnetometer-free reference frame accumulates (a few degrees a minute), and copes with the phone being nudged. Turn it off if you would rather freeze the calibration exactly as measured.")
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
