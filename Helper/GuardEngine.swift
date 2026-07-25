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
//  External dependencies (SMC, power monitor, PD controller, AC Low Power
//  Mode, the uptime clock, and the on-disk state directory) are injected via
//  the initializer. Every parameter defaults to the real system implementation
//  so production construction is unchanged; tests supply in-memory fakes and a
//  controllable clock to drive the machine deterministically.
//

import Foundation

final class GuardEngine {
    private(set) var config: GuardConfig
    private let smc: ChargeControlling
    private let monitor: PowerMonitoring
    private let pd: PDControlling

    // Injection seams. `uptime` and `snapshot` replace the former static
    // `Self.uptime()` / `PowerMonitor.snapshot()`; `powerMode` replaces the
    // former `pmset` shell-outs; `stateDir` replaces the hard-coded
    // /Library path. Defaults (see init) preserve production behavior exactly.
    private let uptimeClock: () -> TimeInterval
    private let snapshot: () -> PowerSnapshot
    private let powerMode: PowerModeControlling
    private let stateDir: URL

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

    // Power-limit state. `limitHolding` means charging is currently paused
    // *because of the watt cap* (as opposed to the flap guard), and
    // `lastLimitChangeAt` enforces a dwell so charging never chatters.
    private var limitHolding = false
    private var lastLimitChangeAt: TimeInterval = 0
    private var lastLimitSampleAt: TimeInterval = 0
    /// The integrator that makes the ceiling mean something. Every sample adds
    /// (cap - watts) x dt, so running under the ceiling banks credit and
    /// charging spends it; charging switches on at the top of the band and off
    /// at the bottom. Over a full cycle the integral is zero by construction,
    /// which puts *average* draw exactly on the ceiling — and makes every
    /// ceiling value produce a different charge rate, which a plain
    /// over/under threshold does not.
    private var limitBudgetJoules: Double = 0
    /// Display-only rolling figures. An instantaneous watt reading taken
    /// mid-pause looks like a lie sitting next to the ceiling, so the UI gets
    /// the average and the duty share instead.
    private var limitAvgWatts: Double?
    private var limitDuty: Double = 1
    /// Running totals for the measurement window, and the plain unbiased mean
    /// they produce.
    ///
    /// An exponential average seeded from its first sample spends its first
    /// time constant reporting mostly that first sample: on a fresh 30W
    /// ceiling it opens at about 41W, which is exactly the "the cap is doing
    /// nothing" reading this whole mechanism exists to avoid. So for the first
    /// `limitAverageTau` the figures are a true energy/time mean — correct
    /// from the very first sample — and the exponential average only takes
    /// over afterwards, by which point it has real history to smooth.
    private var limitSampleSeconds: Double = 0
    private var limitEnergyJoules: Double = 0
    private var limitChargingSeconds: Double = 0
    /// Sampled only while charging is paused, so it is the Mac's own draw
    /// with nothing going to the battery.
    private var limitBaseWatts: Double?
    /// True once we know the ceiling can't be met: charging is already off
    /// and the Mac still draws more than the cap all by itself.
    private var limitUnreachable = false
    /// The ceiling never gets to run the battery below this.
    private static let limitFloorPercent = 20
    /// Half-width of the energy band, in joules — sets how long each charge
    /// burst runs. Bigger means longer, lazier cycles; 500 J gives bursts of
    /// roughly 20-100s on a 65W adapter.
    private static let limitBandJoules: Double = 500
    /// Charging never flips faster than this, whatever the integrator says.
    private static let limitMinSegment: TimeInterval = 15
    /// Time constant for the reported average and duty figures.
    private static let limitAverageTau: Double = 120
    /// How much history the averages need before they are worth showing.
    /// Roughly one full charge/pause cycle at any usable ceiling.
    private static let limitSettleSeconds: Double = 90

