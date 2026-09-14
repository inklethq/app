#!/usr/bin/env bash
# Build a real WidgetKit extension; SwiftPM alone only emits the library.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIGURATION="${1:-debug}"
OUTPUT_DIR="${INKLET_OUTPUT_DIR:-$ROOT_DIR/build}"
DERIVED_DATA="${INKLET_WIDGET_DERIVED_DATA:-$OUTPUT_DIR/WidgetDerivedData}"
source "$SCRIPT_DIR/widget-configuration.sh"
inklet_configure_widget_group

# Use the full SDK without changing the user's xcode-select preference.
if ! xcodebuild -version >/dev/null 2>&1; then
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  else
    echo "Widget packaging requires Xcode; set DEVELOPER_DIR to its Contents/Developer directory." >&2
    exit 1
  fi
fi

case "$CONFIGURATION" in
  debug) XCODE_CONFIGURATION=Debug ;;
  release) XCODE_CONFIGURATION=Release ;;
  *) echo "Expected debug or release" >&2; exit 1 ;;
esac

BUILD_ARGS=(-project "$ROOT_DIR/WidgetExtension/InkletWidgets.xcodeproj"
  -scheme InkletWidgets -configuration "$XCODE_CONFIGURATION"
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED_DATA"
  -packageCachePath "$DERIVED_DATA/PackageCache"
  -clonedSourcePackagesDirPath "$DERIVED_DATA/SourcePackages"
  CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO
  "INKLET_APP_GROUP=$INKLET_APP_GROUP"
  "INKLET_WIDGET_STORAGE_MODE=$INKLET_WIDGET_STORAGE_MODE"
  "MARKETING_VERSION=${INKLET_VERSION:-0.2.0}"
  "CURRENT_PROJECT_VERSION=${INKLET_BUILD_NUMBER:-1}")
if [[ -n "${INKLET_ARCHS:-}" ]]; then
  BUILD_ARGS+=("ARCHS=${INKLET_ARCHS//,/ }" ONLY_ACTIVE_ARCH=NO)
fi
xcodebuild "${BUILD_ARGS[@]}" build
EXTENSION="$DERIVED_DATA/Build/Products/$XCODE_CONFIGURATION/InkletWidgets.appex"
test -x "$EXTENSION/Contents/MacOS/InkletWidgets"
echo "built $EXTENSION"
