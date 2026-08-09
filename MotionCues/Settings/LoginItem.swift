//
//  LoginItem.swift
//
//  "Open at login", via `SMAppService.mainApp` (macOS 13+). This is the
//  supported replacement for `SMLoginItemSetEnabled` and works from inside the
//  App Sandbox — no helper bundle, no launchd plist to install.
//
//  The system owns this state, not us: the user can revoke it in System
//  Settings › General › Login Items, and if they do, our copy in UserDefaults
//  would quietly disagree. So we never cache it — the toggle reads
//  `SMAppService.mainApp.status` every time.
//

import Foundation
import ServiceManagement
import os

enum LoginItem {
    private static let log = Logger(subsystem: "com.motioncues.MotionCues", category: "loginItem")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when the user has switched the app off in System Settings. The UI
    /// says so rather than silently flipping the toggle back.
    static var isBlockedByUser: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// - Returns: nil on success, or a message worth showing the user.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                // Registering while already enabled throws; make it idempotent.
                guard SMAppService.mainApp.status != .enabled else { return nil }
                try SMAppService.mainApp.register()
            } else {
                guard SMAppService.mainApp.status == .enabled else { return nil }
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            log.error("login item \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
            // The usual cause is running a build straight out of DerivedData:
            // launchd will not accept a login item from an unstable path.
            return "Could not change this. macOS only accepts login items from a stable, signed location — move MotionCues to /Applications and try again. (\(error.localizedDescription))"
        }
    }
}
