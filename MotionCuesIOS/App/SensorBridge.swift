//
//  SensorBridge.swift
//
//  Joins Core Motion to the network link and owns the app's on/off state.
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class SensorBridge: ObservableObject {
    @Published private(set) var isStreaming = false
    @Published private(set) var errorMessage: String?
    @Published var useLocation = false {
        didSet {
            source.useLocation = useLocation
            UserDefaults.standard.set(useLocation, forKey: "useLocation")
            if isStreaming { restart() }
        }
    }
    @Published var keepAwake = true {
        didSet {
            UserDefaults.standard.set(keepAwake, forKey: "keepAwake")
            applyIdleTimer()
        }
    }

    let sender = MotionSender()
    let drive = DriveDetector()
    private let source = DeviceMotionSource()
    private var cancellables = Set<AnyCancellable>()

    /// Off by default: it needs the Motion & Fitness permission and a little
    /// battery, and the app is perfectly usable without it.
    @Published var detectDriving = false {
        didSet {
            UserDefaults.standard.set(detectDriving, forKey: "detectDriving")
            applyDriveDetection()
        }
    }

    init() {
        useLocation = UserDefaults.standard.bool(forKey: "useLocation")
        detectDriving = UserDefaults.standard.bool(forKey: "detectDriving")
        keepAwake = UserDefaults.standard.object(forKey: "keepAwake") as? Bool ?? true

        source.onError = { [weak self] message in
            Task { @MainActor in self?.errorMessage = message }
        }
        // Straight from the Core Motion queue into the network queue — no
        // main-actor hop on the hot path.
        source.onFrame = { [weak self] frame in
            self?.sender.send(frame)
        }
        // Republish the link's changes so SwiftUI sees them.
        sender.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        drive.$state
            .sink { [weak self] state in
                guard let self, self.detectDriving else { return }
                self.source.setDriving(state == .driving)
                self.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    var motionAvailable: Bool { source.isAvailable }

    func start() {
        guard !isStreaming else { return }
        errorMessage = nil
        isStreaming = true
        sender.start()
        source.useLocation = useLocation
        source.start()
        source.setBackgroundStreaming(useLocation)
        applyDriveDetection()
        applyIdleTimer()
    }

    func stop() {
        guard isStreaming else { return }
        isStreaming = false
        source.stop()
        sender.stop()
        drive.stop()
        source.setDriving(nil)
        applyIdleTimer()
    }

    func toggle() { isStreaming ? stop() : start() }

    private func restart() {
        stop()
        start()
    }

    private func applyDriveDetection() {
        guard isStreaming else { return }
        if detectDriving {
            drive.start()
            source.setDriving(drive.isDriving)
        } else {
            drive.stop()
            // nil means "not detecting", which the Mac treats differently
            // from "definitely parked".
            source.setDriving(nil)
        }
    }

    private func applyIdleTimer() {
        // Without a background mode, iOS suspends the app when the screen
        // locks and Core Motion stops. Keeping the display awake is the honest
        // way to stay running unless the user opts into location background
        // updates.
        UIApplication.shared.isIdleTimerDisabled = isStreaming && keepAwake
    }
}
