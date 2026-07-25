//
//  GuardEngineTests.swift
//  ChargeGuardHelperTests
//
//  Unit tests for the guard state machine. The engine is built with in-memory
//  fakes for every system seam (SMC, power monitor, PD controller, AC Low
//  Power Mode) and a controllable uptime clock, so transitions are driven
//  deterministically without touching IOKit, pmset, or the real clock.
//

import XCTest

// MARK: - Fakes

final class FakeSMC: ChargeControlling {
    var inhibited = false
    var failWrites = false
    private(set) var writeCount = 0
    var adapterW: Double = 65
    var chargeMA = 1000
    var inputW: Double? = 60

    func isChargingInhibited() throws -> Bool { inhibited }

    func setChargingInhibited(_ v: Bool) throws {
        writeCount += 1
        if failWrites { throw SMCError.writeDidNotStick(key: "CHTE") }
        inhibited = v
    }

    func adapterWatts() -> Double { adapterW }
    func chargeCurrentMA() -> Int { chargeMA }
    func inputPowerWatts() -> Double? { inputW }
}

final class FakeMonitor: PowerMonitoring {
    var onPowerSourceChange: ((PowerSnapshot) -> Void)?
    var onWake: (() -> Void)?
    private(set) var started = false
    func start() { started = true }
}

final class FakePD: PDControlling {
    var probeResult: PDProbeResult = .unavailable(reason: "test default")
    var downshiftResult: PDDownshiftResult = .refused(reason: "test default")
    var restoreResult = true
    private(set) var recovered = false
    private(set) var restoreCount = 0

    func probe(expectedWatts: Int) -> PDProbeResult { probeResult }
    func downshift(targetWatts: Int, expectedWatts: Int) -> PDDownshiftResult {
        downshiftResult
    }
    func restoreFullContract() -> Bool { restoreCount += 1; return restoreResult }
    func recoverFromCrashIfNeeded() { recovered = true }
}

final class FakePowerMode: PowerModeControlling {
    var acLowPowerMode: Int? = 0
    private(set) var setValues: [Int] = []
    func readACLowPowerMode() -> Int? { acLowPowerMode }
    func setACLowPowerMode(_ value: Int) {
        setValues.append(value)
        acLowPowerMode = value
    }
}

final class TestClock {
    private var t: TimeInterval
    init(_ start: TimeInterval = 1000) { t = start }
    func now() -> TimeInterval { t }
    func advance(_ dt: TimeInterval) { t += dt }
}

final class FakePower {
    var snap = PowerSnapshot(isOnAC: false, batteryPercent: 50, isCharging: false)
    func snapshot() -> PowerSnapshot { snap }
}

// MARK: - Tests

final class GuardEngineTests: XCTestCase {

    private struct Rig {
        let engine: GuardEngine
        let smc: FakeSMC
        let monitor: FakeMonitor
        let pd: FakePD
        let powerMode: FakePowerMode
        let clock: TestClock
        let power: FakePower
        let stateDir: URL
    }

