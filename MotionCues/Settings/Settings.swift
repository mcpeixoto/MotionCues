//
//  Settings.swift
//
//  All user-tunable state. Backed by UserDefaults, observed by SwiftUI for the
//  settings window only — the render loop reads a plain value snapshot, never
//  the observable object.
//

import Foundation
import SwiftUI
import Combine

enum CueIntensity: String, CaseIterable, Codable, Identifiable {
    case low, medium, high
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    /// Screen points of dot travel per g of acceleration.
    var gain: Double {
        switch self {
        case .low: 26
        case .medium: 48
        case .high: 80
        }
    }
}

enum DotPlacement: String, CaseIterable, Codable, Identifiable {
    case sides
    case sidesAndTopBottom
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sides: "Left & right only"
        case .sidesAndTopBottom: "All four edges"
        }
    }
}

enum CueAppearance: String, CaseIterable, Codable, Identifiable {
    case automatic, light, dark
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "Follow system"
        case .light: "Dark dots (for light backgrounds)"
        case .dark: "Light dots (for dark backgrounds)"
        }
    }
}

/// Immutable snapshot handed to the renderer. Copied once per settings change,
/// never read through an observable object at frame rate.
struct RenderSettings: Equatable {
    var dotsPerEdge: Int = 8
    var dotDiameter: Double = 7
    var opacity: Double = 0.45
    var edgeInset: Double = 26
    var gain: Double = 48
    var placement: DotPlacement = .sides
    var appearance: CueAppearance = .automatic
    var verticalCues: Bool = true
    var springOmega: Double = 18
    var idleFadeEnabled: Bool = true
}

@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()

    @Published var dotsPerEdge: Int { didSet { defaults.set(dotsPerEdge, forKey: K.dotsPerEdge) } }
    @Published var dotDiameter: Double { didSet { defaults.set(dotDiameter, forKey: K.dotDiameter) } }
    @Published var opacity: Double { didSet { defaults.set(opacity, forKey: K.opacity) } }
    @Published var edgeInset: Double { didSet { defaults.set(edgeInset, forKey: K.edgeInset) } }
    @Published var intensity: CueIntensity { didSet { defaults.set(intensity.rawValue, forKey: K.intensity) } }
    @Published var smoothing: Double { didSet { defaults.set(smoothing, forKey: K.smoothing) } }
    @Published var sensitivity: Double { didSet { defaults.set(sensitivity, forKey: K.sensitivity) } }
    @Published var placement: DotPlacement { didSet { defaults.set(placement.rawValue, forKey: K.placement) } }
    @Published var appearance: CueAppearance { didSet { defaults.set(appearance.rawValue, forKey: K.appearance) } }
    @Published var verticalCues: Bool { didSet { defaults.set(verticalCues, forKey: K.verticalCues) } }
    @Published var sourceKind: MotionSourceKind { didSet { defaults.set(sourceKind.rawValue, forKey: K.sourceKind) } }
    @Published var startOnLaunch: Bool { didSet { defaults.set(startOnLaunch, forKey: K.startOnLaunch) } }
    @Published var hideFromScreenCapture: Bool { didSet { defaults.set(hideFromScreenCapture, forKey: K.hideFromCapture) } }
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
            K.dotsPerEdge: 8,
            K.dotDiameter: 7.0,
            K.opacity: 0.45,
            K.edgeInset: 26.0,
            K.intensity: CueIntensity.medium.rawValue,
            K.smoothing: 0.5,
            K.sensitivity: 0.5,
            K.placement: DotPlacement.sides.rawValue,
            K.appearance: CueAppearance.automatic.rawValue,
            K.verticalCues: true,
            K.sourceKind: MotionSourceKind.automatic.rawValue,
            K.startOnLaunch: false,
            K.hideFromCapture: false,
            K.responsiveness: 0.5,
            K.idleFade: true
        ])

        dotsPerEdge = defaults.integer(forKey: K.dotsPerEdge)
        dotDiameter = defaults.double(forKey: K.dotDiameter)
        opacity = defaults.double(forKey: K.opacity)
        edgeInset = defaults.double(forKey: K.edgeInset)
        intensity = CueIntensity(rawValue: defaults.string(forKey: K.intensity) ?? "") ?? .medium
        smoothing = defaults.double(forKey: K.smoothing)
        sensitivity = defaults.double(forKey: K.sensitivity)
        placement = DotPlacement(rawValue: defaults.string(forKey: K.placement) ?? "") ?? .sides
        appearance = CueAppearance(rawValue: defaults.string(forKey: K.appearance) ?? "") ?? .automatic
        verticalCues = defaults.bool(forKey: K.verticalCues)
        sourceKind = MotionSourceKind(rawValue: defaults.string(forKey: K.sourceKind) ?? "") ?? .automatic
        startOnLaunch = defaults.bool(forKey: K.startOnLaunch)
        hideFromScreenCapture = defaults.bool(forKey: K.hideFromCapture)
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
        RenderSettings(dotsPerEdge: dotsPerEdge,
                       dotDiameter: dotDiameter,
                       opacity: opacity,
                       edgeInset: edgeInset,
                       gain: intensity.gain,
                       placement: placement,
                       appearance: appearance,
                       verticalCues: verticalCues,
                       // responsiveness 0…1 → 9…30 rad/s natural frequency
                       springOmega: 9 + 21 * max(0, min(1, responsiveness)),
                       idleFadeEnabled: idleFade)
    }

    func resetToDefaults() {
        dotsPerEdge = 8
        dotDiameter = 7
        opacity = 0.45
        edgeInset = 26
        intensity = .medium
        smoothing = 0.5
        sensitivity = 0.5
        responsiveness = 0.5
        placement = .sides
        appearance = .automatic
        verticalCues = true
        idleFade = true
    }

    private enum K {
        static let dotsPerEdge = "dotsPerEdge"
        static let dotDiameter = "dotDiameter"
        static let opacity = "opacity"
        static let edgeInset = "edgeInset"
        static let intensity = "intensity"
        static let smoothing = "smoothing"
        static let sensitivity = "sensitivity"
        static let placement = "placement"
        static let appearance = "appearance"
        static let verticalCues = "verticalCues"
        static let sourceKind = "sourceKind"
        static let startOnLaunch = "startOnLaunch"
        static let hideFromCapture = "hideFromScreenCapture"
        static let responsiveness = "responsiveness"
        static let idleFade = "idleFade"
        static let calibration = "calibration"
    }
}
