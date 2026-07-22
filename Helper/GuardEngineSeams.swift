//
//  GuardEngineSeams.swift
//  ChargeGuardHelper
//
//  Dependency-injection seams for GuardEngine. In production the engine is
//  constructed with the real implementations (the initializer defaults wire
//  them up, so main.swift is unchanged). In tests these protocols are backed
//  by in-memory fakes so the state machine can be driven deterministically
//  without touching IOKit, `pmset`, the wall/uptime clock, or /Library.
//

import Foundation

// MARK: - Charge control + telemetry (SMC)

/// The charging gate and read-only telemetry the engine needs from the SMC.
/// `SMCService` is the production implementation.
protocol ChargeControlling: AnyObject {
    func isChargingInhibited() throws -> Bool
    func setChargingInhibited(_ inhibited: Bool) throws
    func adapterWatts() -> Double
    func chargeCurrentMA() -> Int
    func inputPowerWatts() -> Double?
}

extension SMCService: ChargeControlling {}

// MARK: - Power-source + sleep/wake notifications

/// AC attach/detach and sleep/wake callbacks the engine subscribes to.
/// `PowerMonitor` is the production implementation.
protocol PowerMonitoring: AnyObject {
    var onPowerSourceChange: ((PowerSnapshot) -> Void)? { get set }
    var onWake: (() -> Void)? { get set }
    func start()
}

extension PowerMonitor: PowerMonitoring {}

// MARK: - Experimental PD downshift

/// The USB-C PD-downshift surface. `PDController` is the production
/// implementation; it drives an undocumented Type-C controller, so tests use
/// a fake and never exercise the real IOKit path.
protocol PDControlling: AnyObject {
    func probe(expectedWatts: Int) -> PDProbeResult
    func downshift(targetWatts: Int, expectedWatts: Int) -> PDDownshiftResult
    func restoreFullContract() -> Bool
    func recoverFromCrashIfNeeded()
}

extension PDController: PDControlling {}

// MARK: - AC Low Power Mode

/// AC Low Power Mode read/write, isolated so the engine never shells out to
/// `pmset` in tests.
protocol PowerModeControlling {
    func readACLowPowerMode() -> Int?
    func setACLowPowerMode(_ value: Int)
}

/// Production `PowerModeControlling`, backed by `pmset -c lowpowermode`.
struct PmsetPowerMode: PowerModeControlling {
    func readACLowPowerMode() -> Int? {
        guard let out = Self.shell("/usr/bin/pmset", ["-g", "custom"]) else {
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

    func setACLowPowerMode(_ value: Int) {
        _ = Self.shell("/usr/bin/pmset", ["-c", "lowpowermode", "\(value)"])
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
}
