//
//  Version.swift
//  ChargeGuard
//
//  The version number. Singular, on purpose.
//
//  ChargeGuard ships as two binaries — a menu-bar app and a root daemon — but
//  it is one product, and two version numbers on screen only ever raise the
//  question "which one matters?". The answer is neither: they are always built
//  and installed together. So both compile this constant (Shared is a source
//  of every target) and the UI shows it once.
//
//  `scripts/sync-version.sh` stamps the same string into project.yml, which is
//  where xcodegen gets CFBundleShortVersionString for the app bundle, and
//  build-release.sh runs it before every build. Change the number here and
//  nowhere else.
//
//  The one time the app shows two numbers is when they genuinely differ — a
//  new app running against a helper that was never reinstalled. That is a real
//  problem the user has to fix, so it gets said out loud rather than hidden.
//

import Foundation

public enum ChargeGuardVersion {
    public static let current = "0.5.0"
}
