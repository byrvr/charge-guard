//
//  HelperManager.swift
//  ChargeGuard
//
//  Registers the privileged daemon with launchd via SMAppService.
//  The user approves it once in System Settings › General › Login Items.
//

import Foundation
import ServiceManagement

enum HelperState: Equatable {
    case notRegistered
    case requiresApproval
    case enabled
    case error(String)
}

final class HelperManager {
    private let service = SMAppService.daemon(
        plistName: ChargeGuardIDs.helperPlistName)

    var state: HelperState {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .error("helper not found in app bundle")
        @unknown default: return .error("unknown SMAppService status")
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
