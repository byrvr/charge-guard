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
    /// Non-nil when the in-app helper install reported a problem to show.
    @Published var installMessage: String?

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

    /// Installs the root helper behind the native admin-password dialog — no
    /// Terminal. The NSAppleScript call blocks briefly while the system auth
    /// sheet is up; on success the daemon starts under launchd and the poll
    /// picks it up over XPC, flipping the panel to live status.
    func installHelper() {
        do {
            try PrivilegedInstaller.installHelper()
            installMessage = nil
            lastError = nil
        } catch PrivilegedInstallError.cancelled {
            // User dismissed the password dialog — nothing to report.
        } catch {
            installMessage = error.localizedDescription
            lastError = error.localizedDescription
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await refreshOnce()
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
        // Liveness is defined by XPC reachability, not SMAppService (the daemon
        // is a classic root LaunchDaemon, invisible to SMAppService). Critically,
        // do NOT set helperState from SMAppService *before* the await below:
        // that briefly flips it to .notRegistered, and during the async XPC call
        // SwiftUI renders the tall "helper not installed" screen, then snaps back
        // to the compact live view — a full-height content swap every poll that
        // reads as the whole window jerking. Fetch first, then set state.
        let lal = HelperManager.launchAtLogin
        if launchAtLogin != lal { launchAtLogin = lal }

        let s = await xpc.fetchStatus()
        guard let s else {
            // Daemon unreachable — fall back to SMAppService's view of things.
            let hs = helper.state
            if helperState != hs { helperState = hs }
            return
        }
        status = s
        if helperState != .enabled { helperState = .enabled }

        events = await xpc.fetchEvents(limit: 60)
        if let c = await xpc.fetchConfig() {
            if syncedConfig == nil || config == syncedConfig {
                config = c
            }
            syncedConfig = c
        }
    }

    /// Terminal fallback that installs the root daemon, pointed at the
    /// actually-running app bundle (works from /Applications and from a Debug
    /// build in DerivedData). The in-app "Install Helper" button is the
    /// primary path; this is shown under a "Prefer Terminal?" disclosure.
    static var installCommand: String {
        let script = Bundle.main.url(forResource: "install-daemon",
                                     withExtension: "sh")?.path
            ?? "/Applications/ChargeGuard.app/Contents/Resources/install-daemon.sh"
        return "sudo \"\(script)\" \"\(Bundle.main.bundlePath)\""
    }

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
