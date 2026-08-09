//
//  MotionCuesIOSApp.swift
//

import SwiftUI

@main
struct MotionCuesIOSApp: App {
    @StateObject private var bridge = SensorBridge()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bridge)
        }
    }
}
