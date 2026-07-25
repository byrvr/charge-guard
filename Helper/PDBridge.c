//
//  PDBridge.c
//  ChargeGuardHelper
//

#include "PDBridge.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>

// AppleHPM plugin type/interface UUIDs (from osy86's reverse engineering,
// used by macvdmtool).
#define kAppleHPMLibTypeUUID                                                   \
    CFUUIDGetConstantUUIDWithBytes(kCFAllocatorDefault, 0x12, 0xA1, 0xDC,      \
                                   0xCF, 0xCF, 0x7A, 0x47, 0x75, 0xBE, 0xE5,   \
                                   0x9C, 0x43, 0x19, 0xF4, 0xCD, 0x2B)
#define kAppleHPMLibInterfaceUUID                                             \
    CFUUIDGetConstantUUIDWithBytes(kCFAllocatorDefault, 0xC1, 0x3A, 0xCD,      \
                                   0xD9, 0x20, 0x9E, 0x4B, 0x01, 0xB7, 0xBE,   \
                                   0xE0, 0x5C, 0xD8, 0x83, 0xC7, 0xB1)

typedef struct {
    IUNKNOWN_C_GUTS;
    uint16_t field_20;
    uint16_t field_22;
    IOReturn (*Read)(void *, uint64_t chipAddr, uint8_t dataAddr, void *buffer,
                     uint64_t maxLen, uint32_t flags, uint64_t *readLen);
    IOReturn (*Write)(void *, uint64_t chipAddr, uint8_t dataAddr,
                      const void *buffer, uint64_t len, uint32_t flags);
    IOReturn (*Command)(void *, uint64_t chipAddr, uint32_t cmd, uint32_t flags);
    IOReturn (*reserved0)(void);
    IOReturn (*reserved1)(void);
    IOReturn (*reserved2)(void);
} AppleHPMLib;

struct PDConn {
    IOCFPlugInInterface **plugin;
    AppleHPMLib **device;
    bool inDebugMode;
};

// The DATA1 register carries 4CC arguments and results, per the TI
// TPS6598x host interface.
enum { kDATA1Register = 9 };

uint32_t pd_fourcc(char a, char b, char c, char d) {
    return ((uint32_t)(uint8_t)a << 24) | ((uint32_t)(uint8_t)b << 16) |
           ((uint32_t)(uint8_t)c << 8) | (uint32_t)(uint8_t)d;
}

// Only these registers may be written. They are volatile RAM policy
// registers. The command registers CMD1=0x08 and CMD2=0x10 are deliberately
// excluded: the ONLY sanctioned way to run a 4CC is pd_command()'s
// command_allowed() whitelist. This makes "a bug can never issue a
// flash/OTP/patch task" a structural guarantee, not a hope — a mis-computed
// register can never reach the controller's command engine through pd_write.
static bool write_reg_allowed(uint8_t reg) {
    switch (reg) {
        case 0x33: // Tx Sink Capabilities (volatile)
            return true;
        default:
            return false;
    }
}

// Only these commands may ever be issued. LOCK/Gaid/DBMa gate access;
// ANeg/GSrC trigger a volatile PD renegotiation. None writes flash/OTP.
static bool command_allowed(uint32_t cmd) {
    static const uint32_t whitelist[] = {
        0x4C4F434B, // 'LOCK' unlock the ACE
        0x47616964, // 'Gaid' soft reset (unlock recovery)
        0x44424D61, // 'DBMa' enter/exit debug mode
        0x414E6567, // 'ANeg' re-evaluate autonegotiate-sink -> renegotiate
        0x47537243, // 'GSrC' get source caps -> renegotiate
    };
    for (size_t i = 0; i < sizeof(whitelist) / sizeof(whitelist[0]); i++) {
        if (whitelist[i] == cmd) return true;
    }
    return false;
}

uint32_t pd_unlock_key(void) {
    io_service_t svc = IOServiceGetMatchingService(
        kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"));
    if (!svc) return 0;
    io_name_t name;
    kern_return_t kr = IORegistryEntryGetName(svc, name);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS) return 0;
    return ((uint32_t)(uint8_t)name[0] << 24) |
           ((uint32_t)(uint8_t)name[1] << 16) |
           ((uint32_t)(uint8_t)name[2] << 8) | (uint32_t)(uint8_t)name[3];
}

