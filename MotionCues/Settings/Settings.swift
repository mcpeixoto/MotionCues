//
//  Settings.swift
//
//  All user-tunable state. Backed by UserDefaults, observed by SwiftUI for the
//  settings window only — the render loop reads a plain value snapshot, never
//  the observable object.
//
//  The value types themselves live in RenderSettings.swift.
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()

    @Published var dotDiameter: Double { didSet { defaults.set(dotDiameter, forKey: K.dotDiameter) } }
    @Published var opacity: Double { didSet { defaults.set(opacity, forKey: K.opacity) } }
    @Published var intensity: CueIntensity { didSet { defaults.set(intensity.rawValue, forKey: K.intensity) } }
    @Published var smoothing: Double { didSet { defaults.set(smoothing, forKey: K.smoothing) } }
    @Published var sensitivity: Double { didSet { defaults.set(sensitivity, forKey: K.sensitivity) } }
    @Published var appearance: CueAppearance { didSet { defaults.set(appearance.rawValue, forKey: K.appearance) } }
    @Published var verticalCues: Bool { didSet { defaults.set(verticalCues, forKey: K.verticalCues) } }
    @Published var sourceKind: MotionSourceKind { didSet { defaults.set(sourceKind.rawValue, forKey: K.sourceKind) } }
    @Published var startOnLaunch: Bool { didSet { defaults.set(startOnLaunch, forKey: K.startOnLaunch) } }
    @Published var hideFromScreenCapture: Bool { didSet { defaults.set(hideFromScreenCapture, forKey: K.hideFromCapture) } }
    @Published var peripherySize: Double { didSet { defaults.set(peripherySize, forKey: K.peripherySize) } }
    @Published var responsiveness: Double { didSet { defaults.set(responsiveness, forKey: K.responsiveness) } }
    @Published var idleFade: Bool { didSet { defaults.set(idleFade, forKey: K.idleFade) } }

    @Published var calibration: CalibrationState {
        didSet {
            if let data = try? JSONEncoder().encode(calibration) {
                defaults.set(data, forKey: K.calibration)
            }
        }
    }

    /// Emits a fresh snapshot whenever anything the renderer cares about moves.
    let renderSettings = CurrentValueSubject<RenderSettings, Never>(RenderSettings())

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            K.dotDiameter: 7.0,
            K.opacity: 0.45,
            K.intensity: CueIntensity.medium.rawValue,
            K.smoothing: 0.5,
            K.sensitivity: 0.5,
            K.appearance: CueAppearance.automatic.rawValue,
            K.verticalCues: true,
            K.sourceKind: MotionSourceKind.automatic.rawValue,
            K.startOnLaunch: false,
            K.hideFromCapture: false,
            K.peripherySize: 240.0,
            K.responsiveness: 0.5,
            K.idleFade: true
        ])

        dotDiameter = defaults.double(forKey: K.dotDiameter)
        opacity = defaults.double(forKey: K.opacity)
        intensity = CueIntensity(rawValue: defaults.string(forKey: K.intensity) ?? "") ?? .medium
        smoothing = defaults.double(forKey: K.smoothing)
        sensitivity = defaults.double(forKey: K.sensitivity)
        appearance = CueAppearance(rawValue: defaults.string(forKey: K.appearance) ?? "") ?? .automatic
        verticalCues = defaults.bool(forKey: K.verticalCues)
        sourceKind = MotionSourceKind(rawValue: defaults.string(forKey: K.sourceKind) ?? "") ?? .automatic
        startOnLaunch = defaults.bool(forKey: K.startOnLaunch)
        hideFromScreenCapture = defaults.bool(forKey: K.hideFromCapture)
        peripherySize = defaults.double(forKey: K.peripherySize)
        responsiveness = defaults.double(forKey: K.responsiveness)
        idleFade = defaults.bool(forKey: K.idleFade)

        if let data = defaults.data(forKey: K.calibration),
           let decoded = try? JSONDecoder().decode(CalibrationState.self, from: data) {
            calibration = decoded
        } else {
            calibration = CalibrationState()
        }

        renderSettings.send(snapshot())

        // Coalesce bursts of slider changes into one snapshot per runloop turn.
        objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                let next = self.snapshot()
                if next != self.renderSettings.value { self.renderSettings.send(next) }
            }
            .store(in: &cancellables)
    }

    func snapshot() -> RenderSettings {
        RenderSettings(dotDiameter: dotDiameter,
                       opacity: opacity,
                       appearance: appearance,
                       verticalCues: verticalCues,
                       idleFadeEnabled: idleFade,
                       flowGain: intensity.flowGain,
                       peripherySize: peripherySize)
    }

    func resetToDefaults() {
        dotDiameter = 9
        opacity = 0.55
        intensity = .medium
        smoothing = 0.5
        sensitivity = 0.5
        responsiveness = 0.5
        peripherySize = 240
        appearance = .automatic
        verticalCues = true
        idleFade = true
    }

    private enum K {
        static let dotDiameter = "dotDiameter"
        static let opacity = "opacity"
        static let intensity = "intensity"
        static let smoothing = "smoothing"
        static let sensitivity = "sensitivity"
        static let appearance = "appearance"
        static let verticalCues = "verticalCues"
        static let sourceKind = "sourceKind"
        static let startOnLaunch = "startOnLaunch"
        static let hideFromCapture = "hideFromScreenCapture"
        static let peripherySize = "peripherySize"
        static let responsiveness = "responsiveness"
        static let idleFade = "idleFade"
        static let calibration = "calibration"
    }
}
