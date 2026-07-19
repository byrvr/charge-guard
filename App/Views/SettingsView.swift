//
//  SettingsView.swift
//  ChargeGuard
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section("Flap detection") {
                Stepper(value: $appState.config.flapTrigger, in: 2...10) {
                    labeled("Drops to trigger the guard",
                            "\(appState.config.flapTrigger)")
                }
                durationStepper("Within a window of",
                                $appState.config.flapWindow,
                                range: 60...600, step: 30)
            }

            Section("Charge probing") {
                durationStepper("First retry after",
                                $appState.config.probeAfter,
                                range: 60...1800, step: 60)
                durationStepper("Maximum backoff",
                                $appState.config.probeMax,
                                range: 600...7200, step: 300)
                durationStepper("Probe must survive",
                                $appState.config.probeGrace,
                                range: 30...600, step: 30)
            }

            Section("Extras") {
                Toggle("Start ChargeGuard at login",
                       isOn: Binding(
                        get: { appState.launchAtLogin },
                        set: { appState.setLaunchAtLogin($0) }))
                Toggle("Use AC Low Power Mode while guarding",
                       isOn: $appState.config.useLowPowerMode)
                Text("Reduces the Mac's own draw so a weak charger has " +
                     "an easier time. Restored when the guard lifts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Helper") {
                LabeledContent("Daemon",
                               value: helperDescription)
                HStack {
                    Button("Remove Helper", role: .destructive) {
                        appState.removeHelper()
                    }
                    Spacer()
                    if let v = appState.status?.helperVersion, !v.isEmpty {
                        Text("v\(v)").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        // Push on every edit — onDisappear alone loses changes when the
        // process exits while the window is open (quit, logout).
        .onChange(of: appState.config) { _, _ in appState.push() }
    }

    private var helperDescription: String {
        switch appState.helperState {
        case .enabled: return "Running"
        case .requiresApproval: return "Waiting for approval in Login Items"
        case .notRegistered: return "Not installed"
        case .error(let e): return e
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func durationStepper(_ title: String,
                                 _ binding: Binding<TimeInterval>,
                                 range: ClosedRange<TimeInterval>,
                                 step: TimeInterval) -> some View {
        Stepper(value: binding, in: range, step: step) {
            labeled(title, format(binding.wrappedValue))
        }
    }

    private func format(_ t: TimeInterval) -> String {
        t >= 120 ? String(format: "%.0f min", t / 60) : "\(Int(t)) s"
    }
}