PDConn *pd_open(void) {
    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                     IOServiceMatching("AppleHPM"),
                                     &iter) != KERN_SUCCESS) {
        return NULL;
    }

    PDConn *conn = NULL;
    io_service_t service;
    while ((service = IOIteratorNext(iter))) {
        CFNumberRef ridRef = (CFNumberRef)IORegistryEntryCreateCFProperty(
            service, CFSTR("RID"), kCFAllocatorDefault, 0);
        int32_t rid = -1;
        if (ridRef) {
            CFNumberGetValue(ridRef, kCFNumberSInt32Type, &rid);
            CFRelease(ridRef);
        }
        if (rid != 0) {
            IOObjectRelease(service);
            continue;
        }

        IOCFPlugInInterface **plugin = NULL;
        SInt32 score = 0;
        IOReturn ret = IOCreatePlugInInterfaceForService(
            service, kAppleHPMLibTypeUUID, kIOCFPlugInInterfaceID, &plugin,
            &score);
        IOObjectRelease(service);
        if (ret != kIOReturnSuccess || !plugin) {
            continue;
        }

        AppleHPMLib **device = NULL;
        HRESULT res = (*plugin)->QueryInterface(
            plugin, CFUUIDGetUUIDBytes(kAppleHPMLibInterfaceUUID),
            (LPVOID *)&device);
        if (res != S_OK || !device) {
            IODestroyPlugInInterface(plugin);
            continue;
        }

        conn = calloc(1, sizeof(PDConn));
        if (!conn) {
            // `service` was already released above, after the plugin was
            // created; release only the interfaces we still hold.
            (*device)->Release(device);
            IODestroyPlugInInterface(plugin);
            break;
        }
        conn->plugin = plugin;
        conn->device = device;
        conn->inDebugMode = false;
        break;
    }
    IOObjectRelease(iter);
    return conn;
}

int pd_read(PDConn *conn, uint8_t reg, uint8_t *buf, uint32_t maxLen,
            uint32_t *outLen) {
    if (!conn) return -1;
    uint64_t rlen = 0;
    IOReturn x = (*conn->device)->Read(conn->device, 0, reg, buf, maxLen, 0,
                                       &rlen);
    if (x != kIOReturnSuccess) return -1;
    if (outLen) *outLen = (uint32_t)rlen;
    return 0;
}

int pd_write(PDConn *conn, uint8_t reg, const uint8_t *buf, uint32_t len) {
    if (!conn) return -1;
    if (!write_reg_allowed(reg)) return -2; // never a command register
    IOReturn x = (*conn->device)->Write(conn->device, 0, reg, buf, len, 0);
    return (x == kIOReturnSuccess) ? 0 : -1;
}

int pd_command(PDConn *conn, uint32_t cmd, const uint8_t *args,
               uint32_t argLen) {
    if (!conn) return -1;
    if (!command_allowed(cmd)) return -2; // refuse anything off-whitelist

    if (args && argLen) {
        if ((*conn->device)->Write(conn->device, 0, kDATA1Register, args,
                                   argLen, 0) != kIOReturnSuccess) {
            return -1;
        }
    }
    if ((*conn->device)->Command(conn->device, 0, cmd, 0) != kIOReturnSuccess) {
        return -1;
    }
    if (cmd == 0x44424D61) { // track DBMa enter/exit for clean teardown
        conn->inDebugMode = (args && argLen && args[0] != 0);
    }
    // Read into a full 64-byte buffer like the reference (macvdmtool). DATA1
    // can be up to 64 bytes wide; a smaller buffer would rely on Read()
    // honoring maxLen, which the reference never depends on.
    uint8_t result[64];
    uint64_t rlen = 0;
    if ((*conn->device)->Read(conn->device, 0, kDATA1Register, result,
                              sizeof(result), 0, &rlen) != kIOReturnSuccess) {
        return -1;
    }
    return result[0] & 0x0F;
}

void pd_close(PDConn *conn) {
    if (!conn) return;
    if (conn->inDebugMode) {
        // Exit debug mode so the port returns to normal operation. Retry
        // once; a stuck debug mode disrupts the port until reboot.
        uint8_t off = 0x00;
        int r = pd_command(conn, 0x44424D61, &off, 1);
        if (r != 0) {
            r = pd_command(conn, 0x44424D61, &off, 1);
        }
        if (r != 0) {
            fprintf(stderr, "[ChargeGuard] pd_close: failed to exit debug "
                            "mode (r=%d); a reboot will clear it\n", r);
        }
    }
    if (conn->device) {
        (*conn->device)->Release(conn->device);
    }
    if (conn->plugin) {
        IODestroyPlugInInterface(conn->plugin);
    }
    free(conn);
}