    private func makeRig(stateDir: URL? = nil) -> Rig {
        let dir = stateDir ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("cgtest-\(UUID().uuidString)")
        let smc = FakeSMC()
        let mon = FakeMonitor()
        let pd = FakePD()
        let pm = FakePowerMode()
        let clock = TestClock()
        let power = FakePower()
        let engine = GuardEngine(
            smc: smc, monitor: mon, pd: pd, powerMode: pm,
            uptime: clock.now, snapshot: power.snapshot,
            stateDir: dir, startTimer: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return Rig(engine: engine, smc: smc, monitor: mon, pd: pd,
                   powerMode: pm, clock: clock, power: power, stateDir: dir)
    }

    /// Sets the shared power snapshot and delivers a source-change to the engine
    /// so the engine's view and the housekeeping fallback stay consistent.
    private func setAC(_ rig: Rig, _ on: Bool, battery: Int = 50) {
        let s = PowerSnapshot(isOnAC: on, batteryPercent: battery,
                              isCharging: on)
        rig.power.snap = s
        rig.engine.testPowerSourceChanged(s)
    }

    /// Drives three attaches (with intervening detaches) within the flap
    /// window, ending plugged in — enough to trip the default 3-strike guard.
    private func flapToGuard(_ rig: Rig) {
        rig.clock.advance(1); setAC(rig, true)
        rig.clock.advance(1); setAC(rig, false)
        rig.clock.advance(1); setAC(rig, true)
        rig.clock.advance(1); setAC(rig, false)
        rig.clock.advance(1); setAC(rig, true)
    }

    // MARK: Crash safety on start

    func testInitForcesChargingEnabled() {
        let rig = makeRig()
        XCTAssertFalse(rig.smc.inhibited)
        XCTAssertGreaterThanOrEqual(rig.smc.writeCount, 1,
            "charging must be force-enabled on start")
        XCTAssertEqual(rig.engine.testMode, .observing)
    }

    func testInitRunsPDCrashRecovery() {
        let rig = makeRig()
        XCTAssertTrue(rig.pd.recovered,
            "helper start must run PD crash recovery")
    }

    func testStaleLowPowerModeRecoveredOnInit() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cgtest-lpm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let lpm = dir.appendingPathComponent("lpm.saved")
        try "1".write(to: lpm, atomically: true, encoding: .utf8)

        let rig = makeRig(stateDir: dir)

        XCTAssertTrue(rig.powerMode.setValues.contains(1),
            "a persisted LPM baseline must be restored after an unclean exit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lpm.path),
            "the recovery marker must be cleared once restored")
    }

    // MARK: Flap detection

    func testFlapEngagesGuard() {
        let rig = makeRig()
        flapToGuard(rig)
        XCTAssertEqual(rig.engine.testMode, .guarding)
        XCTAssertTrue(rig.smc.inhibited, "guarding must inhibit charging")
    }

    func testBelowThresholdStaysObserving() {
        let rig = makeRig()
        rig.clock.advance(1); setAC(rig, true)   // attach 1
        rig.clock.advance(1); setAC(rig, false)
        rig.clock.advance(1); setAC(rig, true)   // attach 2 (< trigger of 3)
        XCTAssertEqual(rig.engine.testMode, .observing)
        XCTAssertFalse(rig.smc.inhibited)
    }

    func testAttachesOutsideWindowDoNotAccumulate() {
        let rig = makeRig()
        rig.clock.advance(1); setAC(rig, true)     // attach 1
        rig.clock.advance(1); setAC(rig, false)
        rig.clock.advance(1); setAC(rig, true)     // attach 2
        rig.clock.advance(1); setAC(rig, false)
        // Jump well past the flap window before the next attach.
        rig.clock.advance(10_000); setAC(rig, true) // stale ones pruned
        XCTAssertEqual(rig.engine.testMode, .observing,
            "attaches older than the window must not count toward a flap")
    }

    // MARK: Probing

    func testProbeStartsAfterBackoff() {
        let rig = makeRig()
        flapToGuard(rig)
        XCTAssertEqual(rig.engine.testMode, .guarding)
        // Default first backoff is probeAfter = 300s.
        rig.clock.advance(301)
        rig.engine.testTick()
        XCTAssertEqual(rig.engine.testMode, .probing)
        XCTAssertFalse(rig.smc.inhibited, "a probe re-enables charging")
    }

    func testProbeSuccessDisengages() {
        let rig = makeRig()
        flapToGuard(rig)
        rig.clock.advance(301)
        rig.engine.testTick()                       // -> probing
        XCTAssertEqual(rig.engine.testMode, .probing)
        rig.clock.advance(121)                       // past probeGrace (120s)
        rig.engine.testTick()
        XCTAssertEqual(rig.engine.testMode, .observing,
            "a probe that survives the grace period lifts the guard")
        XCTAssertFalse(rig.smc.inhibited)
    }

