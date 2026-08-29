#!/usr/bin/env bash
# Build the native SwiftUI client and wrap it in a distributable .app bundle.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIGURATION="${1:-debug}"
VERSION="${INKLET_VERSION:-0.1.0}"
BUILD_NUMBER="${INKLET_BUILD_NUMBER:-1}"
OUTPUT_DIR="${INKLET_OUTPUT_DIR:-$ROOT_DIR/build}"
ARCHS="${INKLET_ARCHS:-}"
SIGN_IDENTITY="${INKLET_SIGN_IDENTITY:--}"
INSTALL_AFTER_BUILD="${INKLET_INSTALL:-0}"

cd "$ROOT_DIR"

SWIFT_ARGS=(-c "$CONFIGURATION")
if [[ -n "$ARCHS" ]]; then
  IFS=',' read -r -a ARCH_LIST <<< "$ARCHS"
  for arch in "${ARCH_LIST[@]}"; do
    SWIFT_ARGS+=(--arch "$arch")
  done
fi

if [[ "${INKLET_RELEASE:-0}" == "1" ]]; then
  xcrun swift build "${SWIFT_ARGS[@]}" -Xswiftc -DINKLET_RELEASE
else
  xcrun swift build "${SWIFT_ARGS[@]}"
fi
BIN_PATH="$(xcrun swift build "${SWIFT_ARGS[@]}" --show-bin-path)"

APP="$OUTPUT_DIR/inklet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/InkletMac" "$APP/Contents/MacOS/inklet"

# SwiftPM puts processed resources in a sibling bundle. Flatten them into the
# app bundle so Bundle.main resolves them after the build directory is gone.
RESOURCE_BUNDLE="$BIN_PATH/InkletMac_InkletMac.bundle"
if [[ -d "$RESOURCE_BUNDLE/Contents/Resources" ]]; then
  cp -R "$RESOURCE_BUNDLE/Contents/Resources/." "$APP/Contents/Resources/"
else
  cp -R "$RESOURCE_BUNDLE/." "$APP/Contents/Resources/"
fi

# Reuse the product's 1024px source icon and let iconutil create the native
# bundle icon. The temporary iconset never enters the artifact.
ICON_SOURCE="${INKLET_ICON_SOURCE:-$ROOT_DIR/../resources/icon.png}"
if [[ -f "$ICON_SOURCE" ]]; then
  ICONSET="$(mktemp -d)/inklet.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/inklet.icns"
  rm -rf "$(dirname "$ICONSET")"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>inklet</string>
  <key>CFBundleDisplayName</key><string>inklet</string>
  <key>CFBundleExecutable</key><string>inklet</string>
  <key>CFBundleIdentifier</key><string>com.iminklet.mac</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>inklet.icns</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>inklet reads what you're looking at — a browser's address, a Finder selection, or the photo you have open — so the composer can offer it when you summon it.</string>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key>
      <dict><key>default</key><string>Send to inklet</string></dict>
      <key>NSMessage</key><string>sendToInklet</string>
      <key>NSPortName</key><string>inklet</string>
      <key>NSSendTypes</key>
      <array>
        <string>public.utf8-plain-text</string>
        <string>public.file-url</string>
        <string>public.url</string>
        <string>public.image</string>
      </array>
    </dict>
  </array>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><true/>
</dict>
</plist>
PLIST

ENTITLEMENTS="$ROOT_DIR/Resources/InkletMac.entitlements"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
else
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

if [[ "$INSTALL_AFTER_BUILD" == "1" ]]; then
  INSTALLED="$HOME/Applications/inklet.app"
  mkdir -p "$HOME/Applications"
  rm -rf "$INSTALLED"
  cp -R "$APP" "$INSTALLED"
  echo "installed $INSTALLED"
fi

echo "built $APP"
