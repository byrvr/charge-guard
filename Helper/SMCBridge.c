//
//  SMCBridge.c
//  ChargeGuard
//

#include "SMCBridge.h"
#include <string.h>

enum {
    kSMCKernelIndex = 2,
    kSMCCmdReadBytes = 5,
    kSMCCmdWriteBytes = 6,
    kSMCCmdReadKeyInfo = 9,
};

typedef struct {
    char major;
    char minor;
    char build;
    char reserved[1];
    uint16_t release;
} SMCVers;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCPLimit;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    char dataAttributes;
} SMCKeyInfo;

typedef struct {
    uint32_t key;
    SMCVers vers;
    SMCPLimit pLimitData;
    SMCKeyInfo keyInfo;
    char result;
    char status;
    char data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

static uint32_t key_from_str(const char *s) {
    return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] << 8) | (uint32_t)(uint8_t)s[3];
}

kern_return_t smc_open(io_connect_t *conn) {
    io_service_t svc = IOServiceGetMatchingService(
        kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) {
        return KERN_FAILURE;
    }
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, conn);
    IOObjectRelease(svc);
    return kr;
}

void smc_close(io_connect_t conn) {
    if (conn) {
        IOServiceClose(conn);
    }
}

static kern_return_t smc_call(io_connect_t conn, SMCKeyData *in,
                              SMCKeyData *out) {
    size_t outSize = sizeof(SMCKeyData);
    return IOConnectCallStructMethod(conn, kSMCKernelIndex, in,
                                     sizeof(SMCKeyData), out, &outSize);
}

int smc_read_key(io_connect_t conn, const char *key, uint8_t buf[32],
                 uint32_t *size, uint32_t *type) {
    SMCKeyData in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = key_from_str(key);
    in.data8 = kSMCCmdReadKeyInfo;
    kern_return_t kr = smc_call(conn, &in, &out);
    if (kr != KERN_SUCCESS) {
        return -1;
    }
    if (out.result != 0) {
        return (uint8_t)out.result;
    }
    uint32_t dataSize = out.keyInfo.dataSize;
    if (dataSize == 0 || dataSize > 32) {
        return -1;
    }
    *size = dataSize;
    *type = out.keyInfo.dataType;

    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = key_from_str(key);
    in.keyInfo.dataSize = dataSize;
    in.data8 = kSMCCmdReadBytes;
    kr = smc_call(conn, &in, &out);
    if (kr != KERN_SUCCESS) {
        return -1;
    }
    if (out.result != 0) {
        return (uint8_t)out.result;
    }
    memcpy(buf, out.bytes, dataSize);
    return 0;
}

int smc_write_key(io_connect_t conn, const char *key, const uint8_t *buf,
                  uint32_t size) {
    if (size == 0 || size > 32) {
        return -1;
    }
    SMCKeyData in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = key_from_str(key);
    in.keyInfo.dataSize = size;
    in.data8 = kSMCCmdWriteBytes;
    memcpy(in.bytes, buf, size);
    kern_return_t kr = smc_call(conn, &in, &out);
    if (kr != KERN_SUCCESS) {
        return -1;
    }
    if (out.result != 0) {
        return (uint8_t)out.result;
    }
    return 0;
}