    func testProbeFailureDoublesBackoff() {
        let rig = makeRig()
        flapToGuard(rig)
        rig.clock.advance(301)
        rig.engine.testTick()                       // -> probing
        XCTAssertEqual(rig.engine.testMode, .probing)
        // Charger drops during the probe.
        rig.clock.advance(2); setAC(rig, false)
        XCTAssertEqual(rig.engine.testMode, .guarding)
        XCTAssertTrue(rig.smc.inhibited)
        XCTAssertEqual(rig.engine.testBackoff, 600,
            "a failed probe doubles the backoff (300 -> 600)")
    }

    func testSwapReattachSchedulesEarlyProbe() {
        let rig = makeRig()
        flapToGuard(rig)                             // guarding, nextProbe ~ +300
        let scheduled = rig.engine.testNextProbeAt
        // Detach, wait longer than swapGap (30s), reattach -> suspected swap.
        rig.clock.advance(2); setAC(rig, false)
        rig.clock.advance(40); setAC(rig, true)
        XCTAssertLessThan(rig.engine.testNextProbeAt, scheduled,
            "a re-attach after a gap should pull the probe earlier")
    }

    // MARK: Retrigger

    func testImmediateRetriggerAfterRecentGuard() {
        let rig = makeRig()
        flapToGuard(rig)
        rig.engine.forceChargingOn()                 // -> observing, guard-off stamped
        XCTAssertEqual(rig.engine.testMode, .observing)
        // A single drop+attach shortly after should re-engage without 3 strikes.
        rig.clock.advance(30); setAC(rig, false)
        rig.clock.advance(1); setAC(rig, true)
        XCTAssertEqual(rig.engine.testMode, .guarding,
            "one drop soon after a guard should re-engage immediately")
    }

    // MARK: Manual + config control

    func testForceChargingLiftsGuard() {
        let rig = makeRig()
        flapToGuard(rig)
        rig.engine.forceChargingOn()
        XCTAssertEqual(rig.engine.testMode, .observing)
        XCTAssertFalse(rig.smc.inhibited)
    }

    func testDisablingProtectionDisengages() {
        let rig = makeRig()
        flapToGuard(rig)
        var c = rig.engine.currentConfig()
        c.protectionEnabled = false
        rig.engine.applyConfig(c)
        XCTAssertEqual(rig.engine.testMode, .observing)
        XCTAssertFalse(rig.smc.inhibited)
    }

    func testEngineSanitizesIncomingConfig() {
        let rig = makeRig()
        var c = GuardConfig()
        c.flapTrigger = 0            // -> clamped up to 2
        c.probeAfter = 5            // -> clamped up to 60
        c.probeMax = 1              // -> at least probeAfter
        rig.engine.applyConfig(c)
        let out = rig.engine.currentConfig()
        XCTAssertGreaterThanOrEqual(out.flapTrigger, 2)
        XCTAssertGreaterThanOrEqual(out.probeAfter, 60)
        XCTAssertGreaterThanOrEqual(out.probeMax, out.probeAfter)
    }

    // MARK: CHTE write resilience

    func testFailedInhibitIsRetriedNextCycle() {
        let rig = makeRig()
        rig.smc.failWrites = true
        flapToGuard(rig)
        // The write failed, but the engine still entered guarding and owes a write.
        XCTAssertEqual(rig.engine.testMode, .guarding)
        XCTAssertFalse(rig.smc.inhibited)
        XCTAssertEqual(rig.engine.testPendingInhibit, true)

        rig.smc.failWrites = false
        rig.clock.advance(1)
        rig.engine.testTick()
        XCTAssertTrue(rig.smc.inhibited, "the owed CHTE write is retried")
        XCTAssertNil(rig.engine.testPendingInhibit)
    }

