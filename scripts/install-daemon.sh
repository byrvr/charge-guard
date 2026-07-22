#!/bin/bash
# Installs the ChargeGuard helper as a classic root LaunchDaemon, bypassing
# SMAppService (whose code-signature checks reject ad-hoc-signed builds).
# Normally invoked by the app's "Install Helper" button, which runs it as root
# behind the native macOS password dialog. Manual use:
#   sudo scripts/install-daemon.sh [APP_PATH]
# APP_PATH is the path to ChargeGuard.app; it defaults to /Applications so a
# copy installed there Just Works, but the in-app button passes the running
# bundle's path so a Debug build in DerivedData installs correctly too.
set -euo pipefail

if [ "$(id -u)" != 0 ]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

APP="${1:-/Applications/ChargeGuard.app}"
SRC="$APP/Contents/MacOS/ChargeGuardHelper"
DEST="/Library/PrivilegedHelperTools/dev.byrvr.ChargeGuard.helper"
LABEL="dev.byrvr.ChargeGuard.daemon"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
MACH="dev.byrvr.ChargeGuard.helper"

[ -x "$SRC" ] || { echo "helper not found at $SRC — is ChargeGuard.app in /Applications?" >&2; exit 1; }

# Stop the failed SMAppService job so it stops hot-looping and can't fight us
# for the Mach service. (Its registration is separately disabled in Login
# Items; this just clears the running attempt.)
launchctl bootout "system/dev.byrvr.ChargeGuard.helper" 2>/dev/null || true
launchctl bootout "system/$LABEL" 2>/dev/null || true

mkdir -p /Library/PrivilegedHelperTools
install -m 755 -o root -g wheel "$SRC" "$DEST"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>Program</key>
    <string>$DEST</string>
    <key>MachServices</key>
    <dict>
        <key>$MACH</key>
        <true/>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/Library/Logs/ChargeGuardHelper.log</string>
    <key>StandardOutPath</key>
    <string>/Library/Logs/ChargeGuardHelper.log</string>
</dict>
</plist>
PLIST_EOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

launchctl bootstrap system "$PLIST"
launchctl kickstart -k "system/$LABEL" 2>/dev/null || true

sleep 1
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
  echo "ChargeGuard helper installed and running."
  echo "  Log: /Library/Logs/ChargeGuardHelper.log"
  echo "  Open ChargeGuard from the menu bar — it should now show live stats."
else
  echo "Bootstrap did not report the job; check: sudo launchctl print system/$LABEL" >&2
  exit 1
fi
