//
//  ContentView.swift
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var bridge: SensorBridge

    var body: some View {
        let lang = bridge.language
        NavigationStack {
            List {
                Section {
                    HStack {
                        Circle()
                            .fill(indicatorColor)
                            .frame(width: 12, height: 12)
                        Text(bridge.sender.state.localizedDescription(lang))
                            .font(.headline)
                    }
                    if let error = bridge.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(bridge.isStreaming
                           ? L10n.t(.stopStreaming, lang)
                           : L10n.t(.startStreaming, lang)) {
                        bridge.toggle()
                    }
                    .disabled(!bridge.motionAvailable)
                    .frame(maxWidth: .infinity)
                    .font(.headline)
                }

                if !bridge.sender.discovered.isEmpty {
                    Section(L10n.t(.macsFound, lang)) {
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
                    Picker(L10n.t(.language, lang), selection: $bridge.language) {
                        ForEach(AppLanguage.allCases) { option in
                            Text(option.menuTitle).tag(option)
                        }
                    }
                    Toggle(L10n.t(.keepScreenAwake, lang), isOn: $bridge.keepAwake)
                    Toggle(L10n.t(.useGPSSpeed, lang), isOn: $bridge.useLocation)
                    Toggle(L10n.t(.detectVehicle, lang), isOn: $bridge.detectDriving)
                    if bridge.detectDriving {
                        LabeledContent(L10n.t(.rightNow, lang),
                                       value: bridge.drive.state.localizedName(lang))
                        if let speed = bridge.drive.speed {
                            LabeledContent(L10n.t(.speed, lang),
                                           value: String(format: "%.0f km/h", speed * 3.6))
                        }
                    }
                } header: {
                    Text(L10n.t(.options, lang))
                } footer: {
                    if bridge.detectDriving {
                        Text(L10n.t(.detectVehicleFooter, lang))
                    }
                }

                Section {
                    LabeledContent(L10n.t(.packetsSent, lang),
                                   value: "\(bridge.sender.packetsSent)")
                    LabeledContent(L10n.t(.droppedBackpressure, lang),
                                   value: "\(bridge.sender.dropped)")
                    LabeledContent(L10n.t(.sampleRate, lang),
                                   value: "\(Int(MotionCuesService.sensorRateHz)) Hz")
                } header: {
                    Text(L10n.t(.link, lang))
                } footer: {
                    Text(L10n.t(.linkFooter, lang))
                }

                Section(L10n.t(.ifWillNotConnect, lang)) {
                    Label(L10n.t(.tipLocalNetwork, lang), systemImage: "1.circle")
                    Label(L10n.t(.tipMacRunning, lang), systemImage: "2.circle")
                    Label(L10n.t(.tipWiFiOn, lang), systemImage: "3.circle")
                }
                .font(.callout)
            }
            .navigationTitle(L10n.t(.appName, lang))
            .id(lang)
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