    // MARK: PD downshift

    private func confirmPD(_ rig: Rig, targetWatts: Int = 45) {
        rig.smc.adapterW = 65
        rig.pd.probeResult = .confirmed(
            active: PDOContract(millivolts: 20_000, milliamps: 3_250),
            sinkMaxMV: 20_000)
        _ = rig.engine.runPDProbe()
        var c = rig.engine.currentConfig()
        c.experimentalPDDownshift = true
        c.pdTargetWatts = targetWatts
        rig.engine.applyConfig(c)
    }

    func testPDDownshiftPreferredWhenConfirmed() {
        let rig = makeRig()
        confirmPD(rig)
        rig.pd.downshiftResult = .success(
            newContract: PDOContract(millivolts: 15_000, milliamps: 3_000)) // 45W
        flapToGuard(rig)
        XCTAssertEqual(rig.engine.testMode, .guarding)
        XCTAssertFalse(rig.smc.inhibited,
            "a successful downshift keeps charging on, never inhibits CHTE")
        XCTAssertEqual(rig.engine.testPDActiveWatts, 45)
        XCTAssertEqual(rig.engine.currentStatus().pdActiveWatts, 45)
    }

    func testPDDownshiftRefusalFallsBackToInhibit() {
        let rig = makeRig()
        confirmPD(rig)
        rig.pd.downshiftResult = .refused(reason: "layout differs")
        flapToGuard(rig)
        XCTAssertEqual(rig.engine.testMode, .guarding)
        XCTAssertTrue(rig.smc.inhibited,
            "a refused downshift must fall back to the charge-inhibit guard")
        XCTAssertNil(rig.engine.testPDActiveWatts)
    }

    // MARK: Always-on limiter (persistent cap)

    func testPersistentCapEngagesWithoutFlap() {
        let rig = makeRig()
        confirmPD(rig)                       // confirmed + Slow charging on, target 45
        rig.pd.downshiftResult = .success(
            newContract: PDOContract(millivolts: 15_000, milliamps: 3_000)) // 45W
        rig.smc.adapterW = 65                // pulling well above the 45W budget
        setAC(rig, true)                     // just plugged in — no flapping
        rig.clock.advance(1)
        rig.engine.testTick()                // housekeeping applies the always-on cap
        XCTAssertEqual(rig.engine.testMode, .guarding,
            "an always-on limit engages without waiting for a flap")
        XCTAssertEqual(rig.engine.testPDActiveWatts, 45)
        XCTAssertFalse(rig.smc.inhibited,
            "the limit caps the contract; it never inhibits charging")
    }

    func testPersistentCapSkippedWhenAlreadyLow() {
        let rig = makeRig()
        confirmPD(rig)
        rig.pd.downshiftResult = .success(
            newContract: PDOContract(millivolts: 15_000, milliamps: 3_000))
        rig.smc.adapterW = 27                // already below budget (e.g. battery full)
        setAC(rig, true)
        rig.clock.advance(1)
        rig.engine.testTick()
        XCTAssertEqual(rig.engine.testMode, .observing,
            "nothing to cap when the Mac is already sipping — no needless renegotiation")
        XCTAssertNil(rig.engine.testPDActiveWatts)
    }

    func testDisablingLimiterRestoresFullPower() {
        let rig = makeRig()
        confirmPD(rig)
        rig.pd.downshiftResult = .success(
            newContract: PDOContract(millivolts: 15_000, milliamps: 3_000))
        rig.smc.adapterW = 65
        setAC(rig, true)
        rig.clock.advance(1); rig.engine.testTick()
        XCTAssertEqual(rig.engine.testPDActiveWatts, 45, "cap is applied first")

        var c = rig.engine.currentConfig()
        c.experimentalPDDownshift = false
        rig.engine.applyConfig(c)
        XCTAssertNil(rig.engine.testPDActiveWatts,
            "turning the limit off lifts the cap immediately")
        XCTAssertEqual(rig.engine.testMode, .observing)
        XCTAssertGreaterThanOrEqual(rig.pd.restoreCount, 1,
            "disabling the limit restores the full PD contract")
    }

