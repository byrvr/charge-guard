//
//  SMCService.swift
//  ChargeGuardHelper
//
//  Typed access to the few SMC keys ChargeGuard uses. Writes are
//  deliberately restricted to CHTE (charge inhibit) — the only writable
//  charging lever on modern Apple Silicon firmware.
//

import Foundation

enum SMCError: Error, CustomStringConvertible {
    case openFailed
    case ioKitFailure
    case smcStatus(UInt8)
    case unexpectedLayout(key: String)
    case writeDidNotStick(key: String)

    var description: String {
        switch self {
        case .openFailed: return "could not open AppleSMC service"
        case .ioKitFailure: return "IOKit call failed"
        case .smcStatus(let s):
            return String(format: "SMC status 0x%02X%@", s,
                          s == 0x84 ? " (key not found)" :
                          s == 0x86 ? " (key not writable)" : "")
        case .unexpectedLayout(let key):
            return "unexpected layout for key \(key); refusing"
        case .writeDidNotStick(let key):
            return "write to \(key) did not take effect"
        }
    }
}

final class SMCService {
    private var conn: io_connect_t = 0

    init() throws {
        guard smc_open(&conn) == KERN_SUCCESS else { throw SMCError.openFailed }
    }

    deinit { smc_close(conn) }

    private func read(_ key: String) throws -> (bytes: [UInt8], type: UInt32) {
        var buf = [UInt8](repeating: 0, count: 32)
        var size: UInt32 = 0
        var type: UInt32 = 0
        let rc = smc_read_key(conn, key, &buf, &size, &type)
        if rc == -1 { throw SMCError.ioKitFailure }
        if rc != 0 { throw SMCError.smcStatus(UInt8(rc)) }
        return (Array(buf.prefix(Int(size))), type)
    }

    private static func littleEndianValue(_ bytes: [UInt8]) -> Int64 {
        var v: Int64 = 0
        for b in bytes.reversed() { v = (v << 8) | Int64(b) }
        return v
    }

    private static let ui32FourCC: UInt32 = {
        var v: UInt32 = 0
        for c in "ui32".utf8 { v = (v << 8) | UInt32(c) }
        return v
    }()

    // MARK: - Charge inhibit (CHTE)

    /// Whether battery charging is currently inhibited.
    func isChargingInhibited() throws -> Bool {
        let r = try read("CHTE")
        return Self.littleEndianValue(r.bytes) != 0
    }

    /// Inhibits or re-enables battery charging. Root required.
    /// Verifies the key layout before writing and reads back after.
    func setChargingInhibited(_ inhibited: Bool) throws {
        let r = try read("CHTE")
        guard r.bytes.count == 4, r.type == Self.ui32FourCC else {
            throw SMCError.unexpectedLayout(key: "CHTE")
        }
        let value: [UInt8] = inhibited ? [0x01, 0, 0, 0] : [0, 0, 0, 0]
        let rc = smc_write_key(conn, "CHTE", value, 4)
        if rc == -1 { throw SMCError.ioKitFailure }
        if rc != 0 { throw SMCError.smcStatus(UInt8(rc)) }
        // The read-back is authoritative: a write the kernel accepted but
        // firmware ignored must surface as an error.
        guard try isChargingInhibited() == inhibited else {
            throw SMCError.writeDidNotStick(key: "CHTE")
        }
    }

    // MARK: - Telemetry (read-only)

    /// Negotiated adapter power budget in watts (ACPW is mW), 0 when unplugged.
    func adapterWatts() -> Double {
        guard let r = try? read("ACPW") else { return 0 }
        return Double(Self.littleEndianValue(r.bytes)) / 1000.0
    }

    /// Battery charge current in mA (CHBI), 0 when not charging.
    func chargeCurrentMA() -> Int {
        guard let r = try? read("CHBI") else { return 0 }
        return Int(Self.littleEndianValue(r.bytes))
    }
}
