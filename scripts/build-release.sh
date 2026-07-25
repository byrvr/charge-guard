#!/bin/bash
# Builds a Release ChargeGuard.app and packages it as a versioned zip in dist/.
# Usage: scripts/build-release.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
# Shared/Version.swift is the single source of truth — both binaries compile
# it, and this pushes the same string into the app bundle's Info.plist.
"$ROOT/scripts/sync-version.sh"
VERSION=$(/usr/bin/sed -n 's/.*static let current = "\([^"]*\)".*/\1/p' \
  Shared/Version.swift)
DIST="$ROOT/dist"

command -v xcodegen >/dev/null || { echo "install xcodegen: brew install xcodegen" >&2; exit 1; }

echo "Generating project…"
xcodegen generate >/dev/null

echo "Building ChargeGuard $VERSION (Release)…"
DERIVED="$ROOT/.build-release"
xcodebuild -project ChargeGuard.xcodeproj -scheme ChargeGuard \
  -configuration Release -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" build >/dev/null

APP="$DERIVED/Build/Products/Release/ChargeGuard.app"
[ -d "$APP" ] || { echo "build produced no app" >&2; exit 1; }

mkdir -p "$DIST"
ZIP="$DIST/ChargeGuard-$VERSION.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "Packaged: $ZIP"
/usr/bin/shasum -a 256 "$ZIP" | tee "$DIST/ChargeGuard-$VERSION.zip.sha256"