    // MARK: Power limit (watt cap)

    /// Enables the cap and returns the rig already on AC.
    private func withPowerLimit(_ rig: Rig, watts: Int) {
        var c = rig.engine.currentConfig()
        c.powerLimitEnabled = true
        c.powerLimitWatts = watts
        rig.engine.applyConfig(c)
    }

    /// Advances the clock in 5s steps, ticking each time — the way the real
    /// housekeeping timer does. The watt ceiling integrates energy across
    /// elapsed samples, so one giant jump is not the same as the ticks it
    /// spans, and per-sample dt is clamped anyway.
    private func run(_ rig: Rig, _ seconds: Int) {
        for _ in 0..<max(1, seconds / 5) {
            rig.clock.advance(5)
            rig.engine.testTick()
        }
    }

    func testPowerLimitPausesChargingWhenOverCeiling() {
        let rig = makeRig()
        withPowerLimit(rig, watts: 60)
        rig.smc.inputW = 95
        setAC(rig, true)
        run(rig, 30)
        XCTAssertTrue(rig.engine.testLimitHolding,
            "95W against a 60W ceiling burns through the band and pauses")
        XCTAssertTrue(rig.smc.inhibited)
        XCTAssertEqual(rig.engine.testMode, .observing,
            "the watt cap is not the flap guard — mode stays observing")
    }

    /// The whole point of the ceiling. Charging is binary on this hardware:
    /// allowing it jumps the Mac from ~15W to ~63W whatever the ceiling says.
    /// So a 30W ceiling has to mean "charge about a third of the time" and
    /// land on 30W *on average* — not pause forever, and not behave the same
    /// as every other ceiling below 63W.
    func testPowerLimitAveragesOutToTheCeiling() {
        let rig = makeRig()
        withPowerLimit(rig, watts: 30)
        rig.smc.inputW = 15
        setAC(rig, true)

        var energy = 0.0
        var seconds = 0.0
        var chargingSamples = 0
        for i in 0..<600 {                       // 50 minutes of 5s ticks
            let w: Double = rig.smc.inhibited ? 15 : 63
            rig.smc.inputW = w
            rig.clock.advance(5)
            rig.engine.testTick()
            guard i >= 120 else { continue }     // skip the warm-up transient
            energy += w * 5
            seconds += 5
            if !rig.smc.inhibited { chargingSamples += 1 }
        }

        XCTAssertEqual(energy / seconds, 30, accuracy: 3,
            "average draw must land on the ceiling")
        XCTAssertGreaterThan(chargingSamples, 0,
            "the battery has to actually charge")
        XCTAssertLessThan(chargingSamples, 480,
            "and it must not just charge flat out")
        XCTAssertLessThan(rig.engine.testLimitDuty, 0.9)
        XCTAssertGreaterThan(rig.engine.testLimitDuty, 0.05)
        XCTAssertNotNil(rig.engine.testLimitAvgWatts)
        XCTAssertEqual(rig.engine.testLimitBaseWatts ?? 0, 15, accuracy: 2,
            "the Mac's own draw is sampled while charging is paused, so it "
            + "must read the idle figure and not the charging one")
    }

