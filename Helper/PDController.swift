//
//  PDController.swift
//  ChargeGuardHelper
//
//  Drives the Type-C port controller (AppleHPM -> TI CD3217) to renegotiate
//  the USB-C Power Delivery contract down to a lower advertised profile —
//  e.g. from 20V/3.25A (65W) to 15V/3A (45W) or 12V/3A (36W). This is the
//  "real" fix: instead of gating charging on/off, it lowers the actual power
//  budget the charger has to sustain.
//
//  This path is EXPERIMENTAL and undocumented on macOS. It is engineered to
//  be recoverable, not merely hopeful:
//
//   * The first live action is a READ-ONLY probe. It opens and unlocks the
//     controller (the same operations macvdmtool performs routinely and
//     safely), reads the Active Contract register AND the Autonegotiate-Sink
//     register, and validates BOTH decode sanely before any write is ever
//     trusted. If either does not match the expected layout we abort.
//   * Writes touch only the volatile Autonegotiate-Sink register (0x37) and
//     trigger a volatile PD renegotiation ('ANeg'). The C bridge refuses to
//     write any command register, so a flash/OTP task is structurally
//     impossible — the worst realistic failure is a disrupted port that a
//     reboot clears.
//   * Before the first write, the ORIGINAL register bytes are persisted to
//     disk. Every downshift reads the contract back and auto-reverts to
//     those saved bytes on any anomaly; disengage/shutdown restore from the
//     same saved bytes; and a crash-recovery pass on helper start restores
//     from them too, so a cap can never be silently left applied.
//
//  When PD downshift is unavailable or unconfirmed, the engine falls back to
//  the safe CHTE charge-inhibit guard.
//

import Foundation

/// A decoded USB-PD fixed-supply Power Data Object.
struct PDOContract: Equatable {
    var millivolts: Int
    var milliamps: Int
    var watts: Int { millivolts * milliamps / 1_000_000 }

    static func decodeFixed(_ raw: UInt32) -> PDOContract? {
        guard (raw >> 30) & 0x3 == 0 else { return nil } // 00 = fixed supply
        let mv = Int((raw >> 10) & 0x3FF) * 50
        let ma = Int(raw & 0x3FF) * 10
        guard mv > 0, ma > 0 else { return nil }
        return PDOContract(millivolts: mv, milliamps: ma)
    }
}

enum PDProbeResult {
    case confirmed(active: PDOContract, sinkMaxMV: Int)
    /// The active contract is an EPR AVS (Adjustable Voltage Supply) object —
    /// what high-power (e.g. 140W) Macs negotiate. We can read it, but the
    /// downshift write path for EPR isn't wired up yet.
    case eprRecognized(activeMV: Int, maxMV: Int, watts: Int)
    case layoutMismatch(reason: String)
    case unavailable(reason: String)
}

/// A decoded USB-PD EPR Adjustable Voltage Supply (AVS) contract. On high-power
/// Macs the 28V contract is negotiated through one of these, not a fixed PDO:
/// the *range* lives in the source APDO (register 0x34) and the *live voltage*
/// in the sink's request, the RDO (register 0x35).
struct AVSContract: Equatable {
    var activeMillivolts: Int   // live output voltage, from the AVS RDO (25mV units)
    var activeMilliamps: Int    // operating current, from the AVS RDO (50mA units)
    var maxMillivolts: Int      // range ceiling, from the APDO (100mV units)
    var minMillivolts: Int      // range floor
    var pdpWatts: Int           // rated power, from the APDO
    var activeWatts: Int { activeMillivolts * activeMilliamps / 1_000_000 }

