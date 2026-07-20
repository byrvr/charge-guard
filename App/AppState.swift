//
//  AppState.swift
//  ChargeGuard
//

import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var status: GuardStatus?
    @Published var events: [GuardEvent] = []
    @Published var config = GuardConfig()
    @Published var helperState: HelperState = .notRegistered
    @Published var lastError: String?

    private let xpc = XPCClient()
    private let helper = HelperManager()
    private var pollTask: Task<Void, Never>?
    /// Last config known to match the helper's copy. The poll only adopts
    /// the helper's config when there is no unsynced local edit, so the
    /// 2-second refresh cannot clobber values mid-edit in Settings.
    private var syncedConfig: GuardConfig?

    init() {
        refreshHelperState()
        startPolling()
    }

    var menuBarSymbol: String {
        switch status?.mode {
        case .guarding: return "bolt.shield.fill"
        case .probing: return "bolt.badge.clock"
        default:
            return (status?.isCharging ?? false)
                ? "bolt.fill" : "bolt.shield"
        }
    }

    func refreshHelperState() {
        helperState = helper.state
        launchAtLogin = HelperManager.launchAtLogin
    }

    @Published var launchAtLogin = false

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try HelperManager.setLaunchAtLogin(enabled)
            lastError = nil
        } catch {
            lastError = "Launch at login: " + error.localizedDescription
        }
        launchAtLogin = HelperManager.launchAtLogin
    }

    func installHelper() {
        do {
            try helper.register()
            lastError = nil
        } catch {
            lastError = "Helper registration failed: " +
                error.localizedDescription
        }
        refreshHelperState()
        if helperState == .requiresApproval {
            HelperManager.openLoginItemsSettings()
        }
    }

    func removeHelper() {
        do {
            try helper.unregister()
            lastError = nil
        } catch {
            lastError = "Helper removal failed: " + error.localizedDescription
        }
        refreshHelperState()
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshOnce()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func refreshOnce() async {
        refreshHelperState()
        // The helper is installed as a classic root LaunchDaemon, so its
        // liveness is defined by XPC reachability — not by SMAppService,
        // which cannot register ad-hoc-signed builds. A successful status
        // call means the daemon is running.
        let s = await xpc.fetchStatus()
        if let s {
            status = s
            helperState = .enabled
        }
        guard helperState == .enabled else { return }
        events = await xpc.fetchEvents(limit: 60)
        if let c = await xpc.fetchConfig() {
            if syncedConfig == nil || config == syncedConfig {
                config = c
            }
            syncedConfig = c
        }
    }

    /// The one-line command that installs the root daemon.
    static let installCommand =
        "sudo \"/Applications/ChargeGuard.app/Contents/Resources/install-daemon.sh\""

    func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.installCommand, forType: .string)
    }

    func setProtection(enabled: Bool) {
        config.protectionEnabled = enabled
        push()
    }

    func push() {
        let cfg = config
        Task {
            if await xpc.push(config: cfg) {
                syncedConfig = cfg
            }
            await refreshOnce()
        }
    }

    func forceCharging() {
        Task {
            await xpc.forceCharging()
            await refreshOnce()
        }
    }

    @Published var pdProbeResult: String?

    func probePD() {
        pdProbeResult = "Probing…"
        Task {
            let result = await xpc.probePDController()
            pdProbeResult = result
            await refreshOnce()
        }
    }
}
