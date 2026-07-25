//
//  SettingsView.swift
//  ChargeGuard
//
//  Plain-language settings. Everyday users pick a sensitivity preset and a
//  charging strategy; the raw engine timing lives under an Advanced disclosure
//  for anyone who wants to hand-tune it.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            powerLimitSection
            sensitivitySection
            advancedSection
            strategySection
            generalSection
            helperSection
        }
        .formStyle(.grouped)
        .frame(width: 460)
        // Push on every edit — onDisappear alone loses changes when the
        // process exits while the window is open (quit, logout).
        .onChange(of: appState.config) { _, _ in appState.push() }
    }

    // MARK: - Power limit

    private var powerLimitSection: some View {
        Section {
            Toggle("Limit how much power my Mac pulls",
                   isOn: $appState.config.powerLimitEnabled)

            if appState.config.powerLimitEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Ceiling")
                        Spacer()
                        Text("\(appState.config.powerLimitWatts) W")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: powerLimitBinding, in: 25...140, step: 5) {
                        Text("Ceiling")
                    } minimumValueLabel: {
                        Text("25 W").font(.caption2).foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Text("140 W").font(.caption2).foregroundStyle(.secondary)
                    }
                    .labelsHidden()
                }
                .padding(.top, 2)

                if let base = appState.status?.powerLimitBaseWatts {
                    Text("Your Mac alone is using about "
                         + "\(Int(base.rounded())) W right now. A ceiling "
                         + "below that leaves nothing for the battery.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 6) {
                    if appState.status?.powerLimitUnreachable == true {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Ceiling is below what your Mac needs on its own")
                    } else if isBurstCharging {
                        Image(systemName: "bolt.circle.fill")
                            .foregroundStyle(.blue)
                        Text("Charging in bursts — about "
                             + "\(appState.status?.powerLimitDutyPercent ?? 0)"
                             + "% of the time")
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Under the ceiling — charging normally")
                    }
                    Spacer()
                    // The average, not the instantaneous reading: charging runs
                    // in bursts, so a sample taken mid-pause reads far below
                    // the ceiling and looks like the app is making it up.
                    if let avg = appState.status?.powerLimitAverageWatts {
                        Text("avg \(Int(avg.rounded())) W")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else if let w = appState.status?.inputWatts {
                        Text("now \(Int(w.rounded())) W")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)

                if isBurstCharging {
                    Text(appState.status?.powerLimitHolding == true
                         ? "Right now: paused, waiting for the next burst"
                         : "Right now: charging")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if appState.status?.powerLimitUnreachable == true {
                    Text("Charging is already paused and your Mac still needs "
                         + "more than \(appState.config.powerLimitWatts) W by "
                         + "itself, so there is nothing left over to refill the "
                         + "battery. Raise the ceiling above the figure just "
                         + "under the slider, or wait for things to quiet down.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Power limit")
        } footer: {
            Text("Charging on this Mac is all-or-nothing: the moment the "
                 + "battery is allowed to charge, your Mac pulls roughly 35 W "
                 + "more — no matter what number you pick here. So ChargeGuard "
                 + "charges in short bursts and averages out to your ceiling. "
                 + "A lower ceiling means shorter, rarer bursts: a slower, "
                 + "cooler charge. The battery still fills up.\n\n"
                 + "Your apps are never slowed down — only the battery's share "
                 + "is rationed. If your Mac alone already draws more than the "
                 + "ceiling there is no room left for the battery; ChargeGuard "
                 + "says so instead of holding forever, and always lets the "
                 + "battery charge again below 20%.")
                .font(.caption2)
        }
    }

    /// True when the ceiling is actually rationing charge, i.e. charging is
    /// running less than nearly all of the time. Drives the burst wording so a
    /// ceiling set above the Mac's appetite doesn't claim to be doing work.
    private var isBurstCharging: Bool {
        guard appState.status?.powerLimitUnreachable != true else { return false }
        guard let duty = appState.status?.powerLimitDutyPercent else {
            return false
        }
        return duty < 92
    }

    private var powerLimitBinding: Binding<Double> {
        Binding(
            get: { Double(appState.config.powerLimitWatts) },
            set: { appState.config.powerLimitWatts = Int($0.rounded()) })
    }

    // MARK: - Sensitivity

    private var sensitivitySection: some View {
        Section {
            Picker("Sensitivity", selection: sensitivityBinding) {
                ForEach(Sensitivity.presets) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(sensitivityDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("How eagerly ChargeGuard steps in")
        } footer: {
            if currentSensitivity == .custom {
                Text("You've hand-tuned the timing below, so no preset is "
                     + "selected. Pick one above to go back to a simple setting.")
                    .font(.caption2)
            }
        }
    }

    private var currentSensitivity: Sensitivity { Sensitivity.matching(appState.config) }

    private var sensitivityBinding: Binding<Sensitivity> {
        Binding(
            get: { currentSensitivity },
            set: { picked in
                guard picked != .custom else { return }
                var c = appState.config
                picked.apply(to: &c)
                appState.config = c
            })
    }

    private var sensitivityDescription: String {
        switch currentSensitivity {
        case .relaxed:
            return "Waits for a clear pattern before it pauses charging, and "
                + "retries less often. Fewest interruptions."
        case .balanced:
            return "A sensible middle ground — steps in after a charger drops a "
                + "few times, retries on a moderate schedule."
        case .aggressive:
            return "Reacts to the first sign of a struggling charger and retries "
                + "quickly. Best for a badly misbehaving charger."
        case .custom:
            return "Custom timing, set in Advanced below."
        }
    }

    // MARK: - Advanced timing

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced timing") {
                Stepper(value: $appState.config.flapTrigger, in: 2...10) {
                    labeled("Drops before pausing",
                            "\(appState.config.flapTrigger)")
                }
                durationStepper("Counting drops within",
                                $appState.config.flapWindow,
                                range: 60...600, step: 30)
                durationStepper("First retry after",
                                $appState.config.probeAfter,
                                range: 60...1800, step: 60)
                durationStepper("Longest wait between retries",
                                $appState.config.probeMax,
                                range: 600...7200, step: 300)
                durationStepper("A retry must hold for",
                                $appState.config.probeGrace,
                                range: 30...600, step: 30)
            }
        } footer: {
            Text("Only needed to hand-tune how ChargeGuard reacts — the presets "
                 + "above cover most cases.")
                .font(.caption2)
        }
    }

    // MARK: - Charging strategy (Pause vs Slow)

    private var strategySection: some View {
        Section {
            Picker("Strategy", selection: strategyBinding) {
                Text("Pause charging").tag(false)
                Text("Slow charging").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if appState.config.experimentalPDDownshift {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Charge budget")
                        .font(.subheadline)
                    Picker("Charge budget",
                           selection: $appState.config.pdTargetWatts) {
                        Text("45 W").tag(45)
                        Text("36 W").tag(36)
                        Text("27 W").tag(27)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("The charger is asked to deliver at most this, so it "
                         + "stays stable while the battery keeps charging.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }

            HStack {
                Button("Check compatibility") { appState.probePD() }
                Spacer()
                compatibilityBadge
            }
            if appState.status?.pdConfirmed == true {
                Button("Test slow charging now") { appState.selfTestPD() }
                    .controlSize(.small)
                    .help("Briefly asks the charger for less power, then "
                        + "restores full power. External displays may flicker "
                        + "once. Run it while the battery is charging.")
            }
            if let msg = pdMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("When a charger can't keep up")
        } footer: {
            Text("Pause charging is the safe, proven option: charging stops so "
                 + "the charger only powers the Mac, then quietly resumes.\n\n"
                 + "Slow charging asks the charger itself for a smaller budget. "
                 + "It's experimental: on recent Apple Silicon Macs the "
                 + "controller accepts the request but macOS puts the original "
                 + "contract straight back, so it usually changes nothing. If "
                 + "you just want less wattage, use Power limit at the top — "
                 + "that one works everywhere.")
                .font(.caption2)
        }
    }

    private var strategyBinding: Binding<Bool> {
        Binding(
            get: { appState.config.experimentalPDDownshift },
            set: { wantSlow in
                if wantSlow, appState.status?.pdConfirmed != true {
                    appState.pdProbeResult =
                        "Run “Check compatibility” first to enable slow charging."
                    return
                }
                appState.config.experimentalPDDownshift = wantSlow
            })
    }

    private enum PDCompat { case compatible, recognizedEPR, incompatible, unknown }

    /// Raw probe/attempt text from the helper (or our own inline nudge).
    private var pdRawMessage: String? {
        if let r = appState.pdProbeResult, !r.isEmpty { return r }
        if let s = appState.status?.pdStatus, !s.isEmpty { return s }
        return nil
    }

    private var pdCompat: PDCompat {
        if appState.status?.pdConfirmed == true { return .compatible }
        let m = (pdRawMessage ?? "").lowercased()
        if m.contains("epr avs") || m.contains("recognized a") {
            return .recognizedEPR   // read OK; downshift-for-EPR not wired yet
        }
        // "unavailable" means the read didn't land this time (an idle port at
        // 100% does this) — that's "couldn't check", not "doesn't work".
        if m.isEmpty || m.contains("probing") || m.contains("no adapter")
            || m.contains("plug in") || m.contains("check compatibility")
            || m.contains("unavailable") {
            return .unknown
        }
        return .incompatible   // a real check ran and it isn't supported here
    }

    private var compatibilityBadge: some View {
        Group {
            switch pdCompat {
            case .compatible:
                Label("Compatible", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            case .recognizedEPR:
                Label("Recognized (EPR)", systemImage: "info.circle.fill")
                    .foregroundStyle(.blue)
            case .incompatible:
                // Not a warning. Slow charging simply isn't a thing on most
                // Apple Silicon Macs, and Power limit covers the same need.
                Label("Not available on this Mac", systemImage: "minus.circle")
                    .foregroundStyle(.secondary)
            case .unknown:
                Label("Not checked", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
    }

    /// Plain-language version of the probe result for the settings panel.
    private var pdMessage: String? {
        guard let raw = pdRawMessage else { return nil }
        let m = raw.lowercased()
        if m.contains("probing") { return "Checking…" }
        if m.contains("epr avs") || m.contains("recognized a") {
            return "ChargeGuard now reads your Mac's 28 V EPR (AVS) charging "
                + "contract — the decode that was missing. Actually slowing it "
                + "needs the renegotiation step, which we'll test on a spare "
                + "charger (not your dock)."
        }
        if appState.status?.pdConfirmed == true {
            return "ChargeGuard can read your charging contract fine, so you "
                + "can try slow charging. Heads-up: on this Mac the charger "
                + "usually snaps back to full power a moment later — Power "
                + "limit at the top is the reliable way to pull fewer watts."
        }
        if m.contains("no adapter") || m.contains("plug in") {
            return "Plug in your charger, then check again."
        }
        if m.contains("check compatibility") { return raw }  // our own nudge
        if m.contains("layout mismatch") {
            return "Slow charging can't read this Mac's charging contract yet — "
                + "high-power Macs negotiate a newer high-voltage (EPR) contract "
                + "the downshift doesn't parse. It stays off, and Pause charging "
                + "still works."
        }
        if m.contains("unavailable") {
            return "Couldn't read the charging contract just now. Nothing is "
                + "wrong — try again in a moment, ideally while the battery is "
                + "charging. Power limit at the top works either way."
        }
        return raw
    }

    // MARK: - General

    private var generalSection: some View {
        Section {
            Toggle("Start ChargeGuard at login", isOn: Binding(
                get: { appState.launchAtLogin },
                set: { appState.setLaunchAtLogin($0) }))
            Toggle("Use Low Power Mode while protecting",
                   isOn: $appState.config.useLowPowerMode)
        } header: {
            Text("General")
        } footer: {
            Text("Low Power Mode lightens the Mac's own draw while a charger is "
                 + "struggling, then restores your setting afterward.")
                .font(.caption2)
        }
    }

    // MARK: - Helper

    private var helperSection: some View {
        Section {
            LabeledContent("Status", value: helperDescription)
            HStack(spacing: 8) {
                Button("Update Helper…") { appState.installHelper() }
                Button("Remove Helper", role: .destructive) {
                    appState.removeHelper()
                }
                Spacer()
                if let v = appState.status?.helperVersion, !v.isEmpty {
                    Text("v\(v)").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Background service")
        } footer: {
            Text("Update Helper reinstalls the background daemon — use it after "
                 + "updating the app so the running service matches (asks for "
                 + "your password once).")
                .font(.caption2)
        }
    }

    private var helperDescription: String {
        switch appState.helperState {
        case .enabled: return "Running"
        case .requiresApproval: return "Waiting for approval"
        case .notRegistered: return "Not installed"
        case .error(let e): return e
        }
    }

    // MARK: - Small helpers

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

// MARK: - Sensitivity presets

/// Friendly presets that map to the engine's raw flap/probe timing. The three
/// presets cover the common cases; `.custom` means the user hand-tuned values
/// in Advanced that don't match any preset.
private enum Sensitivity: Hashable, Identifiable {
    case relaxed, balanced, aggressive, custom

    var id: Self { self }
    static let presets: [Sensitivity] = [.relaxed, .balanced, .aggressive]

    var label: String {
        switch self {
        case .relaxed: return "Relaxed"
        case .balanced: return "Balanced"
        case .aggressive: return "Aggressive"
        case .custom: return "Custom"
        }
    }

    func apply(to c: inout GuardConfig) {
        switch self {
        case .relaxed:
            c.flapTrigger = 4; c.flapWindow = 240
            c.probeAfter = 600; c.probeMax = 3600; c.probeGrace = 180
        case .balanced:
            c.flapTrigger = 3; c.flapWindow = 180
            c.probeAfter = 300; c.probeMax = 3600; c.probeGrace = 120
        case .aggressive:
            c.flapTrigger = 2; c.flapWindow = 120
            c.probeAfter = 180; c.probeMax = 1800; c.probeGrace = 60
        case .custom:
            break
        }
    }

    /// The preset whose timing matches `c`, or `.custom` if none does.
    static func matching(_ c: GuardConfig) -> Sensitivity {
        for preset in presets {
            var t = c
            preset.apply(to: &t)
            if t.flapTrigger == c.flapTrigger, t.flapWindow == c.flapWindow,
               t.probeAfter == c.probeAfter, t.probeMax == c.probeMax,
               t.probeGrace == c.probeGrace {
                return preset
            }
        }
        return .custom
    }
}
