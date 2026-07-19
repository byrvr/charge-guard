//
//  GuardEngine.swift
//  ChargeGuardHelper
//
//  The state machine that keeps a Mac stable on a weak/flaky USB-C charger.
//
//  A mis-rated charger advertises more power than it can sustain; the Mac
//  draws the full negotiated budget while charging, the charger trips its
//  protection, drops, recovers, and the cycle repeats — an endless AC
//  attach/detach flap. Apple Silicon exposes no charge-current limit, so
//  the working lever is binary: inhibit charging (SMC key CHTE) so the
//  adapter carries only system load, then periodically probe whether the
//  charger can take real charging again.
//
//  All timing uses an uptime clock that pauses during system sleep, so
//  slept time never counts toward flap windows or probe grace periods.
//

import Foundation

final class GuardEngine {
    private(set) var config: GuardConfig
    private let smc: SMCService
    private let monitor: PowerMonitor
    private let pd = PDController()

    // PD-downshift state. `pdConfirmed` gates writes: it is only set by a
    // successful read-only probe. `pdActiveWatts` records an applied
    // downshift so it can be restored on disengage.
    private var pdConfirmed = false
    private var pdActiveWatts: Int?
    private var pdStatus = ""
    private var lastPDReapplyAt: TimeInterval = 0
    // PD IOKit calls are synchronous and could, in the worst case, wedge in
    // the kernel. They run on their own queue behind a hard deadline so the
    // engine/XPC/shutdown queue is never blocked for longer than that.
    private let pdQueue = DispatchQueue(label: "dev.byrvr.ChargeGuard.pd")

    private var mode: GuardMode = .observing
    private var isOnAC = false
    private var attachTimes: [TimeInterval] = []
    private var backoff: TimeInterval
    private var nextProbeAt: TimeInterval = 0
    private var probeDeadline: TimeInterval = 0
    private var lastACSeen: TimeInterval = 0
    private var lastDetach: TimeInterval = 0
    private var lastGuardOff: TimeInterval = 0
    private var lpmBaseline: Int?

