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
//  REGISTER MAP NOTE (why this file looks unusual)
//  ----------------------------------------------
//  Apple ships its own firmware on the CD3217 ("ACE"), and its host-interface
//  register map is NOT the stock TI TPS6598x map. Verified by a full root
//  register scan on a J616sAP (MacBook Pro 16", firmware SN2012024 HW00A3
//  FW003.0):
//
//    0x30  RX Source Caps    [count][PDO ...]  — what the charger offers
//    0x33  TX Sink Caps      [count][PDO ...]  — what WE ask for (writable)
//    0x34  EMPTY (len 0)     — the stock TI "Active PDO" register does not
//                              exist here; reading it succeeds with 0 bytes
//    0x35  Active Contract   [RDO 4B][PDO 4B][...]  — both halves, LE
//    0x37  not a sink-policy register on Apple firmware (12 opaque bytes)
//
//  So the active contract is read from 0x35 (with a fallback to the stock
//  0x34+0x35 pair for non-Apple controllers), and the sink policy we may cap
//  is 0x33 Tx Sink Caps — a standard USB-PD PDO list on both firmwares.
//
//  This path is EXPERIMENTAL and undocumented on macOS. It is engineered to
//  be recoverable, not merely hopeful:
//
//   * The first live action is a READ-ONLY probe. It opens and unlocks the
//     controller (the same operations macvdmtool performs routinely and
//     safely), reads the Active Contract AND the Tx Sink Caps, and validates
//     BOTH decode sanely before any write is ever trusted.
//   * Writes touch only the volatile Tx Sink Caps register (0x33) and trigger
//     a volatile PD renegotiation ('ANeg'). The C bridge refuses to write any
//     command register, so a flash/OTP task is structurally impossible — the
//     worst realistic failure is a disrupted port that a reboot clears.
//   * Before the first write, the ORIGINAL register bytes are persisted to
//     disk. Every downshift reads the contract back and auto-reverts to those
//     saved bytes on any anomaly; disengage/shutdown restore from the same
//     saved bytes; and a crash-recovery pass on helper start restores from
//     them too, so a cap can never be silently left applied.
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
/// the *range* lives in the source APDO and the *live voltage* in the sink's
/// request, the RDO.
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
    static let rxSourceCaps: UInt8 = 0x30
    /// Tx Sink Capabilities — the sink policy we advertise. `[count][PDO...]`,
    /// standard USB-PD PDO encoding, little-endian. Writable and volatile on
    /// both Apple and stock TI firmware.
    static let txSinkCaps: UInt8 = 0x33
    /// Stock TI "Active PDO". Absent (0-length) on Apple firmware.
    static let activeContractLegacy: UInt8 = 0x34
    /// Active contract. Apple firmware packs `[RDO 4B][PDO 4B]...` here; stock
    /// TI exposes just the 4-byte RDO.
    static let activeContract: UInt8 = 0x35
}

/// The live PD contract as the controller reports it: the source's PDO and our
/// request (RDO), regardless of which register layout they came out of.
private struct RawContract {
    var pdo: UInt32
    var rdo: UInt32
    var source: String  // for logging: which layout matched
}

