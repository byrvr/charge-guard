//
//  main.swift
//  ChargeGuardHelper
//
//  Entry point of the privileged daemon. Registered by the app via
//  SMAppService; launchd starts it on demand and keeps it alive.
//

import Foundation
import SystemConfiguration

final class XPCDelegate: NSObject, NSXPCListenerDelegate, ChargeGuardXPC {
    private let engine: GuardEngine

    init(engine: GuardEngine) {
        self.engine = engine
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // This daemon runs as root; do not let arbitrary local users drive
        // it. Accept root and the current console (logged-in) user only.
        // NOTE for signed/distributed builds: additionally pin the client
        // with setCodeSigningRequirement(_:) — ad-hoc dev builds have no
        // stable identity to pin, so the UID check is the baseline here.
        let peer = connection.effectiveUserIdentifier
        if peer != 0, peer != Self.consoleUserUID() {
            NSLog("[ChargeGuard] rejecting XPC connection from uid %d", peer)
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: ChargeGuardXPC.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    private static func consoleUserUID() -> uid_t {
        var uid: uid_t = 0
        var gid: gid_t = 0
        if SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) != nil {
            return uid
        }
        return uid_t.max
    }

    // MARK: - ChargeGuardXPC

    func status(reply: @escaping (Data?) -> Void) {
        reply(try? JSONEncoder().encode(engine.currentStatus()))
    }

    func events(limit: Int, reply: @escaping (Data?) -> Void) {
        reply(try? JSONEncoder().encode(engine.recentEvents(limit: limit)))
    }

    func config(reply: @escaping (Data?) -> Void) {
        reply(try? JSONEncoder().encode(engine.currentConfig()))
    }

    func setConfig(_ data: Data, reply: @escaping (Bool) -> Void) {
        guard let cfg = try? JSONDecoder().decode(GuardConfig.self, from: data)
        else {
            reply(false)
            return
        }
        engine.applyConfig(cfg)
        reply(true)
    }

    func forceCharging(reply: @escaping (Bool) -> Void) {
        engine.forceChargingOn()
        reply(true)
    }
}

// MARK: - Bootstrap

guard let smc = try? SMCService() else {
    NSLog("[ChargeGuard] fatal: cannot open AppleSMC — exiting")
    exit(1)
}

let engine = GuardEngine(smc: smc, monitor: PowerMonitor())
let delegate = XPCDelegate(engine: engine)
let listener = NSXPCListener(machServiceName: ChargeGuardIDs.helperMachService)
listener.delegate = delegate
listener.resume()

// launchd sends SIGTERM on SMAppService unregister, daemon disable, and
// helper upgrades. Restore charging and the Low Power Mode baseline before
// dying — the port of the shell prototype's `trap cleanup TERM INT`.
// SIG_IGN is required so the default disposition doesn't kill the process
// before the dispatch source fires.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let signalSources: [DispatchSourceSignal] = [SIGTERM, SIGINT].map { sig in
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        engine.shutdown()
        exit(0)
    }
    source.resume()
    return source
}

NSLog("[ChargeGuard] helper started (v%@)", HelperVersion.current)
RunLoop.main.run()
