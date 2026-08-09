//
//  DeviceMotionSource.swift
//
//  Core Motion on the phone. This is the accurate sensor path — the reason the
//  companion exists at all.
//
//  Reference frame: `.xArbitraryZVertical`.
//
//  Not `.xMagneticNorthZVertical` or `.xTrueNorthZVertical`, deliberately.
//  Those pull in the magnetometer, and inside a car body — steel shell, door
//  speakers, the phone's own charging cable — the magnetometer reads garbage
//  and would drag the whole attitude estimate with it. `.xArbitraryZVertical`
//  fixes Z to true vertical from the accelerometer and leaves the heading
//  arbitrary but stable. The heading we actually need (the car's forward axis)
//  is recovered on the Mac from the driving itself, which is both more robust
//  and one fewer sensor to trust.
//
//  Rate: 100 Hz. Vehicle manoeuvres live below ~2 Hz, so this is far more than
//  Nyquist demands; the surplus is there so the filters have clean, densely
//  sampled data to work with and so a dropped packet costs 10 ms rather than
//  50 ms.
//

import Foundation
import CoreMotion
import CoreLocation
import simd

final class DeviceMotionSource: NSObject, CLLocationManagerDelegate {
    private let motion = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.motioncues.ios.motion"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()

    private let location = CLLocationManager()
    private var seq: UInt32 = 0
    private var currentSpeed: Double?
    /// Set from the main actor; read on the Core Motion queue. A one-frame
    /// stale read of a Bool is harmless and this avoids a lock on the hot path.
    private var drivingFlag: Bool?

    /// The phone's verdict on whether you are in a moving vehicle, forwarded
    /// to the Mac in every frame. `nil` disables the feature end to end.
    func setDriving(_ value: Bool?) { drivingFlag = value }

    /// Delivered on the motion queue at sensor rate.
    var onFrame: ((MotionFrame) -> Void)?
    /// Delivered on the main queue.
    var onError: ((String) -> Void)?

    /// GPS speed is optional. It buys two things: the lateral roll
    /// compensation on the Mac (a_lat ≈ v·ω) and a sanity check on the
    /// calibration. It costs battery, so it is opt-in.
    var useLocation = false

    var isAvailable: Bool { motion.isDeviceMotionAvailable }
    private(set) var isRunning = false

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        location.activityType = .automotiveNavigation
        location.distanceFilter = kCLDistanceFilterNone
    }

    func start() {
        guard !isRunning else { return }
        guard motion.isDeviceMotionAvailable else {
            onError?("Device motion is not available on this device.")
            return
        }
        isRunning = true
        seq = 0

        motion.deviceMotionUpdateInterval = 1.0 / MotionCuesService.sensorRateHz
        motion.showsDeviceMovementDisplay = false
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] dm, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async { self.onError?(error.localizedDescription) }
                return
            }
            guard let dm else { return }
            self.emit(dm)
        }

        if useLocation { startLocation() }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        motion.stopDeviceMotionUpdates()
        location.stopUpdatingLocation()
        currentSpeed = nil
    }

    private func startLocation() {
        switch location.authorizationStatus {
        case .notDetermined:
            location.requestWhenInUseAuthorization()
        case .denied, .restricted:
            onError?("Location denied — lateral roll compensation will be skipped.")
            return
        default:
            break
        }
        location.startUpdatingLocation()
    }

    /// Keeping the sensors alive with the screen off requires the `location`
    /// background mode, which is only honest because we genuinely use
    /// location. Off by default.
    func setBackgroundStreaming(_ enabled: Bool) {
        guard useLocation else { return }
        if enabled {
            location.allowsBackgroundLocationUpdates = true
            location.pausesLocationUpdatesAutomatically = false
        } else {
            location.allowsBackgroundLocationUpdates = false
        }
    }

    private func emit(_ dm: CMDeviceMotion) {
        seq &+= 1
        let q = dm.attitude.quaternion
        let frame = MotionFrame(
            seq: seq,
            senderTime: dm.timestamp,
            quaternion: SIMD4<Double>(q.x, q.y, q.z, q.w),
            userAcceleration: SIMD3<Double>(dm.userAcceleration.x,
                                            dm.userAcceleration.y,
                                            dm.userAcceleration.z),
            rotationRate: SIMD3<Double>(dm.rotationRate.x,
                                        dm.rotationRate.y,
                                        dm.rotationRate.z),
            gravity: SIMD3<Double>(dm.gravity.x, dm.gravity.y, dm.gravity.z),
            speed: currentSpeed,
            isDriving: drivingFlag
        )
        onFrame?(frame)
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        // CLLocation reports a negative speed when it has no valid estimate.
        currentSpeed = last.speed >= 0 ? last.speed : nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        currentSpeed = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if useLocation, isRunning,
           manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }
}