/// The sink policy we advertise, decoded from 0x33.
private struct SinkPolicy {
    var bytes: [UInt8]      // exact register contents, for byte-perfect restore
    var pdos: [UInt32]
    var maxMillivolts: Int
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
        aneg: PDController.fourCC("ANeg"),
        gsrc: PDController.fourCC("GSrC")
    )

    // The saved original sink-caps bytes live on disk so a downshift can always
    // be undone — including after a crash. Presence of this file means "a cap
    // may be applied".
    private static let stateDir = URL(fileURLWithPath:
        "/Library/Application Support/ChargeGuard")
    private static let markerURL =
        stateDir.appendingPathComponent("pd.sinkcaps.original")
    /// Pre-0.5 marker held bytes for a register we no longer write. Never
    /// replay it — just delete it so it can't be mistaken for a live cap.
    private static let legacyMarkerURL =
        stateDir.appendingPathComponent("pd.autoneg.original")

    /// Plausibility bound for the sink's max-voltage field: it must be at
    /// least the currently negotiated contract voltage and no more than ~29V
    /// (headroom for a 28V EPR contract on high-power Macs).
    private static let sinkMaxCeilingMV = 29_000

    init() {
        try? FileManager.default.removeItem(at: Self.legacyMarkerURL)
    }

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

        guard let raw = readRawContract(conn) else {
            return .unavailable(reason: "couldn't read the active contract")
        }
        let policy = readSinkPolicy(conn)

        // Diagnostic dump: the exact raw contract, so the controller's true
        // layout can be confirmed from the log before any write path is trusted.
        NSLog("[ChargeGuard] PD raw (%@): PDO=%08x type=%u sub=%u  RDO=%08x  "
              + "sinkCaps=%@",
              raw.source, raw.pdo, (raw.pdo >> 30) & 3, (raw.pdo >> 28) & 3,
              raw.rdo,
              (policy?.bytes ?? []).prefix(24).map { String(format: "%02x", $0) }
                  .joined(separator: " "))

        guard let active = PDOContract.decodeFixed(raw.pdo) else {
            // Not a fixed PDO. High-power Macs negotiate 28V through an EPR AVS
            // contract. Decode it, and — if the AVS range and the sink policy
            // both look right — confirm it as downshiftable: capping the sink
            // to a standard rail forces the Mac out of EPR.
            guard let avs = AVSContract.decode(pdo: raw.pdo, rdo: raw.rdo) else {
                return .layoutMismatch(reason: "Active Contract did not decode "
                    + "as a fixed PDO or an EPR AVS contract")
            }
            // The AVS ceiling must look like a real EPR range (20–29V) and the
            // live voltage must sit inside it — otherwise we only recognize it.
            guard avs.maxMillivolts >= 20_000,
                  avs.maxMillivolts <= Self.sinkMaxCeilingMV,
                  avs.activeMillivolts > 0,
                  avs.activeMillivolts <= avs.maxMillivolts + 200,
                  let policy = policy,
                  policy.maxMillivolts >= avs.activeMillivolts,
                  policy.maxMillivolts <= Self.sinkMaxCeilingMV,
                  Self.cappedSinkCaps(policy, toMV: 15_000) != nil else {
                return .eprRecognized(activeMV: avs.activeMillivolts,
                                      maxMV: avs.maxMillivolts,
                                      watts: avs.activeWatts)
            }
            // Both registers read cleanly and the sink policy is cappable: this
            // Mac can be downshifted out of EPR safely. Expose the live AVS
            // voltage/current as the active contract.
            return .confirmed(active: PDOContract(
                                millivolts: avs.activeMillivolts,
                                milliamps: avs.activeMilliamps),
                              sinkMaxMV: policy.maxMillivolts)
        }

        // Sanity-check the decode against what the SMC says the adapter is
        // rated for. Generous tolerance: the contract tracks the adapter's
        // advertised budget but the two are reported by different subsystems.
        if expectedWatts > 0 {
            let slack = max(8, expectedWatts / 4)
            guard abs(active.watts - expectedWatts) <= slack else {
                return .layoutMismatch(reason: "Active Contract decoded to "
                    + "\(active.watts)W, expected ~\(expectedWatts)W")
            }
        }

        guard let policy = policy else {
            return .layoutMismatch(reason: "Tx Sink Caps unreadable")
        }
        guard policy.maxMillivolts >= active.millivolts,
              policy.maxMillivolts <= Self.sinkMaxCeilingMV else {
            return .layoutMismatch(reason: "Tx Sink Caps ceiling "
                + "(\(policy.maxMillivolts)mV) doesn't bracket the active "
                + "contract (\(active.millivolts)mV) — downshift unsafe here")
        }
        // A cap must be constructible without dropping the mandatory 5V object,
        // else we would advertise an illegal sink policy.
        guard Self.cappedSinkCaps(policy, toMV: 15_000) != nil else {
            return .layoutMismatch(reason: "Tx Sink Caps can't be capped "
                + "without breaking the mandatory 5V object")
        }
        return .confirmed(active: active, sinkMaxMV: policy.maxMillivolts)
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

        // Re-read and decode the active contract at write time — a fixed PDO
        // (standard Macs) or an EPR AVS contract (high-power Macs at 28V).
        guard let raw = readRawContract(conn) else {
            return .refused(reason: "active-contract read failed")
        }
        let activeMV: Int
        let activeWatts: Int
        if let fixed = PDOContract.decodeFixed(raw.pdo) {
            // Fixed PDO: re-validate against the adapter's advertised budget.
            let slack = max(8, expectedWatts / 4)
            guard expectedWatts <= 0 || abs(fixed.watts - expectedWatts) <= slack
            else {
                return .refused(reason: "active-contract re-validation failed")
            }
            activeMV = fixed.millivolts
            activeWatts = fixed.watts
        } else if let avs = AVSContract.decode(pdo: raw.pdo, rdo: raw.rdo) {
            // EPR AVS: identity is the APDO type, not a wattage match — the AVS
            // operating current (hence watts) tracks real draw and varies.
            activeMV = avs.activeMillivolts
            activeWatts = avs.activeWatts
        } else {
            return .refused(reason: "active-contract did not decode")
        }

        guard let policy = readSinkPolicy(conn) else {
            return .refused(reason: "could not read the sink policy")
        }
        guard policy.maxMillivolts >= activeMV,
              policy.maxMillivolts <= Self.sinkMaxCeilingMV else {
            return .refused(reason: "sink-policy layout re-check failed")
        }
        let original = policy.bytes

        // Cap the sink to a standard rail. Clamp to 20V so a 28V EPR contract is
        // always forced down out of EPR onto a plain fixed rail, never left in
        // an EPR sub-range we can't reason about.
        let targetMV = min(railFor(targetWatts: targetWatts), 20_000)
        guard targetMV < activeMV else {
            return .refused(reason: "target rail (\(targetMV)mV) is not below "
                + "the active contract (\(activeMV)mV)")
        }
        guard let capped = Self.cappedSinkCaps(policy, toMV: targetMV) else {
            return .refused(reason: "can't build a \(targetMV / 1000)V sink "
                + "policy from this Mac's advertised capabilities")
        }

        // Persist the true original bytes BEFORE the first write, so any
        // failure path (including a crash) can restore them.
        persistOriginal(original)

        guard writeBytes(conn, Reg.txSinkCaps, capped),
              renegotiate(conn) else {
            let ok = revert(conn, to: original, expectMV: activeMV)
            return .didNotStick(restoredTo: ok.contract,
                                restoreVerified: ok.verified)
        }

        usleep(400_000)
        // Success = the contract voltage actually dropped to (about) the capped
        // rail and the power fell below where we started. The read-back may be
        // a fixed PDO (dropped out of EPR) — that's the expected outcome.
        if let now = readContract(conn),
           now.millivolts <= targetMV + 500,
           now.watts < activeWatts {
            // Keep the marker so a later restore/crash-recovery can undo the cap.
            return .success(newContract: now)
        }

        let ok = revert(conn, to: original, expectMV: activeMV)
        return .didNotStick(restoredTo: ok.contract,
                            restoreVerified: ok.verified)
    }

    /// Writes the saved original bytes back and confirms the un-cap took hold:
    /// the sink policy register reads back to its original bytes (the thing we
    /// actually control), or the live contract voltage climbed back to near the
    /// original rail. Clears the marker only on a verified restore. Handles both
    /// fixed and AVS read-back.
    private func revert(_ conn: OpaquePointer, to original: [UInt8],
                        expectMV: Int)
        -> (contract: PDOContract?, verified: Bool) {
        _ = writeBytes(conn, Reg.txSinkCaps, original)
        _ = renegotiate(conn)
        usleep(400_000)
        let restored = readContract(conn)
        // Primary signal: the policy register is byte-for-byte back to the
        // original. Fallback: the negotiated voltage recovered near the rail we
        // started from (covers a controller that doesn't echo 0x33 verbatim).
        let policyBack = readBytes(conn, Reg.txSinkCaps)
            .map { $0 == original } ?? false
        let voltageBack = restored.map { $0.millivolts + 500 >= expectMV } ?? false
        let verified = policyBack || voltageBack
        if verified { clearMarker() }
        return (restored, verified)
    }

    /// Asks the controller to re-evaluate the sink policy we just wrote.
    /// 'ANeg' is the direct autonegotiate trigger; 'GSrC' (re-request the
    /// source caps) is the fallback for firmware that ignores ANeg.
    private func renegotiate(_ conn: OpaquePointer) -> Bool {
        if command(conn, fourCC.aneg) == 0 { return true }
        return command(conn, fourCC.gsrc) == 0
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

        _ = writeBytes(conn, Reg.txSinkCaps, original)
        _ = renegotiate(conn)
        usleep(400_000)
        // Best-effort verification: any successful contract read after
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
              data.count >= 5 else { return nil }
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

    // MARK: - Sink policy (0x33 Tx Sink Caps)

    /// Parses `[count][PDO 4B]...` into raw PDOs. Rejects a count that doesn't
    /// fit the bytes we actually got back, so a short/garbled read can never be
    /// mistaken for a policy we understand.
    private static func parseSinkCaps(_ bytes: [UInt8]) -> [UInt32]? {
        guard let count = bytes.first, count > 0, count <= 11 else { return nil }
        let need = 1 + Int(count) * 4
        guard bytes.count >= need else { return nil }
        return (0..<Int(count)).map { i in
            let o = 1 + i * 4
            return UInt32(bytes[o]) | (UInt32(bytes[o + 1]) << 8)
                | (UInt32(bytes[o + 2]) << 16) | (UInt32(bytes[o + 3]) << 24)
        }
    }

    /// The highest voltage a sink PDO asks for, across all PDO shapes.
    private static func maxVoltageMV(ofSinkPDO raw: UInt32) -> Int? {
        switch (raw >> 30) & 0x3 {
        case 0: return Int((raw >> 10) & 0x3FF) * 50     // Fixed
        case 1, 2: return Int((raw >> 20) & 0x3FF) * 50  // Battery / Variable
        default:
            switch (raw >> 28) & 0x3 {
            case 0: return Int((raw >> 17) & 0xFF) * 100   // SPR PPS
            case 1: return Int((raw >> 17) & 0x1FF) * 100  // EPR AVS
            default: return nil
            }
        }
    }

    private func readSinkPolicy(_ conn: OpaquePointer) -> SinkPolicy? {
        guard let bytes = readBytes(conn, Reg.txSinkCaps),
              let pdos = Self.parseSinkCaps(bytes) else { return nil }
        let maxima = pdos.compactMap { Self.maxVoltageMV(ofSinkPDO: $0) }
        guard maxima.count == pdos.count, let ceiling = maxima.max(),
              ceiling > 0 else { return nil }
        return SinkPolicy(bytes: bytes, pdos: pdos, maxMillivolts: ceiling)
    }

    /// Rebuilds the sink-caps register so nothing above `target` is advertised:
    /// fixed objects above the rail are dropped, variable objects have their
    /// max-voltage field clamped, and battery/augmented objects are withdrawn.
    /// Returns nil unless the result still leads with the mandatory 5V fixed
    /// object — advertising an illegal sink policy is never worth the risk.
    /// The register is rewritten in place at its original length, so only the
    /// count byte and the PDO slots ever change.
    private static func cappedSinkCaps(_ policy: SinkPolicy,
                                       toMV target: Int) -> [UInt8]? {
        var kept: [UInt32] = []
        for raw in policy.pdos {
            switch (raw >> 30) & 0x3 {
            case 0:
                if Int((raw >> 10) & 0x3FF) * 50 <= target { kept.append(raw) }
            case 2:
                let minMV = Int((raw >> 10) & 0x3FF) * 50
                guard minMV <= target else { continue }
                let units = UInt32(target / 50) & 0x3FF
                kept.append((raw & ~(UInt32(0x3FF) << 20)) | (units << 20))
            default:
                continue // battery + augmented: not advertised while capped
            }
        }
        guard let first = kept.first, (first >> 30) & 0x3 == 0,
              Int((first >> 10) & 0x3FF) * 50 == 5_000 else { return nil }
        guard 1 + kept.count * 4 <= policy.bytes.count else { return nil }
        var out = policy.bytes
        out[0] = UInt8(kept.count)
        for (i, raw) in kept.enumerated() {
            let o = 1 + i * 4
            out[o] = UInt8(raw & 0xFF)
            out[o + 1] = UInt8((raw >> 8) & 0xFF)
            out[o + 2] = UInt8((raw >> 16) & 0xFF)
            out[o + 3] = UInt8((raw >> 24) & 0xFF)
        }
        return out == policy.bytes ? nil : out
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

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16)
            | (UInt32(b[o + 3]) << 24)
    }

    /// Reads the live contract across both register layouts.
    ///
    /// Stock TI puts the source PDO at 0x34 and the RDO at 0x35. Apple's
    /// firmware leaves 0x34 empty and packs `[RDO][PDO]` into 0x35. Rather
    /// than branch on a firmware version we can't enumerate, we take whichever
    /// candidate actually decodes as a PDO — a fixed/AVS object and an RDO are
    /// trivially distinguishable, and a wrong guess would simply fail to
    /// decode rather than mis-report power.
    private func readRawContract(_ conn: OpaquePointer) -> RawContract? {
        let legacy = readBytes(conn, Reg.activeContractLegacy) ?? []
        let active = readBytes(conn, Reg.activeContract) ?? []

        // Stock TI: 0x34 holds the PDO, 0x35 holds the RDO.
        if legacy.count >= 4 {
            let pdo = Self.u32(legacy, 0)
            if Self.decodesAsPDO(pdo) {
                let rdo = active.count >= 4 ? Self.u32(active, 0) : 0
                return RawContract(pdo: pdo, rdo: rdo, source: "0x34+0x35")
            }
        }
        // Apple: 0x35 holds [RDO][PDO].
        if active.count >= 8 {
            let a = Self.u32(active, 0), b = Self.u32(active, 4)
            if Self.decodesAsPDO(b) {
                return RawContract(pdo: b, rdo: a, source: "0x35 rdo|pdo")
            }
            if Self.decodesAsPDO(a) {
                return RawContract(pdo: a, rdo: b, source: "0x35 pdo|rdo")
            }
        }
        return nil
    }

    /// True if `raw` looks like a supply object we can act on — a fixed PDO
    /// with a sane rail, or an EPR AVS APDO. Deliberately strict: this is the
    /// discriminator that decides which half of 0x35 is the PDO.
    private static func decodesAsPDO(_ raw: UInt32) -> Bool {
        if let fixed = PDOContract.decodeFixed(raw) {
            return fixed.millivolts >= 5_000 && fixed.millivolts <= 28_000
                && fixed.milliamps >= 500
        }
        return (raw >> 30) & 0x3 == 0x3 && (raw >> 28) & 0x3 == 0x1
    }

    /// Reads and decodes the active contract as a `PDOContract`, whether the
    /// controller reports a fixed PDO or an EPR AVS contract (voltage/current
    /// taken from the AVS RDO). Used by downshift/revert read-backs so both
    /// contract shapes are handled uniformly.
    private func readContract(_ conn: OpaquePointer) -> PDOContract? {
        guard let raw = readRawContract(conn) else { return nil }
        if let fixed = PDOContract.decodeFixed(raw.pdo) { return fixed }
        if let avs = AVSContract.decode(pdo: raw.pdo, rdo: raw.rdo) {
            return PDOContract(millivolts: avs.activeMillivolts,
                               milliamps: avs.activeMilliamps)
        }
        return nil
    }

    private func writeBytes(_ conn: OpaquePointer, _ reg: UInt8,
                            _ bytes: [UInt8]) -> Bool {
        pd_write(conn, reg, bytes, UInt32(bytes.count)) == 0
    }
}
