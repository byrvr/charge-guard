#!/bin/bash
# Removes the classic ChargeGuard helper LaunchDaemon.
# Run with: sudo scripts/uninstall-daemon.sh
set -euo pipefail

if [ "$(id -u)" != 0 ]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

LABEL="dev.byrvr.ChargeGuard.daemon"
DEST="/Library/PrivilegedHelperTools/dev.byrvr.ChargeGuard.helper"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

# Ensure charging is re-enabled before removing (the daemon does this on
# SIGTERM, which bootout delivers).
launchctl bootout "system/$LABEL" 2>/dev/null || true
rm -f "$PLIST" "$DEST"
echo "ChargeGuard helper removed."
