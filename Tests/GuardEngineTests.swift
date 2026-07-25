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

    func testPowerLimitPausesChargingWhenOverCeiling() {
        let rig = makeRig()
        withPowerLimit(rig, watts: 60)
        rig.smc.inputW = 95
        setAC(rig, true)
        rig.clock.advance(15)
        rig.engine.testTick()
        XCTAssertTrue(rig.engine.testLimitHolding,
            "95W over a 60W ceiling must pause charging")
        XCTAssertTrue(rig.smc.inhibited)
        XCTAssertEqual(rig.engine.testMode, .observing,
            "the watt cap is not the flap guard — mode stays observing")
    }

    func testPowerLimitResumesOnceDrawSettles() {
        let rig = makeRig()
        withPowerLimit(rig, watts: 60)
        rig.smc.inputW = 95
        setAC(rig, true)
        rig.clock.advance(15); rig.engine.testTick()
        XCTAssertTrue(rig.engine.testLimitHolding)

        // Still over the ceiling: the pause stays on.
        rig.smc.inputW = 70
        rig.clock.advance(70); rig.engine.testTick()
        XCTAssertTrue(rig.engine.testLimitHolding,
            "still over the ceiling, so charging stays off")

        rig.smc.inputW = 40
        rig.clock.advance(70); rig.engine.testTick()
        XCTAssertFalse(rig.engine.testLimitHolding)
        XCTAssertFalse(rig.smc.inhibited, "charging resumes")
    }

    func testPowerLimitRespectsDwellBeforeFlipping() {
        let rig = makeRig()
        withPowerLimit(rig, watts: 60)
        rig.smc.inputW = 95
        setAC(rig, true)
        rig.clock.advance(15); rig.engine.testTick()
        XCTAssertTrue(rig.engine.testLimitHolding)

        // Draw collapses immediately, but the 60s resume dwell is not up.
        rig.smc.inputW = 20
        rig.clock.advance(5); rig.engine.testTick()
        XCTAssertTrue(rig.engine.testLimitHolding,
            "charging must not chatter back on within the dwell")
    }

    func testPowerLimitReleasesOnBatteryAndOnDisable() {
        let rig = makeRig()
        withPowerLimit(rig, watts: 60)
        rig.smc.inputW = 95
        setAC(rig, true)
        rig.clock.advance(15); rig.engine.testTick()
        XCTAssertTrue(rig.engine.testLimitHolding)

        setAC(rig, false)
        rig.clock.advance(5); rig.engine.testTick()
        XCTAssertFalse(rig.engine.testLimitHolding,
            "unplugging lifts the cap")
        XCTAssertFalse(rig.smc.inhibited)

        // Re-engage, then turn the feature off: charging resumes at once.
        setAC(rig, true)
        rig.clock.advance(15); rig.engine.testTick()
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
        rig.clock.advance(15); rig.engine.testTick()
        XCTAssertTrue(rig.smc.inhibited)

        rig.smc.inhibited = false            // something else re-enabled it
        rig.clock.advance(5); rig.engine.testTick()
        XCTAssertTrue(rig.smc.inhibited,
            "the cap re-asserts the pause it owns")
    }

    func testPowerLimitOffByDefault() {
        let rig = makeRig()
        rig.smc.inputW = 200
        setAC(rig, true)
        rig.clock.advance(30); rig.engine.testTick()
        XCTAssertFalse(rig.engine.testLimitHolding,
            "the cap must be opt-in")
        XCTAssertFalse(rig.smc.inhibited)
    }

    /// Regression. The resume threshold used to be `cap - 10`, which a ceiling
    /// set near the Mac's own idle draw could never reach — charging stayed
    /// off indefinitely and the battery drained while plugged in. Once the
    /// pause is on, draw is charging-free, so anything under the ceiling means
    /// there is room to charge.
    func testPowerLimitResumesWhenCeilingSitsNearIdleDraw() {
        let rig = makeRig()
        withPowerLimit(rig, watts: 30)
        rig.smc.inputW = 55                  // charging hard, over the cap
        setAC(rig, true)
        rig.clock.advance(15); rig.engine.testTick()
        XCTAssertTrue(rig.engine.testLimitHolding)

        // Charging is off now and the Mac alone sits just under the ceiling.
        rig.smc.inputW = 29
        rig.clock.advance(70); rig.engine.testTick()
        XCTAssertFalse(rig.engine.testLimitHolding,
            "29W under a 30W ceiling leaves room to charge")
        XCTAssertFalse(rig.smc.inhibited)
        XCTAssertFalse(rig.engine.testLimitUnreachable)
    }

    func testPowerLimitFlagsAnUnreachableCeiling() {
        let rig = makeRig()
        withPowerLimit(rig, watts: 30)
        rig.smc.inputW = 45                  // the Mac alone wants more
        setAC(rig, true)
        rig.clock.advance(15); rig.engine.testTick()
        XCTAssertTrue(rig.engine.testLimitHolding)
        XCTAssertFalse(rig.engine.testLimitUnreachable,
            "one tick over the ceiling is not yet a verdict")

        rig.clock.advance(70); rig.engine.testTick()
        XCTAssertTrue(rig.engine.testLimitUnreachable,
            "charging is already off and draw is still over the ceiling")

        // Raising the ceiling above the Mac's appetite clears both.
        withPowerLimit(rig, watts: 60)
        rig.clock.advance(70); rig.engine.testTick()
        XCTAssertFalse(rig.engine.testLimitUnreachable)
        XCTAssertFalse(rig.engine.testLimitHolding)
    }

    func testPowerLimitReleasesWhenBatteryRunsDown() {
        let rig = makeRig()
        withPowerLimit(rig, watts: 30)
        rig.smc.inputW = 45
        setAC(rig, true, battery: 60)
        rig.clock.advance(15); rig.engine.testTick()
        XCTAssertTrue(rig.engine.testLimitHolding)

        // An unreachable ceiling has been quietly draining the battery.
        setAC(rig, true, battery: 18)
        rig.clock.advance(70); rig.engine.testTick()
        XCTAssertFalse(rig.engine.testLimitHolding,
            "the battery outranks the watt ceiling")
        XCTAssertFalse(rig.smc.inhibited)
        XCTAssertTrue(rig.engine.testLimitUnreachable)

        // And it must not clamp straight back on at the next tick.
        rig.clock.advance(70); rig.engine.testTick()
        XCTAssertFalse(rig.engine.testLimitHolding)
        XCTAssertFalse(rig.smc.inhibited)
    }
}
