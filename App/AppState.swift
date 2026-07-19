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
        guard helperState == .enabled else { return }
        if let s = await xpc.fetchStatus() {
            status = s
        }
        events = await xpc.fetchEvents(limit: 60)
        if let c = await xpc.fetchConfig() {
            if syncedConfig == nil || config == syncedConfig {
                config = c
            }
            syncedConfig = c
        }
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
}
