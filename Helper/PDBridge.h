//
//  PDBridge.h
//  ChargeGuardHelper
//
//  Stateful C bridge to the AppleHPM IOKit plugin, which fronts the Type-C
//  port controller (a TI CD3217/CD3218 "ACE", a TPS6598x-class part with
//  Apple OTP). This is the same interface AsahiLinux/macvdmtool uses to
//  DFU-restore Macs from a second Mac.
//
//  SAFETY: this bridge exposes register Read/Write and a STRICT WHITELIST of
//  4CC commands. It refuses any command not on the whitelist so a bug can
//  never issue a flash/OTP/patch task — those are the only commands that can
//  permanently brick a port. Everything the whitelist allows is volatile and
//  cleared by a power cycle.
//
//  Requires root (the helper runs as root via launchd).
//

#ifndef PDBridge_h
#define PDBridge_h

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PDConn PDConn;

/// Derives the ACE unlock key from the Mac model type (IOPlatformExpertDevice
/// name, e.g. "J314"). Returns 0 on failure.
uint32_t pd_unlock_key(void);

/// Opens the RID=0 Type-C port controller. Returns NULL if the interface
/// cannot be created (e.g. not root, or resource busy).
PDConn *pd_open(void);

/// Closes the connection, first exiting debug mode if it was entered.
void pd_close(PDConn *conn);

/// Reads up to `maxLen` bytes of a controller register. Returns 0 on success
/// and writes the byte count to *outLen.
int pd_read(PDConn *conn, uint8_t reg, uint8_t *buf, uint32_t maxLen,
            uint32_t *outLen);

/// Writes bytes to a controller register. Returns 0 on success.
int pd_write(PDConn *conn, uint8_t reg, const uint8_t *buf, uint32_t len);

/// Issues a 4CC command with optional argument bytes (written to DATA1/reg 9
/// first, per the TI host-interface handshake). Returns the low nibble of the
/// result register (0 = success) or a negative value on transport failure or
/// if `cmd` is not on the safety whitelist.
///
/// Whitelisted commands ONLY: 'LOCK', 'Gaid', 'DBMa', 'ANeg', 'GSrC'.
int pd_command(PDConn *conn, uint32_t cmd, const uint8_t *args, uint32_t argLen);

/// Convenience 4CC packer: pd_fourcc('A','N','e','g').
uint32_t pd_fourcc(char a, char b, char c, char d);

#ifdef __cplusplus
}
#endif

#endif /* PDBridge_h */
