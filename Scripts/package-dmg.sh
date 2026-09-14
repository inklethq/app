#!/usr/bin/env bash
# Create and sign the disk image that GitHub Releases publishes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${INKLET_VERSION:?INKLET_VERSION is required}"
OUTPUT_DIR="${INKLET_OUTPUT_DIR:-$ROOT_DIR/build}"
DIST_DIR="${INKLET_DIST_DIR:-$ROOT_DIR/dist}"
SIGN_IDENTITY="${INKLET_SIGN_IDENTITY:--}"
APP="$OUTPUT_DIR/inklet Portal.app"
DMG="$DIST_DIR/inklet-portal-$VERSION-mac-universal.dmg"

[[ -d "$APP" ]] || { echo "missing app bundle: $APP" >&2; exit 1; }

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

mkdir -p "$DIST_DIR"
cp -R "$APP" "$STAGING/inklet Portal.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "inklet Portal" -srcfolder "$STAGING" -ov -format UDZO "$DMG"

if [[ "$SIGN_IDENTITY" != "-" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp \
    --identifier com.iminklet.mac.dmg "$DMG"
  codesign --verify --verbose=2 "$DMG"
fi

echo "$DMG"
