//
//  SMCBridge.h
//  ChargeGuard
//
//  Minimal C bridge to the AppleSMC IOKit user client. The struct layout is
//  the canonical interface shared by smcFanControl, smctemp, iStats and
//  virtually every other open-source SMC tool.
//

#ifndef SMCBridge_h
#define SMCBridge_h

#include <stdint.h>
#include <IOKit/IOKitLib.h>

#ifdef __cplusplus
extern "C" {
#endif

/// SMC status byte for "key not found".
#define SMC_RESULT_KEY_NOT_FOUND 0x84
/// SMC status byte for "key is not writable".
#define SMC_RESULT_NOT_WRITABLE 0x86

/// Opens a connection to the AppleSMC service.
/// Returns KERN_SUCCESS and sets *conn on success.
kern_return_t smc_open(io_connect_t *conn);

/// Closes a connection previously opened with smc_open.
void smc_close(io_connect_t conn);

/// Reads an SMC key (4-character name, not NUL-terminated).
/// On success fills buf (up to 32 bytes), *size, and *type (FourCC).
/// Returns 0 on success, a positive SMC status byte (e.g. 0x84) when the
/// SMC rejected the request, or -1 for IOKit-level failures.
int smc_read_key(io_connect_t conn, const char *key, uint8_t buf[32],
                 uint32_t *size, uint32_t *type);

/// Writes an SMC key. Requires root for protected keys.
/// Returns 0 on success, a positive SMC status byte when the SMC rejected
/// the write (0x86 = read-only key), or -1 for IOKit-level failures.
int smc_write_key(io_connect_t conn, const char *key, const uint8_t *buf,
                  uint32_t size);

#ifdef __cplusplus
}
#endif

#endif /* SMCBridge_h */
