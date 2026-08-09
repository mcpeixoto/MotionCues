//
//  ContentView.swift
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var bridge: SensorBridge

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Circle()
                            .fill(indicatorColor)
                            .frame(width: 12, height: 12)
                        Text(bridge.sender.state.description)
                            .font(.headline)
                    }
                    if let error = bridge.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(bridge.isStreaming ? "Stop streaming" : "Start streaming") {
                        bridge.toggle()
                    }
                    .disabled(!bridge.motionAvailable)
                    .frame(maxWidth: .infinity)
                    .font(.headline)
                }

                if !bridge.sender.discovered.isEmpty {
                    Section("Macs found") {
                        ForEach(bridge.sender.discovered, id: \.self) { name in
                            HStack {
                                Text(name)
                                Spacer()
                                if bridge.sender.preferredPeer == name {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                bridge.sender.preferredPeer =
                                    bridge.sender.preferredPeer == name ? nil : name
                            }
                        }
                    }
                }

                Section {
                    Toggle("Keep screen awake while streaming", isOn: $bridge.keepAwake)
                    Toggle("Use GPS speed", isOn: $bridge.useLocation)
                    Toggle("Detect when you're in a vehicle", isOn: $bridge.detectDriving)
                    if bridge.detectDriving {
                        LabeledContent("Right now", value: bridge.drive.state.rawValue)
                        if let speed = bridge.drive.speed {
                            LabeledContent("Speed", value: String(format: "%.0f km/h", speed * 3.6))
                        }
                    }
                } header: {
                    Text("Options")
                } footer: {
                    if bridge.detectDriving {
                        Text("Your Mac hides the cues when this says you're not in a vehicle, so you don't have to remember to switch them off. It uses the motion coprocessor, which costs very little battery.")
                    }
                }

                Section {
                    LabeledContent("Packets sent", value: "\(bridge.sender.packetsSent)")
                    LabeledContent("Dropped (backpressure)", value: "\(bridge.sender.dropped)")
                    LabeledContent("Sample rate",
                                   value: "\(Int(MotionCuesService.sensorRateHz)) Hz")
                } header: {
                    Text("Link")
                } footer: {
                    Text("GPS speed lets the Mac compensate for body roll in corners (lateral acceleration ≈ speed × yaw rate). It costs battery, so it is optional. Everything stays on your devices — the link is a direct UDP stream on the local network or over peer-to-peer Wi-Fi, with no Internet involved.")
                }

                Section("If it will not connect") {
                    Label("Both devices need Local Network permission. iOS asks the first time; if you said no, turn it back on in Settings › MotionCues.", systemImage: "1.circle")
                    Label("Make sure MotionCues is running on the Mac and set to Automatic or iPhone.", systemImage: "2.circle")
                    Label("No Wi-Fi in the car is fine — leave Wi-Fi switched ON anyway, because peer-to-peer discovery uses the Wi-Fi radio.", systemImage: "3.circle")
                }
                .font(.callout)
            }
            .navigationTitle("MotionCues")
        }
    }

    private var indicatorColor: Color {
        switch bridge.sender.state {
        case .streaming: .green
        case .connecting, .searching: .orange
        case .failed: .red
        case .idle: .secondary
        }
    }
}
