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
    /// Drift speed in points per second per g. The dominant cue — see DotFlow.
    var flowGain: Double = 620
    /// Maximum excursion across the column, in points. Small on purpose —
    /// there is no room sideways. See DotFlow.
    var flowAcrossLimit: Double = 90
}
