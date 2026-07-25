#!/bin/bash
# Stamps the version from Shared/Version.swift into project.yml so the app
# bundle's CFBundleShortVersionString and the helper's reported version can
# never drift apart. Run automatically by build-release.sh.
#
# Usage: scripts/sync-version.sh [--check]
#   --check  exit non-zero if project.yml is out of date instead of fixing it
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="Shared/Version.swift"
VERSION=$(/usr/bin/sed -n 's/.*static let current = "\([^"]*\)".*/\1/p' "$SRC")
[ -n "$VERSION" ] || { echo "no version found in $SRC" >&2; exit 1; }

CURRENT=$(/usr/bin/awk -F'"' '/CFBundleShortVersionString/{print $2; exit}' \
  project.yml)

if [ "$CURRENT" = "$VERSION" ]; then
  echo "version $VERSION (project.yml in sync)"
  exit 0
fi

if [ "${1:-}" = "--check" ]; then
  echo "project.yml says $CURRENT but $SRC says $VERSION — run $0" >&2
  exit 1
fi

/usr/bin/sed -i '' \
  "s/CFBundleShortVersionString: \".*\"/CFBundleShortVersionString: \"$VERSION\"/" \
  project.yml
echo "version $VERSION (project.yml updated from $CURRENT)"
