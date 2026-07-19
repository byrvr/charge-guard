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
}