    private var events: [GuardEvent] = []
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "dev.byrvr.ChargeGuard.engine")

    static let defaultStateDir = URL(fileURLWithPath:
        "/Library/Application Support/ChargeGuard")
    private var configURL: URL { stateDir.appendingPathComponent("config.json") }
    private var lpmURL: URL { stateDir.appendingPathComponent("lpm.saved") }

    /// Seconds of machine uptime, excluding time spent asleep.
    static func systemUptime() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }

    /// Uptime as seen by this engine instance (injectable for tests).
    private func uptime() -> TimeInterval { uptimeClock() }

    init(smc: ChargeControlling,
         monitor: PowerMonitoring,
         pd: PDControlling = PDController(),
         powerMode: PowerModeControlling = PmsetPowerMode(),
         uptime: @escaping () -> TimeInterval = GuardEngine.systemUptime,
         snapshot: @escaping () -> PowerSnapshot = PowerMonitor.snapshot,
         stateDir: URL = GuardEngine.defaultStateDir,
         startTimer: Bool = true) {
        self.smc = smc
        self.monitor = monitor
        self.pd = pd
        self.powerMode = powerMode
        self.uptimeClock = uptime
        self.snapshot = snapshot
        self.stateDir = stateDir
        self.config = Self.loadConfig(from:
            stateDir.appendingPathComponent("config.json"))
        self.backoff = config.probeAfter

        // Crash recovery: never leave a stale inhibit or Low Power Mode
        // behind from a previous unclean exit.
        try? smc.setChargingInhibited(false)
        recoverStaleLPM()
        // If a PD cap survived an unclean exit, restore the original policy.
        // No-op unless a marker exists, so users who never enabled downshift
        // never touch the PD write path on boot.
        _ = pdBounded(8, false) { [pd] in pd.recoverFromCrashIfNeeded(); return true }

        let snap = snapshot()
        isOnAC = snap.isOnAC
        if isOnAC { lastACSeen = uptime() }
        log(.info, "engine started (source: \(isOnAC ? "AC" : "battery"), " +
            "battery \(snap.batteryPercent)%)")

        monitor.onPowerSourceChange = { [weak self] snap in
            self?.queue.async { self?.powerSourceChanged(snap) }
        }
        monitor.onWake = { [weak self] in
            self?.queue.async { self?.systemWoke() }
        }
        monitor.start()

        if startTimer {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 5, repeating: 5)
            t.setEventHandler { [weak self] in self?.housekeeping() }
            t.resume()
            timer = t
        }
    }

    // MARK: - Event handling

    private func powerSourceChanged(_ snap: PowerSnapshot) {
        let now = uptime()
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
            nextProbeAt = uptime() + backoff
        }
        let snap = snapshot()
        queueSourceRefresh(snap)
    }

    private func queueSourceRefresh(_ snap: PowerSnapshot) {
        if snap.isOnAC != isOnAC {
            powerSourceChanged(snap)
        }
    }

    private func housekeeping() {
        let now = uptime()
        pruneAttaches(now)

        // Poll fallback in case a notification was missed.
        queueSourceRefresh(snapshot())

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
            // The watt cap runs first: it is the lever that actually works on
            // Apple Silicon, and it owns CHTE while the flap guard is idle.
            enforcePowerLimit(now)
            // Always-on limiter: when Slow charging is enabled as a persistent
            // cap and the controller is confirmed, hold the contract down
            // proactively instead of waiting for a charger to misbehave.
            maybeEngagePersistentCap(now)
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
            lastPDReapplyAt = uptime()
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

    /// Proactively applies the PD cap when Slow charging is enabled as an
    /// always-on limit — confirmed controller, on AC, and currently drawing
    /// above the target budget. Enters the same stable capped state the flap
    /// path uses, so the existing maintenance and restore-on-disengage logic
    /// applies unchanged. Does nothing while the Mac is already sipping
    /// (battery full → low contract), so it never renegotiates a port that
    /// isn't actually pulling high power.
    private func maybeEngagePersistentCap(_ now: TimeInterval) {
        guard config.experimentalPDDownshift, pdConfirmed, isOnAC,
              pdActiveWatts == nil else { return }
        guard Int(smc.adapterWatts().rounded()) > config.pdTargetWatts + 5
        else { return }
        if attemptPDDownshift() {
            engageLPM()
            mode = .guarding
            log(.guardOn, "power limit engaged — holding the charger near "
                + "\(config.pdTargetWatts)W (charging continues, slower)")
        }
    }

    // MARK: - Power limit (watt cap)

    /// Holds total adapter draw under `config.powerLimitWatts`.
    ///
    /// Apple Silicon exposes no charge-current limit — CHTL looks like one but
    /// ignores writes, and the PD contract is re-asserted by the SoC's own
    /// policy manager — so the only lever that moves real watts is pausing
    /// charging, and it is all-or-nothing: the instant charging is allowed the
    /// Mac jumps to roughly system load + 35W, whatever the ceiling says.
    ///
    /// So the ceiling is held as an *average*, not as an instantaneous limit.
    /// An energy integrator banks credit while draw sits under the ceiling and
    /// spends it while charging runs, and charging is switched at the edges of
    /// the band. A lower ceiling buys fewer charging seconds per minute, so
    /// the slider maps onto a real, monotonic charge rate instead of every
    /// value below the charging draw behaving identically.
    ///
    /// Nothing here throttles the system itself; apps always get what they ask
    /// for and only the battery's share is rationed.
    private func enforcePowerLimit(_ now: TimeInterval) {
        guard config.powerLimitEnabled, isOnAC else {
            releasePowerLimit(now, reason: isOnAC ? "limit off" : "on battery")
            return
        }
        // Re-assert the pause if anything else re-enabled charging behind us.
        if limitHolding, let actual = try? smc.isChargingInhibited(), !actual {
            inhibit(true)
        }
        guard let watts = smc.inputPowerWatts() else { return }
        let cap = Double(config.powerLimitWatts)
        let battery = snapshot().batteryPercent

        // dt is clamped: a sleep or a stalled tick must not dump one huge lump
        // of credit into the integrator.
        let dt = min(max(now - lastLimitSampleAt, 0), 15)
        lastLimitSampleAt = now
        trackLimitAverages(watts, dt)

        // Safety valve. A ceiling set below what the Mac needs on its own can
        // never be met by pausing charging, and while the pause is held the
        // battery quietly covers every load spike. Under `limitFloorPercent`
        // the battery wins: charging goes back on and stays on.
        if battery <= Self.limitFloorPercent {
            if limitHolding {
                releasePowerLimit(now, reason: "battery down to \(battery)%")
                limitUnreachable = watts >= cap
            }
            return
        }

        let band = Self.limitBandJoules
        limitBudgetJoules = min(max(limitBudgetJoules + (cap - watts) * dt,
                                    -band), band)
        let heldFor = now - lastLimitChangeAt
        guard heldFor >= Self.limitMinSegment else { return }

        if !limitHolding, limitBudgetJoules <= -band {
            limitHolding = true
            lastLimitChangeAt = now
            inhibit(true)
            log(.guardOn, "power limit: burst done at "
                + "\(Int(watts.rounded()))W — charging paused to hold the "
                + "\(config.powerLimitWatts)W average")
        } else if limitHolding, limitBudgetJoules >= band {
            limitHolding = false
            limitUnreachable = false
            lastLimitChangeAt = now
            inhibit(false)
            log(.guardOff, "power limit: \(Int(watts.rounded()))W leaves room "
                + "under the \(config.powerLimitWatts)W average — charging "
                + "resumed")
        } else if limitHolding, !limitUnreachable, watts >= cap, heldFor >= 180 {
            // Charging is off and the Mac alone is still over the ceiling, so
            // credit never rebuilds and the burst never comes. Say so rather
            // than holding silently until the battery is flat.
            limitUnreachable = true
            log(.warning, "power limit: the Mac alone draws "
                + "\(Int(watts.rounded()))W, over the "
                + "\(config.powerLimitWatts)W cap — raise the cap or the "
                + "battery won't charge")
        }
    }

    /// Exponential averages of draw and of the charging duty share. Display
    /// only — nothing in the control loop reads these.
    private func trackLimitAverages(_ watts: Double, _ dt: TimeInterval) {
        guard dt > 0 else {
            if limitAvgWatts == nil { limitAvgWatts = watts }
            return
        }
        limitSampleSeconds += dt
        limitEnergyJoules += watts * dt
        limitChargingSeconds += limitHolding ? 0 : dt
        if limitSampleSeconds < Self.limitAverageTau {
            // Young window: the honest arithmetic mean, no seeding bias.
            limitAvgWatts = limitEnergyJoules / limitSampleSeconds
            limitDuty = limitChargingSeconds / limitSampleSeconds
        } else {
            // Old enough to smooth. The handover is seamless: at the crossover
            // the exponential average starts from the window mean.
            let a = min(1, dt / Self.limitAverageTau)
            limitAvgWatts = limitAvgWatts.map { $0 + (watts - $0) * a } ?? watts
            limitDuty += ((limitHolding ? 0 : 1) - limitDuty) * a
        }
        if limitHolding {
            // Charging is off, so this sample is the Mac by itself. Slower
            // constant than the others: it is advice about where to put the
            // slider, and advice that jitters is useless.
            let b = min(1, dt / 180)
            limitBaseWatts = limitBaseWatts.map { $0 + (watts - $0) * b }
                ?? watts
        }
    }

    /// Wipes everything the old ceiling taught us.
    ///
    /// The integrator and the averages are both *relative to a ceiling*: at
    /// 45W on this hardware they settle at roughly 45W and 60% duty, and those
    /// are the exact numbers a 30W ceiling must not inherit. Carrying them
    /// across a slider move meant the panel spent two minutes reporting the
    /// previous setting's steady state — which reads as the cap being ignored,
    /// because for those two minutes the displayed numbers really did belong
    /// to a cap that was ignored. `limitBaseWatts` survives: it measures the
    /// Mac's own appetite, which has nothing to do with where the slider sits.
    private func resetPowerLimitAveraging(_ now: TimeInterval) {
        limitBudgetJoules = 0
        limitAvgWatts = nil
        limitDuty = limitHolding ? 0 : 1
        limitSampleSeconds = 0
        limitEnergyJoules = 0
        limitChargingSeconds = 0
        limitUnreachable = false
        lastLimitSampleAt = now
    }

    /// Whether the sample clock is actually running, i.e. whether "Measuring"
    /// will ever finish.
    ///
    /// `limitSampleSeconds` only advances inside the observing branch of
    /// housekeeping, with protection on and a readable draw sensor. Turn
    /// protection off, trip the flap guard, or run on a Mac where PDTR can't
    /// be read, and the counter stops — so a settling flag that looked only at
    /// "limit on, on AC" would leave the UI saying "about a minute" forever.
    private func limitIsMeasuring(_ s: GuardStatus) -> Bool {
        config.protectionEnabled && mode == .observing && s.inputWatts != nil
    }

    private func releasePowerLimit(_ now: TimeInterval, reason: String) {
        limitUnreachable = false
        limitBudgetJoules = 0
        limitAvgWatts = nil
        limitDuty = 1
        limitSampleSeconds = 0
        limitEnergyJoules = 0
        limitChargingSeconds = 0
        limitBaseWatts = nil
        lastLimitSampleAt = now
        guard limitHolding else { return }
        limitHolding = false
        lastLimitChangeAt = now
        inhibit(false)
        log(.guardOff, "power limit released (\(reason)) — charging enabled")
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
        lastGuardOff = uptime()
    }

    private func startProbe(_ now: TimeInterval) {
        mode = .probing
        probeDeadline = now + config.probeGrace
        inhibit(false)
        let pct = snapshot().batteryPercent
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
        let current = powerMode.readACLowPowerMode() ?? 0
        lpmBaseline = current
        // Persist the baseline BEFORE changing the setting, and never
        // overwrite an existing file: a crash-restart loop must not bake
        // the leaked "1" in as the user's baseline.
        if !FileManager.default.fileExists(atPath: lpmURL.path) {
            try? FileManager.default.createDirectory(
                at: stateDir, withIntermediateDirectories: true)
            try? "\(current)".write(to: lpmURL, atomically: true,
                                    encoding: .utf8)
        }
        powerMode.setACLowPowerMode(1)
    }

    private func restoreLPM() {
        guard let baseline = lpmBaseline else { return }
        powerMode.setACLowPowerMode(baseline)
        try? FileManager.default.removeItem(at: lpmURL)
        lpmBaseline = nil
    }

    private func recoverStaleLPM() {
        guard let raw = try? String(contentsOf: lpmURL, encoding: .utf8),
              let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              value == 0 || value == 1 else {
            try? FileManager.default.removeItem(at: lpmURL)
            return
        }
        powerMode.setACLowPowerMode(value)
        try? FileManager.default.removeItem(at: lpmURL)
        log(.info, "recovered AC Low Power Mode to \(value) after an " +
            "unclean previous exit")
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
            let snap = snapshot()
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
            s.powerLimitHolding = limitHolding
            s.powerLimitUnreachable = limitUnreachable
            if config.powerLimitEnabled, isOnAC {
                // Held back until there is enough history to mean anything —
                // a half-formed average sitting next to the ceiling reads as
                // the ceiling being ignored. The UI says "settling" instead.
                if limitSampleSeconds >= Self.limitSettleSeconds {
                    s.powerLimitAverageWatts = limitAvgWatts
                    s.powerLimitDutyPercent =
                        Int((min(max(limitDuty, 0), 1) * 100).rounded())
                } else if limitIsMeasuring(s) {
                    s.powerLimitSettling = true
                }
                s.powerLimitBaseWatts = limitBaseWatts
            }
            if mode == .guarding {
                s.nextProbeIn = max(0, nextProbeAt - uptime())
            }
            s.helperVersion = ChargeGuardVersion.current
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
            limitHolding = false
            limitUnreachable = false
            limitBudgetJoules = 0
            limitSampleSeconds = 0
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
                pdStatus = "confirmed: read the active contract cleanly "
                    + "(\(active.watts)W at \(active.millivolts / 1000)V). Slow "
                    + "charging can be enabled."
            case .eprRecognized(let activeMV, let maxMV, let watts):
                pdConfirmed = false
                pdStatus = "recognized a \(activeMV / 1000)V EPR AVS contract "
                    + "(range to \(maxMV / 1000)V, \(watts)W). Read OK — the "
                    + "EPR downshift is the next step."
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

    /// User-initiated safe test of the downshift write path: performs one real
    /// downshift to the configured budget, then immediately restores the full
    /// contract. Lets the user confirm slow charging works on their hardware
    /// without waiting for a charger to actually misbehave. Only runs while
    /// idle (not mid-guard) and after a probe has confirmed the layout.
    func runPDSelfTest() -> String {
        queue.sync {
            guard pdConfirmed else {
                pdStatus = "run “Check compatibility” first — a downshift test "
                    + "only runs after the read-only probe confirms this Mac"
                return pdStatus
            }
            guard mode == .observing else {
                return "ChargeGuard is currently acting on the charger — let it "
                    + "settle back to normal, then run the test."
            }
            let expected = Int(smc.adapterWatts().rounded())
            guard expected > config.pdTargetWatts else {
                return "The charger is only offering \(expected)W right now — the "
                    + "battery is likely full, so there's nothing to slow down. "
                    + "Test again while it's actually charging."
            }
            let target = config.pdTargetWatts
            let result = pdBounded(12,
                PDDownshiftResult.refused(reason: "timed out"))
                { [pd] in pd.downshift(targetWatts: target,
                                       expectedWatts: expected) }
            // Always restore immediately — this is a test, never a lingering cap.
            _ = pdBounded(8, false) { [pd] in pd.restoreFullContract() }

            let msg: String
            switch result {
            case .success(let c):
                msg = "Test passed: renegotiated down to \(c.watts)W "
                    + "(\(c.millivolts / 1000)V), then restored full power. Slow "
                    + "charging works on this Mac."
            case .didNotStick(let restored, _):
                msg = "Test inconclusive: the charger didn't take the lower "
                    + "budget"
                    + (restored.map { " (held at \($0.watts)W)" } ?? "")
                    + " — full power was restored. Pause charging still works."
            case .refused(let why):
                msg = "Test couldn't run (\(why)) — full power is intact."
            }
            log(.info, "PD self-test: \(msg)")
            pdStatus = msg
            return msg
        }
    }

    func applyConfig(_ newConfig: GuardConfig) {
        let sanitized = newConfig.sanitized()
        queue.sync {
            let wasEnabled = config.protectionEnabled
            let wasPDEnabled = config.experimentalPDDownshift
            let oldCap = config.powerLimitWatts
            let wasLimiting = config.powerLimitEnabled
            config = sanitized
            Self.saveConfig(sanitized, to: configURL)
            if wasEnabled, !sanitized.protectionEnabled {
                if mode != .observing {
                    disengageGuard("protection disabled")
                }
                log(.info, "protection disabled")
            } else if !wasEnabled, sanitized.protectionEnabled {
                log(.info, "protection enabled")
            }
            // Turning the always-on limiter off must lift any active cap and
            // restore full power right away, not wait for a disengage trigger.
            if wasPDEnabled, !sanitized.experimentalPDDownshift,
               pdActiveWatts != nil {
                disengageGuard("slow-charging limit turned off")
            }
            // Turning the watt cap off (or protection off entirely) must
            // resume charging immediately, not on the next dwell tick.
            if !sanitized.powerLimitEnabled || !sanitized.protectionEnabled {
                releasePowerLimit(uptime(), reason: "limit off")
            } else if !wasLimiting || oldCap != sanitized.powerLimitWatts {
                // A new ceiling is a new experiment. Start it clean instead of
                // reporting the last one's steady state for the next two
                // minutes.
                resetPowerLimitAveraging(uptime())
                if wasLimiting {
                    log(.info, "power limit: ceiling \(oldCap)W → "
                        + "\(sanitized.powerLimitWatts)W — remeasuring")
                }
            }
        }
    }

    func forceChargingOn() {
        queue.sync {
            releasePowerLimit(uptime(), reason: "manual override")
            if mode != .observing {
                disengageGuard("manual override")
            } else {
                inhibit(false)
                log(.info, "manual override: charging enabled")
            }
        }
    }

    // MARK: - Config persistence

    private static func loadConfig(from url: URL) -> GuardConfig {
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(GuardConfig.self, from: data)
        else {
            return GuardConfig()
        }
        return cfg
    }

    private static func saveConfig(_ cfg: GuardConfig, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cfg) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Minimal lock-guarded box for handing a result back from `pdQueue`.
final class Atomic<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ v: T) { lock.lock(); _value = v; lock.unlock() }
}

