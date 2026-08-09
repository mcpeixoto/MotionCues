//
//  RenderSettings.swift
//
//  The pure value types the renderer works in. Split out from `Settings.swift`
//  deliberately: the render path, and the offline demo renderer in Tools/,
//  need these without pulling in SwiftUI, Combine or the @MainActor store.
//

import Foundation

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

    /// How hard vehicle acceleration drives the particle field, in points per
    /// second squared per g. This is what Intensity really controls.
    var flowGain: Double {
        switch self {
        case .low: 520
        case .medium: 900
        case .high: 1400
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
    var dotDiameter: Double = 9
    var opacity: Double = 0.55
    var appearance: CueAppearance = .automatic
    var verticalCues: Bool = true
    var idleFadeEnabled: Bool = true
    /// Scales vehicle acceleration into the particle field's response.
    /// Points per second squared per g. See ParticleField.
    var flowGain: Double = 900
    /// How far in from the screen edge the cue reaches, in points. The middle
    /// is left clear because that is where you are trying to read.
    var peripherySize: Double = 240
}