    private var events: [GuardEvent] = []
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "dev.byrvr.ChargeGuard.engine")

    private static let stateDir = URL(fileURLWithPath:
        "/Library/Application Support/ChargeGuard")
    private static let configURL = stateDir.appendingPathComponent("config.json")
    private static let lpmURL = stateDir.appendingPathComponent("lpm.saved")

    /// Seconds of machine uptime, excluding time spent asleep.
    private static func uptime() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }

    init(smc: SMCService, monitor: PowerMonitor) {
        self.smc = smc
        self.monitor = monitor
        self.config = Self.loadConfig()
        self.backoff = config.probeAfter

        // Crash recovery: never leave a stale inhibit or Low Power Mode
        // behind from a previous unclean exit.
        try? smc.setChargingInhibited(false)
        recoverStaleLPM()
        // If a PD cap survived an unclean exit, restore the original policy.
        // No-op unless a marker exists, so users who never enabled downshift
        // never touch the PD write path on boot.
        _ = pdBounded(8, false) { [pd] in pd.recoverFromCrashIfNeeded(); return true }

        let snap = PowerMonitor.snapshot()
        isOnAC = snap.isOnAC
        if isOnAC { lastACSeen = Self.uptime() }
        log(.info, "engine started (source: \(isOnAC ? "AC" : "battery"), " +
            "battery \(snap.batteryPercent)%)")

        monitor.onPowerSourceChange = { [weak self] snap in
            self?.queue.async { self?.powerSourceChanged(snap) }
        }
        monitor.onWake = { [weak self] in
            self?.queue.async { self?.systemWoke() }
        }
        monitor.start()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.housekeeping() }
        t.resume()
        timer = t
    }

    // MARK: - Event handling

    private func powerSourceChanged(_ snap: PowerSnapshot) {
        let now = Self.uptime()
        guard snap.isOnAC != isOnAC else { return }
        isOnAC = snap.isOnAC
        if isOnAC {
            lastACSeen = now
            attachTimes.append(now)
            pruneAttaches(now)
            log(.info, "AC attached (\(attachTimes.count) in last " +
                "\(Int(config.flapWindow))s)")
            guard config.protectionEnabled else { return }
            if mode == .observing {
                if attachTimes.count >= config.flapTrigger {
                    engageGuard(now)
                } else if lastGuardOff > 0,
                          now - lastGuardOff <= config.retriggerWindow {
                    // The guard was on minutes ago and the charger dropped
                    // again — skip the multi-strike confirmation.
                    log(.info, "charger dropped again shortly after guard " +
                        "off — re-engaging immediately")
                    engageGuard(now)
                }
            } else if mode == .guarding, lastDetach > 0,
                      now - lastDetach > config.swapGap {
                // Re-attach after a real gap: likely a charger swap.
                // Probe soon so a good charger isn't stuck guarded.
                if nextProbeAt - now > config.swapProbeDelay {
                    nextProbeAt = now + config.swapProbeDelay
                    log(.info, "re-attach after a gap — early charge probe " +
                        "in \(Int(config.swapProbeDelay))s")
                }
            }
        } else {
            lastDetach = now
            log(.info, "AC detached")
            if mode == .probing {
                probeFailed(now)
            }
        }
    }

    private func systemWoke() {
        // A probe that spanned sleep observed nothing; void it. The uptime
        // clock already excludes slept time, so this is belt-and-braces
        // against a charger that flapped while the machine was suspended.
        if mode == .probing {
            log(.info, "system woke during a probe — voiding it")
            inhibit(true)
            mode = .guarding
            nextProbeAt = Self.uptime() + backoff
        }
        let snap = PowerMonitor.snapshot()
        queueSourceRefresh(snap)
    }

    private func queueSourceRefresh(_ snap: PowerSnapshot) {
        if snap.isOnAC != isOnAC {
            powerSourceChanged(snap)
        }
    }

    private func housekeeping() {
        let now = Self.uptime()
        pruneAttaches(now)

        // Poll fallback in case a notification was missed.
        queueSourceRefresh(PowerMonitor.snapshot())

        // "Adapter removed" must measure time since AC was last PRESENT,
        // not since the last attach transition.
        if isOnAC { lastACSeen = now }

        // A CHTE write we still owe (previous attempt failed) is retried
        // in every mode — disengageGuard's enable must eventually stick
        // even though reconcileInhibit no longer applies in .observing.
        if let owed = pendingInhibitWrite {
            inhibit(owed)
        }

        guard config.protectionEnabled else { return }
        reconcileInhibit()

        switch mode {
        case .observing:
            break
        case .guarding:
            if !isOnAC, now - lastACSeen > 300 {
                disengageGuard("adapter removed for >5 min")
            } else if let target = pdActiveWatts, isOnAC {
                // PD-downshift mode is a stable end state — charging
                // continues at the lower budget. Re-apply if a renegotiation
                // (e.g. a brief flap) reset the contract back up, but no more
                // than once a minute so we never churn the controller.
                if Int(smc.adapterWatts().rounded()) > target + 5,
                   now - lastPDReapplyAt >= 60 {
                    lastPDReapplyAt = now
                    if !attemptPDDownshift() {
                        // PD downshift stopped working — fall back to the
                        // proven charge-inhibit guard instead of silently
                        // providing no protection.
                        log(.warning, "PD downshift no longer holds — "
                            + "falling back to charge-inhibit")
                        pdActiveWatts = nil
                        inhibit(true)
                        backoff = config.probeAfter
                        nextProbeAt = now + backoff
                    }
                }
            } else if isOnAC, now >= nextProbeAt {
                startProbe(now)
            }
        case .probing:
            if now >= probeDeadline {
                disengageGuard("charging survived " +
                    "\(Int(config.probeGrace))s probe")
            }
        }
    }

    // MARK: - State transitions

    private func engageGuard(_ now: TimeInterval) {
        // Preferred path: renegotiate the PD contract down so the charger
        // only has to sustain a lower budget while the battery keeps
        // charging. Only attempted when the user opted in AND a probe has
        // confirmed the controller layout on this machine. Any failure falls
        // through to the safe charge-inhibit guard.
        if config.experimentalPDDownshift, pdConfirmed,
           attemptPDDownshift() {
            engageLPM()
            mode = .guarding
            backoff = config.probeAfter
            nextProbeAt = now + backoff
            return
        }
        log(.guardOn, "charger flapping — inhibiting charging")
        inhibit(true)
        engageLPM()
        mode = .guarding
        backoff = config.probeAfter
        nextProbeAt = now + backoff
    }

    /// Runs blocking PD work on `pdQueue` with a hard deadline. On timeout the
    /// worker thread may stay blocked in the kernel, but the engine queue is
    /// never held longer than `seconds`; subsequent PD ops serialize behind
    /// the wedged one and also time out, disabling PD (CHTE takes over).
    private func pdBounded<T>(_ seconds: Double, _ fallback: T,
                              _ work: @escaping () -> T) -> T {
        let holder = Atomic<T>(fallback)
        let sem = DispatchSemaphore(value: 0)
        pdQueue.async { holder.set(work()); sem.signal() }
        _ = sem.wait(timeout: .now() + seconds)
        return holder.value
    }

    /// Returns true if a downshift is now applied.
    private func attemptPDDownshift() -> Bool {
        let expected = Int(smc.adapterWatts().rounded())
        guard expected > config.pdTargetWatts else { return false }
        let target = config.pdTargetWatts
        let result = pdBounded(12, PDDownshiftResult.refused(reason: "timed out"))
            { [pd] in pd.downshift(targetWatts: target, expectedWatts: expected) }
        switch result {
        case .success(let c):
            pdActiveWatts = c.watts
            lastPDReapplyAt = Self.uptime()
            pdStatus = "downshifted to \(c.watts)W (\(c.millivolts / 1000)V)"
            log(.guardOn, "PD renegotiated to \(c.watts)W — charging "
                + "continues at the lower budget")
            return true
        case .didNotStick(let restored, let verified):
            pdStatus = "downshift did not stick"
            log(.warning, "PD downshift did not stick"
                + (restored.map { " (restored \($0.watts)W)" } ?? "")
                + (verified ? "" : " [restore unverified — will retry on "
                    + "disengage]")
                + " — using charge-inhibit guard")
            return false
        case .refused(let why):
            pdStatus = "downshift refused: \(why)"
            log(.warning, "PD downshift refused: \(why)")
            return false
        }
    }

    private func disengageGuard(_ reason: String) {
        log(.guardOff, "\(reason) — charging enabled")
        // Restore whenever a cap MIGHT be applied (marker-driven inside the
        // controller), not only when pdActiveWatts is set — a failed
        // downshift can leave a cap with pdActiveWatts == nil.
        let restored = pdBounded(8, false) { [pd] in pd.restoreFullContract() }
        if pdActiveWatts != nil || !restored {
            pdActiveWatts = nil
            pdStatus = "restored full contract"
        }
        inhibit(false)
        restoreLPM()
        mode = .observing
        attachTimes.removeAll()
        lastGuardOff = Self.uptime()
    }

    private func startProbe(_ now: TimeInterval) {
        mode = .probing
        probeDeadline = now + config.probeGrace
        inhibit(false)
        let pct = PowerMonitor.snapshot().batteryPercent
        log(.probe, "probing: charging re-enabled for " +
            "\(Int(config.probeGrace))s (battery \(pct)%, " +
            "backoff was \(Int(backoff))s)")
    }

    private func probeFailed(_ now: TimeInterval) {
        inhibit(true)
        mode = .guarding
        backoff = min(backoff * 2, config.probeMax)
        nextProbeAt = now + backoff
        log(.probe, "probe failed (charger dropped) — re-inhibited; " +
            "next attempt in \(Int(backoff))s")
    }

    // MARK: - SMC / LPM plumbing

    /// Desired CHTE state whose last write failed; retried every cycle.
    private var pendingInhibitWrite: Bool?

    private func inhibit(_ on: Bool) {
        do {
            try smc.setChargingInhibited(on)
            pendingInhibitWrite = nil
        } catch {
            pendingInhibitWrite = on
            log(.warning, "CHTE write failed: \(error) " +
                "(will re-assert next cycle)")
        }
    }

    /// Re-asserts the desired CHTE state every cycle while guarded, so an
    /// external write or a rejected write cannot silently defeat the guard.
    private func reconcileInhibit() {
        guard mode != .observing else { return }
        // In PD-downshift mode charging stays ON at a lower contract, so the
        // CHTE gate must not be touched.
        guard pdActiveWatts == nil else { return }
        let want = (mode == .guarding)
        if let actual = try? smc.isChargingInhibited(), actual != want {
            log(.warning, "CHTE drifted (\(actual ? "inhibited" : "enabled")) " +
                "— re-asserting")
            inhibit(want)
        }
    }

    private func engageLPM() {
        guard config.useLowPowerMode, lpmBaseline == nil else { return }
        let current = Self.readACLowPowerMode() ?? 0
        lpmBaseline = current
        // Persist the baseline BEFORE changing the setting, and never
        // overwrite an existing file: a crash-restart loop must not bake
        // the leaked "1" in as the user's baseline.
        if !FileManager.default.fileExists(atPath: Self.lpmURL.path) {
            try? FileManager.default.createDirectory(
                at: Self.stateDir, withIntermediateDirectories: true)
            try? "\(current)".write(to: Self.lpmURL, atomically: true,
                                    encoding: .utf8)
        }
        Self.pmset(["-c", "lowpowermode", "1"])
    }

    private func restoreLPM() {
        guard let baseline = lpmBaseline else { return }
        Self.pmset(["-c", "lowpowermode", "\(baseline)"])
        try? FileManager.default.removeItem(at: Self.lpmURL)
        lpmBaseline = nil
    }

    private func recoverStaleLPM() {
        guard let raw = try? String(contentsOf: Self.lpmURL, encoding: .utf8),
              let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              value == 0 || value == 1 else {
            try? FileManager.default.removeItem(at: Self.lpmURL)
            return
        }
        Self.pmset(["-c", "lowpowermode", "\(value)"])
        try? FileManager.default.removeItem(at: Self.lpmURL)
        log(.info, "recovered AC Low Power Mode to \(value) after an " +
            "unclean previous exit")
    }

    private static func readACLowPowerMode() -> Int? {
        guard let out = shell("/usr/bin/pmset", ["-g", "custom"]) else {
            return nil
        }
        var inAC = false
        for line in out.split(separator: "\n") {
            if line.contains("AC Power") { inAC = true; continue }
            if line.contains("Battery Power") { inAC = false; continue }
            if inAC, line.contains("lowpowermode"),
               let v = line.split(separator: " ").last.flatMap({ Int($0) }) {
                return v
            }
        }
        return nil
    }

    private static func pmset(_ args: [String]) {
        _ = shell("/usr/bin/pmset", args)
    }

    @discardableResult
    private static func shell(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Helpers

    private func pruneAttaches(_ now: TimeInterval) {
        attachTimes.removeAll { now - $0 > config.flapWindow }
    }

    private func log(_ kind: GuardEvent.Kind, _ message: String) {
        let event = GuardEvent(kind: kind, message: message)
        events.append(event)
        if events.count > 500 { events.removeFirst(events.count - 500) }
        NSLog("[ChargeGuard] %@", message)
    }

    // MARK: - XPC surface (called from the listener on `queue`)

    func currentStatus() -> GuardStatus {
        queue.sync {
            var s = GuardStatus()
            let snap = PowerMonitor.snapshot()
            s.mode = mode
            s.protectionEnabled = config.protectionEnabled
            s.isOnAC = snap.isOnAC
            s.batteryPercent = snap.batteryPercent
            s.isCharging = snap.isCharging
            s.chargingInhibited = (try? smc.isChargingInhibited()) ?? false
            s.adapterWatts = smc.adapterWatts()
            s.inputWatts = smc.inputPowerWatts()
            s.chargeCurrentMA = smc.chargeCurrentMA()
            s.recentAttaches = attachTimes.count
            s.currentBackoff = backoff
            s.pdStatus = pdStatus
            s.pdConfirmed = pdConfirmed
            s.pdActiveWatts = pdActiveWatts
            if mode == .guarding {
                s.nextProbeIn = max(0, nextProbeAt - Self.uptime())
            }
            s.helperVersion = HelperVersion.current
            return s
        }
    }

    func recentEvents(limit: Int) -> [GuardEvent] {
        queue.sync { Array(events.suffix(max(0, limit))) }
    }

    func currentConfig() -> GuardConfig {
        queue.sync { config }
    }

    /// Restores user-visible state before the process exits — launchd sends
    /// SIGTERM on SMAppService unregister, daemon disable, and upgrades.
    /// The clean-exit half of the "charging force-enabled on start and
    /// clean exit" invariant. Callable from any thread except `queue`.
    func shutdown() {
        queue.sync {
            log(.info, "terminating — re-enabling charging")
            _ = pdBounded(8, false) { [pd] in pd.restoreFullContract() }
            pdActiveWatts = nil
            inhibit(false)
            restoreLPM()
        }
    }

    /// Runs the read-only PD probe and records whether writes can be trusted.
    func runPDProbe() -> String {
        queue.sync {
            let expected = Int(smc.adapterWatts().rounded())
            guard expected > 0 else {
                pdStatus = "no adapter attached — plug in the charger first"
                return pdStatus
            }
            let result = pdBounded(8,
                PDProbeResult.unavailable(reason: "probe timed out"))
                { [pd] in pd.probe(expectedWatts: expected) }
            switch result {
            case .confirmed(let active, _):
                pdConfirmed = true
                pdStatus = "confirmed: controller speaks standard PD layout "
                    + "(active \(active.watts)W). Downshift can be enabled."
            case .layoutMismatch(let why):
                pdConfirmed = false
                pdStatus = "layout mismatch — downshift unsafe here (\(why))"
            case .unavailable(let why):
                pdConfirmed = false
                pdStatus = "controller unavailable (\(why))"
            }
            log(.info, "PD probe: \(pdStatus)")
            return pdStatus
        }
    }

    func applyConfig(_ newConfig: GuardConfig) {
        let sanitized = newConfig.sanitized()
        queue.sync {
            let wasEnabled = config.protectionEnabled
            config = sanitized
            Self.saveConfig(sanitized)
            if wasEnabled, !newConfig.protectionEnabled {
                if mode != .observing {
                    disengageGuard("protection disabled")
                }
                log(.info, "protection disabled")
            } else if !wasEnabled, newConfig.protectionEnabled {
                log(.info, "protection enabled")
            }
        }
    }

    func forceChargingOn() {
        queue.sync {
            if mode != .observing {
                disengageGuard("manual override")
            } else {
                inhibit(false)
                log(.info, "manual override: charging enabled")
            }
        }
    }

    // MARK: - Config persistence

    private static func loadConfig() -> GuardConfig {
        guard let data = try? Data(contentsOf: configURL),
              let cfg = try? JSONDecoder().decode(GuardConfig.self, from: data)
        else {
            return GuardConfig()
        }
        return cfg
    }

    private static func saveConfig(_ cfg: GuardConfig) {
        try? FileManager.default.createDirectory(
            at: stateDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cfg) {
            try? data.write(to: configURL, options: .atomic)
        }
    }
}

enum HelperVersion {
    static let current = "0.2.0"
}

/// Minimal lock-guarded box for handing a result back from `pdQueue`.
final class Atomic<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ v: T) { lock.lock(); _value = v; lock.unlock() }
}