// Deterministic drivers for unit tests. These run the same private handlers
// the production timer and IOKit callbacks invoke, but synchronously on the
// engine queue so a test can step the machine with a controllable clock.
// Internal + unused in production (dead-code-stripped from Release builds);
// they exist only so the test target can step the state machine.
extension GuardEngine {
    func testTick() { queue.sync { housekeeping() } }
    func testPowerSourceChanged(_ snap: PowerSnapshot) {
        queue.sync { powerSourceChanged(snap) }
    }
    func testSystemWoke() { queue.sync { systemWoke() } }

    var testMode: GuardMode { queue.sync { mode } }
    var testBackoff: TimeInterval { queue.sync { backoff } }
    var testNextProbeAt: TimeInterval { queue.sync { nextProbeAt } }
    var testAttachCount: Int { queue.sync { attachTimes.count } }
    var testPendingInhibit: Bool? { queue.sync { pendingInhibitWrite } }
    var testPDActiveWatts: Int? { queue.sync { pdActiveWatts } }
    var testLimitHolding: Bool { queue.sync { limitHolding } }
    var testLimitUnreachable: Bool { queue.sync { limitUnreachable } }
    var testLimitBudget: Double { queue.sync { limitBudgetJoules } }
    var testLimitDuty: Double { queue.sync { limitDuty } }
    var testLimitAvgWatts: Double? { queue.sync { limitAvgWatts } }
    var testLimitBaseWatts: Double? { queue.sync { limitBaseWatts } }
    var testLimitSampleSeconds: Double { queue.sync { limitSampleSeconds } }
}
