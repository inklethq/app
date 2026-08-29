# inklet for macOS

The native SwiftUI client ships from the public `inklethq/app` releases next
to the Windows Electron build. It targets macOS 26 and produces one universal
disk image for Apple silicon and Intel Macs.

## Local build

```sh
./Scripts/build-app.sh debug
```

Set `INKLET_INSTALL=1` to copy the result to `~/Applications/inklet.app`.

## Release build

Pushing an annotated `v*` tag runs `.github/workflows/release.yml`. The macOS
job builds both architectures, signs the app and disk image with Developer ID,
submits the disk image to Apple's notarization service, staples the ticket, and
uploads both versioned and stable release assets.

Required repository secrets:

- `CSC_LINK`: base64-encoded Developer ID Application `.p12`
- `CSC_KEY_PASSWORD`: password for that `.p12`
- `APPLE_API_KEY`: base64-encoded App Store Connect API `.p8`
- `APPLE_API_KEY_ID`
- `APPLE_API_ISSUER`
