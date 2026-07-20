//
//  MenuView.swift
//  ChargeGuard
//
//  The menu bar panel: live status, recent activity, quick actions.
//

import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if appState.helperState == .enabled {
                statusGrid
                Divider()
                EventLogView(events: appState.events)
                Divider()
                footer
            } else {
                helperSetup
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Image(systemName: appState.menuBarSymbol)
                .font(.title2)
                .foregroundStyle(headerColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("ChargeGuard").font(.headline)
                Text(modeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if appState.status != nil {
                // Bound to the local config (not the polled helper snapshot)
                // so the switch doesn't flick back while the push is in
                // flight.
                Toggle("", isOn: Binding(
                    get: { appState.config.protectionEnabled },
                    set: { appState.setProtection(enabled: $0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help("Protection on/off")
            }
        }
    }

    // One accent only: orange while the guard is actively protecting.
    // Everything else stays monochrome.
    private var headerColor: Color {
        appState.status?.mode == .guarding ? .orange : .primary
    }

    private var modeDescription: String {
        guard appState.helperState == .enabled else {
            return "Helper not installed"
        }
        guard let s = appState.status else { return "Connecting to helper…" }
        switch s.mode {
        case .observing:
            return s.isOnAC ? "Charger behaving — macOS in control"
                            : "On battery — watching"
        case .guarding:
            if let next = s.nextProbeIn {
                return "Charger protected — next charge try in \(Int(next))s"
            }
            return "Charger protected — charging paused"
        case .probing:
            return "Testing the charger — charging enabled"
        }
    }

    private var statusGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            if let s = appState.status {
                GridRow {
                    statCell("Battery", "\(s.batteryPercent)%",
                             s.isCharging ? "charging" : (s.isOnAC ?
                             "on AC, not charging" : "discharging"))
                    statCell("Adapter", s.adapterWatts > 0 ?
                             String(format: "%.0f W", s.adapterWatts) : "—",
                             adapterCaption(s))
                }
                GridRow {
                    statCell("Charge current",
                             s.chargeCurrentMA > 0 ?
                             "\(s.chargeCurrentMA) mA" : "0 mA",
                             s.chargingInhibited ? "inhibited by guard"
                                                 : "firmware controlled")
                    statCell("Drops seen", "\(s.recentAttaches)",
                             "in the flap window")
                }
            }
        }
    }

    private func adapterCaption(_ s: GuardStatus) -> String {
        guard s.isOnAC else { return "not connected" }
        if let draw = s.inputWatts {
            return String(format: "drawing %.0f W now", draw)
        }
        return "negotiated budget"
    }

    private func statCell(_ title: String, _ value: String,
                          _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .rounded).weight(.semibold))
            Text(caption).font(.caption2).foregroundStyle(.tertiary)
        }
        .gridColumnAlignment(.leading)
    }

    private var helperSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The privileged helper isn't running yet.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("ChargeGuard needs a small root daemon to control the SMC "
                 + "charging gate. Install it once by running this in "
                 + "Terminal:")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(AppState.installCommand)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Copy Command") { appState.copyInstallCommand() }
                    .buttonStyle(.borderedProminent)
                Text("then paste into Terminal and press Return")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text("The window will switch to live status a second after the "
                 + "daemon starts. To remove it later: sudo "
                 + "…/Resources/uninstall-daemon.sh")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            if appState.status?.mode == .guarding {
                Button("Charge Now") { appState.forceCharging() }
                    .help("Lift the guard and let charging run — it " +
                          "re-engages if the charger flaps again")
            }
            Spacer()
            // SettingsLink alone opens the window behind other apps when
            // triggered from a menu bar panel (LSUIElement app is not
            // active) — activate first, then open.
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit ChargeGuard (the helper keeps protecting)")
        }
    }
}

struct EventLogView: View {
    let events: [GuardEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Activity").font(.caption).foregroundStyle(.secondary)
            if events.isEmpty {
                Text("No events yet.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(events.suffix(30).reversed()) { event in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: symbol(for: event.kind))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 12)
                                Text(event.message)
                                    .font(.caption2)
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                                Text(event.date, style: .time)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
        }
    }

    private func symbol(for kind: GuardEvent.Kind) -> String {
        switch kind {
        case .info: return "info.circle"
        case .guardOn: return "shield.fill"
        case .guardOff: return "shield.slash"
        case .probe: return "bolt.badge.clock"
        case .warning: return "exclamationmark.triangle"
        }
    }

}
