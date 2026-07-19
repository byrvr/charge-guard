//
//  XPCProtocol.swift
//  ChargeGuard
//
//  The XPC surface between the menu bar app and the privileged helper.
//  Payloads are JSON-encoded shared model types, so the @objc protocol
//  only ever carries Foundation types.
//

import Foundation

@objc public protocol ChargeGuardXPC {
    /// Returns a JSON-encoded `GuardStatus`.
    func status(reply: @escaping (Data?) -> Void)

    /// Returns a JSON-encoded `[GuardEvent]`, most recent last.
    func events(limit: Int, reply: @escaping (Data?) -> Void)

    /// Returns a JSON-encoded `GuardConfig`.
    func config(reply: @escaping (Data?) -> Void)

    /// Applies a JSON-encoded `GuardConfig`.
    func setConfig(_ data: Data, reply: @escaping (Bool) -> Void)

    /// Manually lift the guard and re-enable charging (the guard re-engages
    /// if the charger flaps again).
    func forceCharging(reply: @escaping (Bool) -> Void)

    /// Runs the READ-ONLY PD-controller probe and returns a human-readable
    /// summary. This is the safe first step before enabling PD downshift:
    /// it confirms whether this machine's Type-C controller uses the
    /// standard register layout the downshift relies on.
    func probePDController(reply: @escaping (String) -> Void)
}