    /// A higher ceiling must buy strictly more charging time. This is what
    /// makes the slider a control rather than an on/off switch with 24
    /// identical positions.
    func testHigherCeilingChargesMoreOfTheTime() {
        func dutyAtCeiling(_ watts: Int) -> Double {
            let rig = makeRig()
            withPowerLimit(rig, watts: watts)
            rig.smc.inputW = 15
            setAC(rig, true)
            var charging = 0.0
            var total = 0.0
            for i in 0..<600 {
                rig.smc.inputW = rig.smc.inhibited ? 15 : 63
                rig.clock.advance(5)
                rig.engine.testTick()
                guard i >= 120 else { continue }
                total += 1
                if !rig.smc.inhibited { charging += 1 }
            }
            return charging / total
        }
        let low = dutyAtCeiling(25)
        let mid = dutyAtCeiling(40)
        let high = dutyAtCeiling(55)
        XCTAssertLessThan(low, mid, "40W must charge more than 25W")
        XCTAssertLessThan(mid, high, "55W must charge more than 40W")
    }

    func testPowerLimitResumesOnceDrawSettles() {
        let rig = makeRig()
        withPowerLimit(rig, watts: 60)
        rig.smc.inputW = 95
        setAC(rig, true)
        run(rig, 30)
        XCTAssertTrue(rig.engine.testLimitHolding)

        // Still over the ceiling with charging already off: no credit builds,
        // so the pause stays on.
        rig.smc.inputW = 70
        run(rig, 60)
        XCTAssertTrue(rig.engine.testLimitHolding,
            "still over the ceiling, so charging stays off")

        // 20W of headroom refills the band and the next burst starts.
        rig.smc.inputW = 40
        run(rig, 90)
        XCTAssertFalse(rig.engine.testLimitHolding)
        XCTAssertFalse(rig.smc.inhibited, "charging resumes")
    }

    func testPowerLimitDoesNotFlipOnAMomentarySpike() {
        let rig = makeRig()
        withPowerLimit(rig, watts: 60)
        rig.smc.inputW = 30
        setAC(rig, true)
        run(rig, 120)
        XCTAssertFalse(rig.engine.testLimitHolding)

        // One 5s sample at 200W is 700J of overdraw — real, but not enough to
        // empty a banked band. Charging must not chatter off for it.
        rig.smc.inputW = 200
        run(rig, 5)
        XCTAssertFalse(rig.engine.testLimitHolding,
            "a single spike must not flip charging")

        rig.smc.inputW = 30
        run(rig, 60)
        XCTAssertFalse(rig.engine.testLimitHolding)
    }

    func testPowerLimitReleasesOnBatteryAndOnDisable() {
        let rig = makeRig()
        withPowerLimit(rig, watts: 60)
        rig.smc.inputW = 95
        setAC(rig, true)
        run(rig, 30)
        XCTAssertTrue(rig.engine.testLimitHolding)

        setAC(rig, false)
        run(rig, 5)
        XCTAssertFalse(rig.engine.testLimitHolding,
            "unplugging lifts the cap")
        XCTAssertFalse(rig.smc.inhibited)

        // Re-engage, then turn the feature off: charging resumes at once.
        setAC(rig, true)
        run(rig, 40)
        XCTAssertTrue(rig.engine.testLimitHolding)
        var c = rig.engine.currentConfig()
        c.powerLimitEnabled = false
        rig.engine.applyConfig(c)
        XCTAssertFalse(rig.engine.testLimitHolding)
        XCTAssertFalse(rig.smc.inhibited,
            "turning the cap off resumes charging immediately")
    }

    func testPowerLimitReassertsWhenChargingSneaksBackOn() {
        let rig = makeRig()
        withPowerLimit(rig, watts: 60)
        rig.smc.inputW = 95
        setAC(rig, true)
        run(rig, 30)
        XCTAssertTrue(rig.smc.inhibited)

        rig.smc.inhibited = false            // something else re-enabled it
        run(rig, 5)
        XCTAssertTrue(rig.smc.inhibited,
            "the cap re-asserts the pause it owns")
    }

    func testPowerLimitOffByDefault() {
        let rig = makeRig()
        rig.smc.inputW = 200
        setAC(rig, true)
        run(rig, 60)
        XCTAssertFalse(rig.engine.testLimitHolding,
            "the cap must be opt-in")
        XCTAssertFalse(rig.smc.inhibited)
    }

