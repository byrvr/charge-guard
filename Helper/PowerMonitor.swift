//
//  PowerMonitor.swift
//  ChargeGuardHelper
//
//  Observes power-source changes (AC attach/detach) via IOPSNotification
//  and system sleep/wake via IORegisterForSystemPower, and reports battery
//  state. Replaces the `pmset -g pslog` text-parsing of the shell
//  prototype with proper IOKit callbacks.
//

import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

// IOMessage.h defines these via the iokit_common_msg() macro, which does
// not import into Swift: sys_iokit | sub_iokit_common | code.
private let kMsgSystemWillSleep: UInt32 = 0xE000_0280
private let kMsgCanSystemSleep: UInt32 = 0xE000_0270
private let kMsgSystemHasPoweredOn: UInt32 = 0xE000_0300

struct PowerSnapshot {
    var isOnAC: Bool = false
    var batteryPercent: Int = 0
    var isCharging: Bool = false
}

final class PowerMonitor {
    var onPowerSourceChange: ((PowerSnapshot) -> Void)?
    var onWake: (() -> Void)?

    private var runLoopSource: CFRunLoopSource?
    private var rootPort: io_connect_t = 0
    private var notifierPort: IONotificationPortRef?
    private var notifierObject: io_object_t = 0

    func start() {
        // Power-source (AC/battery) change notifications.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue()
            monitor.onPowerSourceChange?(PowerMonitor.snapshot())
        }, context)?.takeRetainedValue() {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        // Sleep/wake notifications: slept time must not count toward probes.
        var port: IONotificationPortRef?
        rootPort = IORegisterForSystemPower(context, &port, { ctx, _, messageType, messageArgument in
            guard let ctx else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue()
            switch messageType {
            case kMsgSystemHasPoweredOn:
                monitor.onWake?()
            case kMsgSystemWillSleep, kMsgCanSystemSleep:
                // Always allow sleep promptly, acknowledging with the
                // notification id carried in the callback argument.
                IOAllowPowerChange(monitor.rootPort,
                                   Int(bitPattern: messageArgument))
            default:
                break
            }
        }, &notifierObject)
        if let port {
            notifierPort = port
            IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        }
    }

    static func snapshot() -> PowerSnapshot {
        var snap = PowerSnapshot()
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue()
                as? [CFTypeRef] else {
            return snap
        }
        if let providing = IOPSGetProvidingPowerSourceType(blob)?
            .takeUnretainedValue() as String? {
            snap.isOnAC = (providing == kIOPMACPowerKey)
        }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if let type = desc[kIOPSTypeKey] as? String,
               type == kIOPSInternalBatteryType {
                if let cur = desc[kIOPSCurrentCapacityKey] as? Int,
                   let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    snap.batteryPercent = cur * 100 / max
                }
                snap.isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
            }
        }
        return snap
    }
}