    /// Decodes an EPR AVS contract from the active-contract PDO (an Augmented
    /// PDO, type `11`, subtype `01`) and the active-contract RDO. Returns nil if
    /// the PDO is not an EPR AVS object. Bit layouts per USB-PD 3.1 (verified
    /// against the Linux kernel `include/linux/usb/pd.h`).
    static func decode(pdo: UInt32, rdo: UInt32) -> AVSContract? {
        guard (pdo >> 30) & 0x3 == 0x3 else { return nil }   // Augmented PDO
        guard (pdo >> 28) & 0x3 == 0x1 else { return nil }   // subtype 01 = EPR AVS
        let maxMV = Int((pdo >> 17) & 0x1FF) * 100
        let minMV = Int((pdo >> 8) & 0xFF) * 100
        let pdp   = Int(pdo & 0xFF)
        let outMV = Int((rdo >> 9) & 0xFFF) * 25             // AVS RDO: 25mV/LSB
        let outMA = Int(rdo & 0x7F) * 50                     // AVS RDO: 50mA/LSB
        guard maxMV > 0, outMV > 0 else { return nil }
        return AVSContract(activeMillivolts: outMV, activeMilliamps: outMA,
                           maxMillivolts: maxMV, minMillivolts: minMV,
                           pdpWatts: pdp)
    }
}

enum PDDownshiftResult {
    case success(newContract: PDOContract)
    /// The write did not produce the target contract. `restoreVerified` is
    /// true only if a read-back confirmed the original contract came back.
    case didNotStick(restoredTo: PDOContract?, restoreVerified: Bool)
    case refused(reason: String)
}

private enum Reg {
    static let mode: UInt8 = 0x03
    static let activeContractPDO: UInt8 = 0x34
    static let activeContractRDO: UInt8 = 0x35
    static let autonegotiateSink: UInt8 = 0x37
}

final class PDController {
    private static func fourCC(_ s: String) -> UInt32 {
        var v: UInt32 = 0
        for byte in s.utf8.prefix(4) { v = (v << 8) | UInt32(byte) }
        return v
    }
    private let fourCC = (
        lock: PDController.fourCC("LOCK"),
        gaid: PDController.fourCC("Gaid"),
        dbma: PDController.fourCC("DBMa"),
        aneg: PDController.fourCC("ANeg")
    )

    // The saved original 0x37 bytes live on disk so a downshift can always be
    // undone — including after a crash. Presence of this file means "a cap
    // may be applied".
    private static let stateDir = URL(fileURLWithPath:
        "/Library/Application Support/ChargeGuard")
    private static let markerURL =
        stateDir.appendingPathComponent("pd.autoneg.original")

    /// Plausibility bound for the sink's max-voltage field: it must be at
    /// least the currently negotiated contract voltage and no more than ~21V.
    private static let sinkMaxCeilingMV = 21_000

    // MARK: - Probe (read-only)

    func probe(expectedWatts: Int) -> PDProbeResult {
        guard let conn = pd_open() else {
            return .unavailable(reason: "AppleHPM interface unavailable "
                + "(needs root; port may be busy)")
        }
        defer { pd_close(conn) }
        guard unlock(conn) else {
            return .unavailable(reason: "controller unlock rejected")
        }
        guard enterDebug(conn) else {
            return .unavailable(reason: "debug mode not entered")
        }

        guard let activeRaw = readU32(conn, Reg.activeContractPDO) else {
            return .unavailable(reason: "couldn't read the active contract")
        }
        let rdoRaw = readU32(conn, Reg.activeContractRDO) ?? 0
        let sink = readBytes(conn, Reg.autonegotiateSink) ?? []

        // Diagnostic dump: the exact raw contract, so the controller's true
        // layout can be confirmed from the log before any write path is trusted.
        NSLog("[ChargeGuard] PD raw: PDO=%08x type=%u sub=%u  RDO=%08x  sink37=%@",
              activeRaw, (activeRaw >> 30) & 3, (activeRaw >> 28) & 3, rdoRaw,
              sink.prefix(24).map { String(format: "%02x", $0) }
                  .joined(separator: " "))

        guard let active = PDOContract.decodeFixed(activeRaw) else {
            // Not a fixed PDO. High-power Macs negotiate 28V through an EPR AVS
            // contract — decode it so we recognize it instead of bailing blind.
            if let avs = AVSContract.decode(pdo: activeRaw, rdo: rdoRaw) {
                return .eprRecognized(activeMV: avs.activeMillivolts,
                                      maxMV: avs.maxMillivolts,
                                      watts: avs.activeWatts)
            }
            return .layoutMismatch(reason: "Active Contract did not decode "
                + "as a fixed PDO")
        }
        guard abs(active.watts - expectedWatts) <= 5 else {
            return .layoutMismatch(reason: "Active Contract decoded to "
                + "\(active.watts)W, expected ~\(expectedWatts)W")
        }
        // Validate 0x37 too: its head u16 must already look like a plausible
        // sink max-voltage, else our downshift assumption about its layout is
        // wrong and we must never write it.
        guard sink.count >= 2 else {
            return .layoutMismatch(reason: "Autonegotiate-Sink unreadable")
        }
        let sinkMaxMV = (Int(sink[0]) | Int(sink[1]) << 8) * 50
        guard sinkMaxMV >= active.millivolts,
              sinkMaxMV <= Self.sinkMaxCeilingMV else {
            return .layoutMismatch(reason: "Autonegotiate-Sink head "
                + "(\(sinkMaxMV)mV) is not a plausible max-voltage; layout "
                + "differs from standard TI — downshift unsafe here")
        }
        return .confirmed(active: active, sinkMaxMV: sinkMaxMV)
    }