    /// Regression. The resume threshold used to be `cap - 10`, which a ceiling
    /// set near the Mac's own idle draw could never reach — charging stayed
    /// off indefinitely and the battery drained while plugged in. A sliver of
    /// headroom now still charges, just rarely.
    func testPowerLimitResumesWhenCeilingSitsNearIdleDraw() {
        let rig = makeRig()
        withPowerLimit(rig, watts: 30)
        rig.smc.inputW = 55                  // charging hard, over the cap
        setAC(rig, true)
        run(rig, 60)
        XCTAssertTrue(rig.engine.testLimitHolding)

        // Charging is off now and the Mac alone sits 1W under the ceiling.
        // That is 1W of headroom — slow, but never never.
        rig.smc.inputW = 29
        run(rig, 1200)
        XCTAssertFalse(rig.engine.testLimitHolding,
            "1W under a 30W ceiling still leaves room to charge")
        XCTAssertFalse(rig.smc.inhibited)
        XCTAssertFalse(rig.engine.testLimitUnreachable)
    }

    func testPowerLimitFlagsAnUnreachableCeiling() {
        let rig = makeRig()
        withPowerLimit(rig, watts: 30)
        rig.smc.inputW = 45                  // the Mac alone wants more
        setAC(rig, true)
        run(rig, 60)
        XCTAssertTrue(rig.engine.testLimitHolding)
        XCTAssertFalse(rig.engine.testLimitUnreachable,
            "a short pause over the ceiling is not yet a verdict")

        run(rig, 200)
        XCTAssertTrue(rig.engine.testLimitUnreachable,
            "charging is already off and draw is still over the ceiling")

        // Raising the ceiling above the Mac's appetite clears both.
        withPowerLimit(rig, watts: 60)
        run(rig, 120)
        XCTAssertFalse(rig.engine.testLimitUnreachable)
        XCTAssertFalse(rig.engine.testLimitHolding)
    }

    func testPowerLimitReleasesWhenBatteryRunsDown() {
        let rig = makeRig()
        withPowerLimit(rig, watts: 30)
        rig.smc.inputW = 45
        setAC(rig, true, battery: 60)
        run(rig, 60)
        XCTAssertTrue(rig.engine.testLimitHolding)

        // An unreachable ceiling has been quietly draining the battery.
        setAC(rig, true, battery: 18)
        run(rig, 20)
        XCTAssertFalse(rig.engine.testLimitHolding,
            "the battery outranks the watt ceiling")
        XCTAssertFalse(rig.smc.inhibited)
        XCTAssertTrue(rig.engine.testLimitUnreachable)

        // And it must not clamp straight back on at the next tick.
        run(rig, 60)
        XCTAssertFalse(rig.engine.testLimitHolding)
        XCTAssertFalse(rig.smc.inhibited)
    }

    // MARK: - Ceiling changes

    /// Runs a realistic all-or-nothing load: 15W idle, 63W the moment charging
    /// is allowed. Returns the true average over the samples it took.
    @discardableResult
    private func runBursting(_ rig: Rig, _ seconds: Int) -> Double {
        var energy = 0.0
        var total = 0.0
        for _ in 0..<max(1, seconds / 5) {
            let w: Double = rig.smc.inhibited ? 15 : 63
            rig.smc.inputW = w
            rig.clock.advance(5)
            rig.engine.testTick()
            energy += w * 5
            total += 5
        }
        return energy / total
    }

