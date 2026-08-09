//
//  DriveDetector.swift
//
//  Works out whether you are actually in a moving car, so the cue can turn
//  itself on and off instead of being a thing you have to remember.
//
//  This lives on the phone rather than on the Mac on purpose. The obvious
//  place to detect driving is Core Location, and the obvious device to do it
//  on is the one running the overlay — but a Mac has no GPS receiver. Its
//  position comes from Wi-Fi database lookups: tens of metres of error and
//  updates every several seconds, which cannot reliably tell a car from a
//  chair. The phone has both a GPS and `CMMotionActivityManager`, whose
//  `automotive` classification is exactly this question, computed by a
//  coprocessor for almost no battery.
//
//  So the phone decides and tells the Mac, over the link that already exists.
//
//  Two signals, because either alone misfires:
//
//    * `CMMotionActivity.automotive` is quick to say yes and slow to say no —
//      it will happily keep claiming `automotive` for a while after you park.
//    * GPS speed is unambiguous when moving but says nothing at a red light.
//
//  Driving is either of them saying so; not driving requires both to have
//  been quiet for a while. That hysteresis is deliberate: flickering the
//  overlay on and off at every junction would be worse than leaving it on.
//

import Foundation
import CoreMotion
import CoreLocation

@MainActor
final class DriveDetector: NSObject, ObservableObject {
    enum State: String {
        case unknown = "Unknown"
        case driving = "In a vehicle"
        case notDriving = "Not in a vehicle"
        case unavailable = "Not available on this device"
        case denied = "Motion access denied"
    }

    @Published private(set) var state: State = .unknown
    /// Last speed seen, m/s, for the UI.
    @Published private(set) var speed: Double?

    var isDriving: Bool { state == .driving }

    private let activity = CMMotionActivityManager()
    private let location = CLLocationManager()
    private let queue = OperationQueue()

    /// Once either signal has fired, stay "driving" until both have been quiet
    /// this long. A red light is not the end of a journey.
    private let quietPeriod: TimeInterval = 90

    private var lastPositive: Date?
    private var timer: Timer?
    private var running = false

    /// Above this the car is definitely moving (≈ 11 km/h). Below it, walking
    /// pace, and not evidence of anything.
    private let drivingSpeed: Double = 3.0

    override init() {
        super.init()
        queue.name = "com.motioncues.ios.activity"
        queue.maxConcurrentOperationCount = 1
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyHundredMeters
        location.activityType = .automotiveNavigation
        location.distanceFilter = 50
    }

    static var isSupported: Bool { CMMotionActivityManager.isActivityAvailable() }

    func start() {
        guard !running else { return }
        guard Self.isSupported else { state = .unavailable; return }

        switch CMMotionActivityManager.authorizationStatus() {
        case .denied, .restricted:
            state = .denied
            return
        default:
            break
        }

        running = true
        activity.startActivityUpdates(to: queue) { [weak self] activity in
            guard let activity else { return }
            Task { @MainActor in self?.handle(activity) }
        }
        // Coarse location only: this is a "moving or not" question, so there
        // is no reason to ask for precision we do not need.
        if location.authorizationStatus == .notDetermined {
            location.requestWhenInUseAuthorization()
        }
        location.startUpdatingLocation()

        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        guard running else { return }
        running = false
        activity.stopActivityUpdates()
        location.stopUpdatingLocation()
        timer?.invalidate()
        timer = nil
        state = .unknown
        speed = nil
        lastPositive = nil
    }

    // MARK: - Signals

    private func handle(_ activity: CMMotionActivity) {
        // `confidence == .low` is noisy enough to cause false starts on a
        // train or a bus stop bench; require medium or better.
        if activity.automotive && activity.confidence != .low {
            lastPositive = Date()
        }
        evaluate()
    }

    private func evaluate() {
        guard running else { return }
        if let speed, speed > drivingSpeed {
            lastPositive = Date()
        }
        guard let lastPositive else {
            state = .notDriving
            return
        }
        state = Date().timeIntervalSince(lastPositive) < quietPeriod ? .driving : .notDriving
    }
}

extension DriveDetector: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let value = last.speed >= 0 ? last.speed : nil
        Task { @MainActor in
            self.speed = value
            self.evaluate()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.speed = nil }
    }
}