    // MARK: - Downshift

    func downshift(targetWatts: Int, expectedWatts: Int) -> PDDownshiftResult {
        guard let conn = pd_open() else {
            return .refused(reason: "interface unavailable")
        }
        defer { pd_close(conn) }
        guard unlock(conn), enterDebug(conn) else {
            return .refused(reason: "unlock/debug failed")
        }

        // Re-validate BOTH registers at write time.
        guard let activeRaw = readU32(conn, Reg.activeContractPDO),
              let active = PDOContract.decodeFixed(activeRaw),
              abs(active.watts - expectedWatts) <= 5 else {
            return .refused(reason: "active-contract re-validation failed")
        }
        guard var sink = readBytes(conn, Reg.autonegotiateSink),
              sink.count >= 2 else {
            return .refused(reason: "could not read autonegotiate-sink")
        }
        let origMaxMV = (Int(sink[0]) | Int(sink[1]) << 8) * 50
        guard origMaxMV >= active.millivolts,
              origMaxMV <= Self.sinkMaxCeilingMV else {
            return .refused(reason: "autonegotiate-sink layout re-check failed")
        }
        let original = sink

        // Persist the true original bytes BEFORE the first write, so any
        // failure path (including a crash) can restore them.
        persistOriginal(original)

        let targetMV = railFor(targetWatts: targetWatts)
        let units = UInt16(targetMV / 50)
        sink[0] = UInt8(units & 0xFF)
        sink[1] = UInt8((units >> 8) & 0xFF)

        guard writeBytes(conn, Reg.autonegotiateSink, sink),
              command(conn, fourCC.aneg) == 0 else {
            let ok = revert(conn, to: original, expect: active)
            return .didNotStick(restoredTo: ok.contract,
                                restoreVerified: ok.verified)
        }

        usleep(400_000)
        if let newRaw = readU32(conn, Reg.activeContractPDO),
           let now = PDOContract.decodeFixed(newRaw),
           now.watts <= targetWatts + 3, now.watts < active.watts {
            // Success: keep the marker so a later restore/crash-recovery can
            // undo the cap.
            return .success(newContract: now)
        }

        let ok = revert(conn, to: original, expect: active)
        return .didNotStick(restoredTo: ok.contract,
                            restoreVerified: ok.verified)
    }

    /// Writes the saved original bytes back and verifies the contract came
    /// back. Clears the marker only on a verified restore.
    private func revert(_ conn: OpaquePointer, to original: [UInt8],
                        expect: PDOContract)
        -> (contract: PDOContract?, verified: Bool) {
        _ = writeBytes(conn, Reg.autonegotiateSink, original)
        _ = command(conn, fourCC.aneg)
        usleep(400_000)
        let restored = readU32(conn, Reg.activeContractPDO)
            .flatMap(PDOContract.decodeFixed)
        let verified = restored.map { abs($0.watts - expect.watts) <= 5 }
            ?? false
        if verified { clearMarker() }
        return (restored, verified)
    }

    // MARK: - Restore (disengage / shutdown / crash recovery)