    /// The bug behind "the ceiling isn't holding". The integrator and the
    /// reported average are both relative to a ceiling: at 45W they settle on
    /// 45W and ~60% duty. Left alone across a slider move they kept reporting
    /// exactly that against a fresh 30W ceiling for the length of the average's
    /// time constant — so the panel showed 47W and 66% under a 30W cap and
    /// looked like the cap did nothing.
    func testChangingTheCeilingRestartsTheMeasurement() {
        let rig = makeRig()
        withPowerLimit(rig, watts: 45)
        rig.smc.inputW = 15
        setAC(rig, true)
        runBursting(rig, 900)

        let settledAvg = rig.engine.testLimitAvgWatts ?? 0
        // Wide tolerance on purpose: the reported figure is an exponential
        // average whose time constant is close to the burst period, so it
        // ripples with the cycle. The test is about what happens next.
        XCTAssertEqual(settledAvg, 45, accuracy: 7,
            "precondition: 45W ceiling settles on 45W")
        XCTAssertGreaterThan(rig.engine.testLimitSampleSeconds, 90)

        withPowerLimit(rig, watts: 30)
        XCTAssertNil(rig.engine.testLimitAvgWatts,
            "the old ceiling's average must not carry over")
        XCTAssertEqual(rig.engine.testLimitBudget, 0,
            "and neither may the old ceiling's banked energy")
        XCTAssertEqual(rig.engine.testLimitSampleSeconds, 0)
        XCTAssertNil(rig.engine.currentStatus().powerLimitAverageWatts,
            "nothing is reported until the new ceiling has been measured")
        XCTAssertTrue(rig.engine.currentStatus().powerLimitSettling)
    }

    /// Half an average next to the ceiling is worse than no number at all: it
    /// is seeded from the first reading, so for the first minute it is mostly
    /// "whatever the Mac happened to be drawing".
    func testAverageIsWithheldUntilItHasEnoughHistory() {
        let rig = makeRig()
        withPowerLimit(rig, watts: 30)
        rig.smc.inputW = 15
        setAC(rig, true)

        runBursting(rig, 60)
        var s = rig.engine.currentStatus()
        XCTAssertNil(s.powerLimitAverageWatts)
        XCTAssertNil(s.powerLimitDutyPercent)
        XCTAssertTrue(s.powerLimitSettling)

        runBursting(rig, 120)
        s = rig.engine.currentStatus()
        XCTAssertNotNil(s.powerLimitAverageWatts)
        XCTAssertNotNil(s.powerLimitDutyPercent)
        XCTAssertFalse(s.powerLimitSettling)
    }

    /// End to end on the exact numbers from the bug report: settle at 45W,
    /// drop the slider to 30W, and the real draw has to follow it down.
    func testLoweringTheCeilingLowersTheRealAverage() {
        let rig = makeRig()
        withPowerLimit(rig, watts: 45)
        rig.smc.inputW = 15
        setAC(rig, true)
        let at45 = runBursting(rig, 1500)
        XCTAssertEqual(at45, 45, accuracy: 4)

        withPowerLimit(rig, watts: 30)
        let at30 = runBursting(rig, 1500)
        XCTAssertEqual(at30, 30, accuracy: 4,
            "the measured draw must follow the slider down, not linger")
        XCTAssertEqual(rig.engine.testLimitAvgWatts ?? 0, 30, accuracy: 6,
            "and the figure the panel shows must agree with reality")
    }

    /// Enabling the ceiling mid-session starts a measurement too — otherwise
    /// the first reading published is whatever the Mac drew at that instant.
    func testEnablingTheCeilingStartsAMeasurement() {
        let rig = makeRig()
        rig.smc.inputW = 63
        setAC(rig, true)
        run(rig, 300)
        withPowerLimit(rig, watts: 30)
        XCTAssertEqual(rig.engine.testLimitSampleSeconds, 0)
        XCTAssertTrue(rig.engine.currentStatus().powerLimitSettling)
    }

    /// One product, one version number.
    func testHelperReportsTheSharedVersion() {
        let rig = makeRig()
        XCTAssertEqual(rig.engine.currentStatus().helperVersion,
                       ChargeGuardVersion.current)
        XCTAssertFalse(ChargeGuardVersion.current.isEmpty)
    }
}
