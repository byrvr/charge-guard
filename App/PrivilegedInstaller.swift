//
//  PrivilegedInstaller.swift
//  ChargeGuard
//
//  Installs the privileged root helper by running the bundled install script
//  behind the NATIVE macOS admin-password dialog — no Terminal, no sudo typed
//  by the user. Uses AppleScript's `do shell script … with administrator
//  privileges`, run in-process via NSAppleScript so the authentication prompt
//  is attributed to ChargeGuard (its name and icon), not to "osascript".
//
//  This is a sudo-equivalent: whatever the script does runs as root, so the
//  script stays inside the (root/admin-owned) app bundle and is never taken
//  from a user-writable location. The longer-term plan is to move to
//  SMAppService once the app is signed with a real (even free) identity, which
//  replaces this with a one-toggle Login Items approval.
//

import Foundation
import AppKit

enum PrivilegedInstallError: LocalizedError {
    case scriptMissing
    case cancelled
    case failed(code: Int, message: String)
    case compileFailed

    var errorDescription: String? {
        switch self {
        case .scriptMissing:
            return "The installer script is missing from the app bundle."
        case .cancelled:
            return "Installation was cancelled."
        case .failed(let code, let message):
            let detail = message.isEmpty ? "" : " \(message)"
            return "Installation failed (exit \(code)).\(detail)"
        case .compileFailed:
            return "Could not prepare the installer."
        }
    }
}

enum PrivilegedInstaller {
    /// Runs `install-daemon.sh` (bundled in Resources) as root behind the
    /// native admin-password dialog. The running app's bundle path is passed
    /// as an argument so the script finds the embedded helper wherever the app
    /// lives — a Debug build in DerivedData as well as /Applications.
    /// Must be called on the main thread (NSAppleScript is main-thread only).
    @MainActor
    static func installHelper() throws {
        try runAsRoot(scriptResource: "install-daemon")
    }

    @MainActor
    private static func runAsRoot(scriptResource name: String) throws {
        guard let scriptURL = Bundle.main.url(forResource: name,
                                              withExtension: "sh") else {
            throw PrivilegedInstallError.scriptMissing
        }

        // `quoted form of` performs the shell quoting at AppleScript runtime;
        // we only need valid AppleScript string literals for the two paths.
        let source = "do shell script \"/bin/bash \" & quoted form of "
            + appleScriptLiteral(scriptURL.path)
            + " & \" \" & quoted form of "
            + appleScriptLiteral(Bundle.main.bundlePath)
            + " with administrator privileges"

        guard let script = NSAppleScript(source: source) else {
            throw PrivilegedInstallError.compileFailed
        }

        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let code = (errorInfo["NSAppleScriptErrorNumber"] as? Int) ?? 0
            let message =
                (errorInfo["NSAppleScriptErrorMessage"] as? String) ?? ""
            // -128 is the standard "user cancelled" AppleScript error.
            if code == -128 { throw PrivilegedInstallError.cancelled }
            throw PrivilegedInstallError.failed(code: code, message: message)
        }
    }

    /// Escapes a Swift string into an AppleScript string literal, quotes included.
    private static func appleScriptLiteral(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
