# inklet Portal for macOS

The native SwiftUI client. It targets macOS 26 and produces one universal
disk image for Apple silicon and Intel Macs. The Electron client that
previously lived in this repository is archived on the
`archive/electron-universal` branch and no longer receives feature work.

## Local build

Requires full Xcode 26. The build automatically uses `/Applications/Xcode.app`
when `DEVELOPER_DIR` is unset; Command Line Tools alone cannot build the widgets.

```sh
./Scripts/build-app.sh debug
```

Set `INKLET_INSTALL=1` to copy the result to `~/Applications/inklet Portal.app`.
The app includes Quick Send (small), Activity (medium), and Virtual Display
(large). See [Widget setup and current API dependencies](WidgetExtension/README.md).

Run `xcrun swift test` for shared data/routing tests, or
`xcrun swift run InkletWidgetPreview build/widget-previews` for offline layout
previews in both appearances.

## Release build

Pushing an annotated `v*` tag runs `.github/workflows/release.yml`. The macOS
job builds both architectures, signs the app and disk image with Developer ID,
submits the disk image to Apple's notarization service, staples the ticket, and
uploads both versioned and stable release assets.

The build signs its embedded widget first and uses the signing identity's Team
ID for the shared macOS App Group. If using a certificate hash, set
`INKLET_TEAM_ID` explicitly. Both architectures include the widget extension.

Required repository secrets:

- `CSC_LINK`: base64-encoded Developer ID Application `.p12`
- `CSC_KEY_PASSWORD`: password for that `.p12`
- `APPLE_API_KEY`: base64-encoded App Store Connect API `.p8`
- `APPLE_API_KEY_ID`
- `APPLE_API_ISSUER`
