//
//  GuardModels.swift
//  ChargeGuard
//
//  Types shared between the app and the privileged helper.
//

import Foundation

/// Tunable behavior of the guard engine.
public struct GuardConfig: Codable, Equatable, Sendable {
    /// Master switch. When off, the engine only observes.
    public var protectionEnabled: Bool = true
    /// AC attaches within `flapWindow` that mean "the charger is flapping".
    public var flapTrigger: Int = 3
    /// Sliding window for counting attaches, in seconds.
    public var flapWindow: TimeInterval = 180
    /// First delay before re-trying charging after the guard engages.
    public var probeAfter: TimeInterval = 300
    /// Maximum backoff between charge probes.
    public var probeMax: TimeInterval = 3600
    /// How long a probe must survive before the guard disengages.
    public var probeGrace: TimeInterval = 120
    /// A detach gap longer than this suggests a deliberate replug/swap.
    public var swapGap: TimeInterval = 30
    /// Probe delay used after a suspected charger swap.
    public var swapProbeDelay: TimeInterval = 45
    /// After a recent guard, a single drop re-engages immediately.
    public var retriggerWindow: TimeInterval = 600
    /// Engage AC Low Power Mode while guarding.
    public var useLowPowerMode: Bool = true

    /// EXPERIMENTAL: when guarding, try to renegotiate the USB-C PD contract
    /// down to `pdTargetWatts` (driving the Type-C controller) instead of
    /// inhibiting charging. Off by default; only takes effect after a probe
    /// confirms this machine's controller uses the standard register layout.
    ///
    /// NOTE: on Apple-firmware Type-C controllers (CD3217 with Apple's
    /// register map) the write is accepted but the SoC's own policy manager
    /// re-asserts the original contract, so this never actually lowers the
    /// budget. `powerLimitEnabled` is the lever that works.
    public var experimentalPDDownshift: Bool = false
    /// Target power budget for the downshift (nearest advertised rail at or
    /// below this is chosen: 45W/36W/27W).
    public var pdTargetWatts: Int = 45

    /// Cap total draw from the adapter. Implemented with the one lever Apple
    /// Silicon actually honors: pause battery charging while the Mac is
    /// pulling more than `powerLimitWatts`, resume once it drops back under.
    /// System load is never throttled — only the charging half is.
    public var powerLimitEnabled: Bool = false
    /// Watt ceiling for `powerLimitEnabled`.
    public var powerLimitWatts: Int = 60

    public init() {}

    /// Clamps every field to a sane range. The helper applies this to any
    /// config arriving over XPC, so a hostile or buggy client cannot drive
    /// the engine into degenerate behavior (e.g. flapTrigger 0 = guard on
    /// every attach, probeMax 0 = probe storm).
    public func sanitized() -> GuardConfig {
        var c = self
        c.flapTrigger = min(max(c.flapTrigger, 2), 10)
        c.flapWindow = min(max(c.flapWindow, 60), 600)
        c.probeAfter = min(max(c.probeAfter, 60), 1800)
        c.probeGrace = min(max(c.probeGrace, 30), 600)
        c.probeMax = min(max(c.probeMax, c.probeAfter), 7200)
        c.swapGap = min(max(c.swapGap, 5), 300)
        c.swapProbeDelay = min(max(c.swapProbeDelay, 10), 600)
        c.retriggerWindow = min(max(c.retriggerWindow, 0), 3600)
        c.pdTargetWatts = min(max(c.pdTargetWatts, 27), 60)
        c.powerLimitWatts = min(max(c.powerLimitWatts, 25), 140)
        return c
    }
}

/// What the engine is currently doing.
public enum GuardMode: String, Codable, Sendable {
    /// Watching; charging is under macOS control.
    case observing
    /// Charger misbehaved; charging is inhibited.
    case guarding
    /// Temporarily re-enabled charging to see if the charger holds.
    case probing
}

/// A snapshot of engine + power state for the UI.
public struct GuardStatus: Codable, Sendable {
    public var mode: GuardMode = .observing
    public var protectionEnabled: Bool = true
    public var isOnAC: Bool = false
    public var batteryPercent: Int = 0
    public var isCharging: Bool = false
    public var chargingInhibited: Bool = false
    /// Negotiated adapter power budget in watts (from SMC ACPW), 0 if none.
    public var adapterWatts: Double = 0
    /// Live draw from the adapter in watts (from SMC PDTR), if readable.
    public var inputWatts: Double?
    /// Battery charge current in mA (from SMC CHBI).
    public var chargeCurrentMA: Int = 0
    /// AC attaches seen within the flap window.
    public var recentAttaches: Int = 0
    /// Seconds until the next charge probe, if one is scheduled.
    public var nextProbeIn: TimeInterval?
    /// Current probe backoff, seconds.
    public var currentBackoff: TimeInterval = 0
    /// Human-readable result of the last PD-downshift probe/attempt.
    public var pdStatus: String = ""
    /// True once a probe confirmed the controller's register layout.
    public var pdConfirmed: Bool = false
    /// Watts of an active PD downshift, if one is currently applied.
    public var pdActiveWatts: Int?
    /// True while the power limit is actively holding charging paused.
    public var powerLimitHolding: Bool = false
    public var helperVersion: String = ""

    public init() {}
}

/// One line of the engine's activity log.
public struct GuardEvent: Codable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case info, guardOn, guardOff, probe, warning
    }

    public var id: UUID = UUID()
    public var date: Date
    public var kind: Kind
    public var message: String

    public init(date: Date = Date(), kind: Kind, message: String) {
        self.date = date
        self.kind = kind
        self.message = message
    }
}

public enum ChargeGuardIDs {
    /// Mach service name the helper listens on (must match the launchd plist).
    public static let helperMachService = "dev.byrvr.ChargeGuard.helper"
    /// File name of the daemon plist inside Contents/Library/LaunchDaemons.
    public static let helperPlistName = "dev.byrvr.ChargeGuard.helper.plist"
}
