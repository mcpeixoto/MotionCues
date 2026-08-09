//
//  AppCoordinator.swift
//
//  Wires provider → engine → overlay, and owns the source-selection policy.
//

import AppKit
import Combine
import CoreMotion
import SwiftUI

@MainActor
final class AppCoordinator: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var linkStatus = MotionLinkStatus()
    @Published private(set) var calibrationQuality = CalibrationQuality()
    @Published private(set) var isCalibrating = false
    @Published private(set) var activeSource: MotionSourceKind = .automatic
    /// What the phone says about being in a vehicle. `nil` when nothing is
    /// reporting it, which is treated as "show the cues" rather than "hide".
    @Published private(set) var isDriving: Bool?

    let settings: AppSettings
    // `nonisolated`: the engine is deliberately driven from the sensor queue,
    // not the main actor. It publishes through a lock-protected box that the
    // display link reads at vsync — see `MotionStateBox`.
    private nonisolated let engine = MotionEngine()
    private var overlay: OverlayController!

    private var provider: MotionProvider?
    /// In `.automatic` we keep the iPhone listener alive permanently and only
    /// fall back to AirPods while no phone is streaming, so plugging the phone
    /// in mid-journey takes over with no user action.
    private var fallbackProvider: MotionProvider?
    private var usingFallback = false

    private var cancellables = Set<AnyCancellable>()
    private var statusTimer: Timer?
    private var lastWake: Double = 0

    init(settings: AppSettings) {
        self.settings = settings
        overlay = OverlayController(state: engine.state, settings: settings.snapshot())

        engine.loadCalibration(settings.calibration)
        engine.smoothing = settings.smoothing
        engine.sensitivity = settings.sensitivity

        settings.renderSettings
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                self?.overlay.update(settings: snapshot)
            }
            .store(in: &cancellables)

        settings.$smoothing
            .sink { [weak self] value in self?.engine.smoothing = value }
            .store(in: &cancellables)
        settings.$sensitivity
            .sink { [weak self] value in self?.engine.sensitivity = value }
            .store(in: &cancellables)
        settings.$hideFromScreenCapture
            .sink { [weak self] value in self?.overlay.setHiddenFromCapture(value) }
            .store(in: &cancellables)
        settings.$onlyWhileDriving
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyDrivingGate() }
            .store(in: &cancellables)
        settings.$sourceKind
            .dropFirst()
            // `@Published` fires from `willSet`, so at that instant
            // `settings.sourceKind` is still the OLD value and restarting here
            // would bring the previous source back up. Hop through the run
            // loop so the property has actually landed.
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isRunning else { return }
                self.restartProviders()
            }
            .store(in: &cancellables)

        engine.onCalibrationUpdate = { [weak self] quality in
            Task { @MainActor in
                guard let self else { return }
                self.calibrationQuality = quality
                if self.isCalibrating && self.engine.calibration.isCalibrated {
                    self.isCalibrating = false
                    self.settings.calibration = self.engine.calibration
                }
            }
        }

        if settings.startOnLaunch {
            // Not synchronously: this runs inside the App's `init`, before
            // `applicationDidFinishLaunching`, and putting NSPanels on screen
            // that early is asking for trouble.
            Task { @MainActor [weak self] in self?.start() }
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        overlay.setHiddenFromCapture(settings.hideFromScreenCapture)
        applyDrivingGate()
        overlay.show()
        startProviders()
        startStatusTimer()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopProviders()
        overlay.hide()
        statusTimer?.invalidate()
        statusTimer = nil
        linkStatus = MotionLinkStatus()
    }

    func toggle() { isRunning ? stop() : start() }

    /// Hide the overlay when the phone says the car is parked.
    ///
    /// Only ever acts on a definite `false`. If nothing is reporting a drive
    /// state — no phone, or the phone has detection switched off — the cues
    /// stay up. Silently hiding the overlay because we do not know is much
    /// worse than showing it when it is not needed.
    private func applyDrivingGate() {
        guard isRunning else { return }
        let shouldHide = settings.onlyWhileDriving && isDriving == false
        if shouldHide {
            overlay.hide()
        } else {
            overlay.show()
        }
    }

    // MARK: - Provider selection

    private func startProviders() {
        engine.reset()
        let kind = settings.sourceKind

        switch kind {
        case .simulator:
            provider = makeSimulator()
        case .iPhone:
            provider = makeReceiver()
        case .mac:
            provider = makeHeadphones()
        case .automatic:
            // Phone is the good source; AirPods only cover the gap.
            provider = makeReceiver()
            if HeadphoneMotionProvider.isSupportedOnThisMac {
                fallbackProvider = makeHeadphones()
            }
        }

        provider?.start()
        fallbackProvider?.start()
        activeSource = kind == .automatic ? .iPhone : kind
        engine.sourceKind = activeSource
    }

    private func stopProviders() {
        provider?.stop(); provider = nil
        fallbackProvider?.stop(); fallbackProvider = nil
        usingFallback = false
    }

    private func restartProviders() {
        stopProviders()
        startProviders()
    }

    private func makeSimulator() -> MotionProvider {
        let p = SimulatedMotionProvider()
        attach(p, isFallback: false)
        return p
    }

    private func makeReceiver() -> MotionProvider {
        let p = MotionReceiver()
        attach(p, isFallback: false)
        return p
    }

    private func makeHeadphones() -> MotionProvider {
        let p = HeadphoneMotionProvider()
        attach(p, isFallback: settings.sourceKind == .automatic)
        return p
    }

    private func attach(_ p: MotionProvider, isFallback: Bool) {
        // Capture the kind, not the provider: `p.onFrame = { ... p ... }` would
        // make the provider own a closure that owns the provider, and nothing
        // would ever be deallocated across a source switch.
        let kind = p.kind

        p.onFrame = { [weak self] frame in
            guard let self else { return }
            // In automatic mode the fallback's samples are discarded whenever
            // the phone is live — no blending, no fighting.
            if isFallback && !self.usingFallbackNow { return }
            if !isFallback && self.usingFallbackNow && kind == .iPhone {
                // Phone came back: hand control straight back to it.
                Task { @MainActor [weak self] in
                    self?.setUsingFallback(false, engineSource: .iPhone)
                }
            }
            self.engine.ingest(frame)
            self.maybeWakeOverlay()
        }
        p.onStatusChange = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                if isFallback {
                    guard self.usingFallback else { return }
                    self.linkStatus = status
                } else {
                    self.linkStatus = status
                    if kind == .iPhone {
                        self.evaluateFallback(phoneConnected: status.connected)
                    }
                    self.isDriving = status.isDriving
                    self.applyDrivingGate()
                }
            }
        }
    }

    /// Cross-thread scratch state. The sensor queue reads these; the main
    /// actor writes them. A lock is cheaper and clearer than hopping actors
    /// on every one of the 100 samples a second.
    private nonisolated let shared = SharedRuntimeState()

    private nonisolated var usingFallbackNow: Bool { shared.usingFallback }

    private func setUsingFallback(_ value: Bool, engineSource: MotionSourceKind) {
        guard usingFallback != value else { return }
        usingFallback = value
        shared.usingFallback = value
        activeSource = engineSource
        engine.sourceKind = engineSource
        engine.reset()
    }

    private func evaluateFallback(phoneConnected: Bool) {
        guard settings.sourceKind == .automatic, fallbackProvider != nil else { return }
        setUsingFallback(!phoneConnected, engineSource: phoneConnected ? .iPhone : .mac)
    }

    /// Display links park themselves when nothing moves; nudge them when
    /// something does. Rate-limited so this is not a per-sample actor hop.
    private nonisolated func maybeWakeOverlay() {
        guard shared.shouldWake(now: hostUptime(), minInterval: 0.25) else { return }
        Task { @MainActor [weak self] in self?.overlay.wake() }
    }

    // MARK: - Calibration

    func beginCalibration() {
        guard isRunning else { return }
        isCalibrating = true
        calibrationQuality = CalibrationQuality()
        engine.beginCalibration()
    }

    func cancelCalibration() {
        isCalibrating = false
        engine.cancelCalibration()
    }

    func persistCalibration() {
        settings.calibration = engine.calibration
    }

    func setManualYawOffset(_ degrees: Double) {
        var state = engine.calibration
        state.manualOffset = degrees * .pi / 180
        engine.loadCalibration(state)
        settings.calibration = state
    }

    func clearCalibration() {
        let fresh = CalibrationState()
        engine.loadCalibration(fresh)
        settings.calibration = fresh
        engine.reset()
    }

    var currentCalibration: CalibrationState { engine.calibration }

    /// Live vehicle-frame reading, for the settings window's meter.
    var currentMotion: VehicleMotion { engine.state.load() }

    // MARK: - Status

    private func startStatusTimer() {
        statusTimer?.invalidate()
        // The menu bar does not need 100 Hz truth; 2 Hz is plenty and keeps
        // SwiftUI out of the hot path entirely.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.objectWillChange.send()
                // Background auto-refine slowly moves the yaw; persist it only
                // when it has actually drifted, not twice a second.
                let live = self.engine.calibration
                if abs(YawEstimator.angleDelta(self.settings.calibration.yaw, live.yaw)) > 0.01
                    || self.settings.calibration.isCalibrated != live.isCalibrated {
                    self.settings.calibration = live
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    // MARK: - Diagnostics for the UI

    var headphonesAvailable: Bool { HeadphoneMotionProvider.isSupportedOnThisMac }

    var motionAuthorizationDescription: String {
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .authorized: "Granted"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Not requested yet"
        @unknown default: "Unknown"
        }
    }
}
