//
//  GuardConfigTests.swift
//  ChargeGuardHelperTests
//
//  The helper applies `sanitized()` to every config arriving over XPC, so a
//  hostile or buggy client cannot drive the engine into degenerate behavior.
//  These tests pin the clamp ranges in both directions.
//

import XCTest

final class GuardConfigTests: XCTestCase {

    func testDefaultsAreUnchangedBySanitize() {
        let d = GuardConfig()
        XCTAssertEqual(d, d.sanitized(),
            "the shipped defaults must already be within every clamp range")
    }

    func testLowValuesClampUp() {
        var c = GuardConfig()
        c.flapTrigger = 0
        c.flapWindow = 1
        c.probeAfter = 1
        c.probeGrace = 0
        c.probeMax = 0
        c.swapGap = 0
        c.swapProbeDelay = 0
        c.pdTargetWatts = 1
        let s = c.sanitized()
        XCTAssertEqual(s.flapTrigger, 2)
        XCTAssertEqual(s.flapWindow, 60)
        XCTAssertEqual(s.probeAfter, 60)
        XCTAssertEqual(s.probeGrace, 30)
        XCTAssertGreaterThanOrEqual(s.probeMax, s.probeAfter)
        XCTAssertEqual(s.swapGap, 5)
        XCTAssertEqual(s.swapProbeDelay, 10)
        XCTAssertEqual(s.pdTargetWatts, 27)
    }

    func testHighValuesClampDown() {
        var c = GuardConfig()
        c.flapTrigger = 100
        c.flapWindow = 99_999
        c.probeAfter = 99_999
        c.probeGrace = 99_999
        c.probeMax = 999_999
        c.swapGap = 99_999
        c.swapProbeDelay = 99_999
        c.pdTargetWatts = 999
        let s = c.sanitized()
        XCTAssertEqual(s.flapTrigger, 10)
        XCTAssertEqual(s.flapWindow, 600)
        XCTAssertEqual(s.probeAfter, 1800)
        XCTAssertEqual(s.probeGrace, 600)
        XCTAssertEqual(s.probeMax, 7200)
        XCTAssertEqual(s.swapGap, 300)
        XCTAssertEqual(s.swapProbeDelay, 600)
        XCTAssertEqual(s.pdTargetWatts, 60)
    }

    func testProbeMaxNeverBelowProbeAfter() {
        var c = GuardConfig()
        c.probeAfter = 1800     // max allowed
        c.probeMax = 600        // below probeAfter on purpose
        let s = c.sanitized()
        XCTAssertGreaterThanOrEqual(s.probeMax, s.probeAfter,
            "probeMax must never sanitize below probeAfter (no probe storm)")
    }
}
