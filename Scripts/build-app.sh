#!/usr/bin/env bash
# Build the native SwiftUI client and wrap it in a distributable .app bundle.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIGURATION="${1:-debug}"
VERSION="${INKLET_VERSION:-0.2.0}"
BUILD_NUMBER="${INKLET_BUILD_NUMBER:-1}"
OUTPUT_DIR="${INKLET_OUTPUT_DIR:-$ROOT_DIR/build}"
ARCHS="${INKLET_ARCHS:-}"
SIGN_IDENTITY="${INKLET_SIGN_IDENTITY:--}"
INSTALL_AFTER_BUILD="${INKLET_INSTALL:-0}"
# Sparkle: the feed is committed to the `appcast` branch by the release
# workflow; the public key pairs with the SPARKLE_PRIVATE_KEY repository
# secret (private half lives in the release manager's login Keychain).
SPARKLE_FEED_URL="${INKLET_SPARKLE_FEED_URL:-https://raw.githubusercontent.com/inklethq/app/appcast/appcast.xml}"
SPARKLE_PUBLIC_KEY="${INKLET_SPARKLE_PUBLIC_KEY:-V8ABE8pxqFcEA8x5OycPwX+42/hPESXcBaReS2HXEPA=}"
source "$SCRIPT_DIR/widget-configuration.sh"
inklet_configure_widget_group

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

cd "$ROOT_DIR"

SWIFT_ARGS=(-c "$CONFIGURATION" --product InkletMac)
if [[ -n "${INKLET_SWIFT_SCRATCH_PATH:-}" ]]; then
  SWIFT_ARGS+=(--scratch-path "$INKLET_SWIFT_SCRATCH_PATH")
fi
if [[ "${INKLET_DISABLE_BUILD_SANDBOX:-0}" == "1" ]]; then
  SWIFT_ARGS+=(--disable-sandbox)
fi
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

APP="$OUTPUT_DIR/inklet Portal.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/InkletMac" "$APP/Contents/MacOS/inklet"

# SwiftPM drops the Sparkle binary artifact next to the executable; the app
# links it via @executable_path/../Frameworks (see Package.swift).
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
cp -R "$BIN_PATH/Sparkle.framework" "$SPARKLE"

# SwiftPM puts processed resources in a sibling bundle. Flatten them into the
# app bundle so Bundle.main resolves them after the build directory is gone.
RESOURCE_BUNDLE="$BIN_PATH/InkletMac_InkletMac.bundle"
if [[ -d "$RESOURCE_BUNDLE/Contents/Resources" ]]; then
  cp -R "$RESOURCE_BUNDLE/Contents/Resources/." "$APP/Contents/Resources/"
else
  cp -R "$RESOURCE_BUNDLE/." "$APP/Contents/Resources/"
fi

# The app also previews its Virtual Display using the Widget's shared views.
WIDGET_RESOURCES="$BIN_PATH/InkletMac_InkletPresentationWidget.bundle"
if [[ -d "$WIDGET_RESOURCES" ]]; then
  cp -R "$WIDGET_RESOURCES" "$APP/Contents/Resources/"
fi

INKLET_OUTPUT_DIR="$OUTPUT_DIR" bash "$SCRIPT_DIR/build-widgets.sh" "$CONFIGURATION"
case "$CONFIGURATION" in debug) XCODE_CONFIGURATION=Debug ;; release) XCODE_CONFIGURATION=Release ;; esac
WIDGET_DERIVED_DATA="${INKLET_WIDGET_DERIVED_DATA:-$OUTPUT_DIR/WidgetDerivedData}"
mkdir -p "$APP/Contents/PlugIns"
cp -R "$WIDGET_DERIVED_DATA/Build/Products/$XCODE_CONFIGURATION/InkletWidgets.appex" "$APP/Contents/PlugIns/"

