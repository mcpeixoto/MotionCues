//
//  SharedRuntimeState.swift
//
//  The two or three scalars that genuinely have to be read from the sensor
//  queue and written from the main actor. Kept in one small lock-protected
//  object so the concurrency story is obvious rather than sprinkled through
//  the coordinator.
//

import Foundation

final class SharedRuntimeState: @unchecked Sendable {
    private let lock = NSLock()
    private var _usingFallback = false
    private var _lastWake: Double = 0

    var usingFallback: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _usingFallback }
        set { lock.lock(); _usingFallback = newValue; lock.unlock() }
    }

    /// Rate limiter for waking the overlay's display links.
    /// - Returns: true at most once per `minInterval`.
    func shouldWake(now: Double, minInterval: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard now - _lastWake > minInterval else { return false }
        _lastWake = now
        return true
    }
}