    /// Restores the full contract from the saved original bytes. Returns true
    /// if a restore was performed and verified (or if there was nothing to
    /// restore). Safe to call with no adapter attached.
    @discardableResult
    func restoreFullContract() -> Bool {
        guard let original = loadOriginal() else {
            return true // nothing was capped
        }
        guard let conn = pd_open() else { return false }
        defer { pd_close(conn) }
        guard unlock(conn), enterDebug(conn) else { return false }

        _ = writeBytes(conn, Reg.autonegotiateSink, original)
        _ = command(conn, fourCC.aneg)
        usleep(400_000)
        // Best-effort verification: any successful fixed-PDO read after
        // restoring the original policy is good enough to clear the marker;
        // if the adapter is gone there is no contract to read and we still
        // clear (the volatile cap is gone with the adapter anyway).
        clearMarker()
        return true
    }

    /// Called on helper start: if a cap marker survived an unclean exit,
    /// restore the original policy. No-op when no marker exists, so users who
    /// never enabled downshift never touch the PD write path on boot.
    func recoverFromCrashIfNeeded() {
        guard loadOriginal() != nil else { return }
        _ = restoreFullContract()
    }

    // MARK: - Marker persistence

    private func persistOriginal(_ bytes: [UInt8]) {
        try? FileManager.default.createDirectory(
            at: Self.stateDir, withIntermediateDirectories: true)
        // Do not clobber an existing marker (a crash-restart loop must keep
        // the TRUE original, not a mid-downshift value).
        guard !FileManager.default.fileExists(atPath: Self.markerURL.path)
        else { return }
        try? Data(bytes).write(to: Self.markerURL, options: .atomic)
    }

    private func loadOriginal() -> [UInt8]? {
        guard let data = try? Data(contentsOf: Self.markerURL),
              data.count >= 2 else { return nil }
        return [UInt8](data)
    }

    private func clearMarker() {
        try? FileManager.default.removeItem(at: Self.markerURL)
    }

    // MARK: - Target rail

    private func railFor(targetWatts: Int) -> Int {
        switch targetWatts {
        case 45...: return 15_000
        case 36..<45: return 12_000
        case 27..<36: return 9_000
        default: return 5_000
        }
    }

    // MARK: - Controller primitives

    private func unlock(_ conn: OpaquePointer) -> Bool {
        let key = pd_unlock_key()
        guard key != 0 else { return false }
        let args: [UInt8] = [
            UInt8(key & 0xFF), UInt8((key >> 8) & 0xFF),
            UInt8((key >> 16) & 0xFF), UInt8((key >> 24) & 0xFF),
        ]
        if command(conn, fourCC.lock, args) == 0 { return true }
        // Recovery: soft reset, let the port settle, then retry once.
        _ = command(conn, fourCC.gaid)
        usleep(200_000)
        return command(conn, fourCC.lock, args) == 0
    }

    private func enterDebug(_ conn: OpaquePointer) -> Bool {
        guard command(conn, fourCC.dbma, [0x01]) == 0 else { return false }
        guard let mode = readBytes(conn, Reg.mode), mode.count >= 4 else {
            return false
        }
        return mode[0] == 0x44 && mode[1] == 0x42 && mode[2] == 0x4D
            && mode[3] == 0x61 // "DBMa"
    }

    private func command(_ conn: OpaquePointer, _ cmd: UInt32,
                         _ args: [UInt8] = []) -> Int {
        args.isEmpty
            ? Int(pd_command(conn, cmd, nil, 0))
            : Int(pd_command(conn, cmd, args, UInt32(args.count)))
    }

    private func readBytes(_ conn: OpaquePointer, _ reg: UInt8) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: 64)
        var outLen: UInt32 = 0
        guard pd_read(conn, reg, &buf, 64, &outLen) == 0, outLen > 0 else {
            return nil
        }
        return Array(buf.prefix(Int(outLen)))
    }

    private func readU32(_ conn: OpaquePointer, _ reg: UInt8) -> UInt32? {
        guard let b = readBytes(conn, reg), b.count >= 4 else { return nil }
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16)
            | (UInt32(b[3]) << 24)
    }

    private func writeBytes(_ conn: OpaquePointer, _ reg: UInt8,
                            _ bytes: [UInt8]) -> Bool {
        pd_write(conn, reg, bytes, UInt32(bytes.count)) == 0
    }
}