# Reuse the product's 1024px source icon and let iconutil create the native
# bundle icon. The temporary iconset never enters the artifact.
ICON_SOURCE="${INKLET_ICON_SOURCE:-$ROOT_DIR/Resources/icon.png}"
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
  <key>CFBundleName</key><string>inklet Portal</string>
  <key>CFBundleDisplayName</key><string>inklet Portal</string>
  <key>CFBundleExecutable</key><string>inklet</string>
  <key>CFBundleIdentifier</key><string>com.iminklet.mac</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>inklet.icns</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>InkletAppGroupIdentifier</key><string>$INKLET_APP_GROUP</string>
  <key>InkletWidgetStorageMode</key><string>$INKLET_WIDGET_STORAGE_MODE</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>com.iminklet.mac.widgets</string>
    <key>CFBundleURLSchemes</key><array><string>inklet-mac</string></array>
  </dict></array>
  <key>NSAppleEventsUsageDescription</key>
  <string>inklet Portal reads what you're looking at — a browser's address, a Finder selection, or the photo you have open — so the composer can offer it when you summon it.</string>
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
  <key>SUFeedURL</key><string>$SPARKLE_FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><true/>
</dict>
</plist>
PLIST

SIGNING_RESOURCES="$OUTPUT_DIR/SigningEntitlements"
mkdir -p "$SIGNING_RESOURCES"
ENTITLEMENTS="$SIGNING_RESOURCES/InkletMac.entitlements"
cp "$ROOT_DIR/Resources/InkletMac.entitlements" "$ENTITLEMENTS"
WIDGET="$APP/Contents/PlugIns/InkletWidgets.appex"
WIDGET_ENTITLEMENTS="$SIGNING_RESOURCES/InkletWidgets.entitlements"
cp "$ROOT_DIR/WidgetExtension/InkletPresentationWidget.entitlements" "$WIDGET_ENTITLEMENTS"
for entitlement_file in "$ENTITLEMENTS" "$WIDGET_ENTITLEMENTS"; do
  /usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 $INKLET_APP_GROUP" "$entitlement_file"
done
# Sparkle ships pre-signed; re-sign its nested executables with our identity
# (innermost first) so the host app's signature covers a consistent tree.
# The XPC services keep their own entitlements. Sparkle's docs recommend
# exactly this sequence rather than --deep.
sign_sparkle() {
  local -a flags=("$@")
  for xpc in Installer Downloader; do
    codesign --force "${flags[@]}" --preserve-metadata=entitlements \
      "$SPARKLE/Versions/B/XPCServices/$xpc.xpc"
  done
  codesign --force "${flags[@]}" "$SPARKLE/Versions/B/Autoupdate"
  codesign --force "${flags[@]}" "$SPARKLE/Versions/B/Updater.app"
  codesign --force "${flags[@]}" "$SPARKLE"
}

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  sign_sparkle --sign -
  codesign --force --sign - --entitlements "$WIDGET_ENTITLEMENTS" "$WIDGET"
  codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
else
  if [[ -n "${INKLET_WIDGET_PROVISION_PROFILE:-}" ]]; then
    cp "$INKLET_WIDGET_PROVISION_PROFILE" "$WIDGET/Contents/embedded.provisionprofile"
  fi
  if [[ -n "${INKLET_APP_PROVISION_PROFILE:-}" ]]; then
    cp "$INKLET_APP_PROVISION_PROFILE" "$APP/Contents/embedded.provisionprofile"
  fi
  sign_sparkle --sign "$SIGN_IDENTITY" --options runtime --timestamp
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
    --entitlements "$WIDGET_ENTITLEMENTS" "$WIDGET"
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

if [[ "$INSTALL_AFTER_BUILD" == "1" ]]; then
  INSTALLED="$HOME/Applications/inklet Portal.app"
  mkdir -p "$HOME/Applications"
  rm -rf "$INSTALLED"
  cp -R "$APP" "$INSTALLED"
  echo "installed $INSTALLED"
fi

echo "built $APP"
