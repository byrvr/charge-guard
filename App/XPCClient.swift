//
//  XPCClient.swift
//  ChargeGuard
//
//  Thin async wrapper over the NSXPCConnection to the helper.
//
//  XPC invokes exactly one of {reply block, error handler} per message, so
//  every call funnels through `call(_:_:)`, which resumes its continuation
//  from whichever fires — a failed message returns the fallback instead of
//  leaking the continuation and hanging the caller forever.
//

import Foundation

final class XPCClient {
    private var connection: NSXPCConnection?

    private func ensureConnection() -> NSXPCConnection {
        if let c = connection { return c }
        let c = NSXPCConnection(
            machServiceName: ChargeGuardIDs.helperMachService,
            options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: ChargeGuardXPC.self)
        c.invalidationHandler = { [weak self, weak c] in
            // Only clear the slot if the dying connection is still current —
            // a stale handler must not tear down a healthy replacement.
            if let self, let c, self.connection === c { self.connection = nil }
        }
        c.interruptionHandler = { [weak self, weak c] in
            if let self, let c, self.connection === c {
                c.invalidate()
                self.connection = nil
            }
        }
        c.resume()
        connection = c
        return c
    }

    /// Resumes a continuation at most once, from either the XPC reply or
    /// the per-call error handler.
    private final class ResumeOnce<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?

        init(_ continuation: CheckedContinuation<T, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: T) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }

    private func call<T>(
        fallback: T,
        _ body: @escaping (ChargeGuardXPC, @escaping (T) -> Void) -> Void
    ) async -> T {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = ensureConnection().remoteObjectProxyWithErrorHandler {
                _ in once.resume(fallback)
            }
            guard let p = proxy as? ChargeGuardXPC else {
                once.resume(fallback)
                return
            }
            body(p) { once.resume($0) }
        }
    }

    // MARK: - API

    func fetchStatus() async -> GuardStatus? {
        await call(fallback: nil) { p, reply in
            p.status { data in
                reply(data.flatMap {
                    try? JSONDecoder().decode(GuardStatus.self, from: $0)
                })
            }
        }
    }

    func fetchEvents(limit: Int = 50) async -> [GuardEvent] {
        await call(fallback: []) { p, reply in
            p.events(limit: limit) { data in
                reply(data.flatMap {
                    try? JSONDecoder().decode([GuardEvent].self, from: $0)
                } ?? [])
            }
        }
    }

    func fetchConfig() async -> GuardConfig? {
        await call(fallback: nil) { p, reply in
            p.config { data in
                reply(data.flatMap {
                    try? JSONDecoder().decode(GuardConfig.self, from: $0)
                })
            }
        }
    }

    @discardableResult
    func push(config: GuardConfig) async -> Bool {
        guard let data = try? JSONEncoder().encode(config) else { return false }
        return await call(fallback: false) { p, reply in
            p.setConfig(data) { reply($0) }
        }
    }

    @discardableResult
    func forceCharging() async -> Bool {
        await call(fallback: false) { p, reply in
            p.forceCharging { reply($0) }
        }
    }

    func probePDController() async -> String {
        await call(fallback: "helper unreachable") { p, reply in
            p.probePDController { reply($0) }
        }
    }

    func selfTestPDDownshift() async -> String {
        await call(fallback: "helper unreachable") { p, reply in
            p.selfTestPDDownshift { reply($0) }
        }
    }
}
