# inklet Portal for macOS

The native SwiftUI client for inklet. It signs in with an inklet account,
composes Content from text, links, images, and files, sends it to inklet
Displays, manages account-owned Virtual Displays, and ships a WidgetKit
extension that shows those Displays on the desktop.

It targets macOS 26 and builds as one universal app for Apple silicon and
Intel Macs. The product name is **inklet Portal**, matching the iOS app.

> The Electron client that previously lived in this repository is archived
> unchanged on the `archive/electron-universal` branch and receives no further
> work.

## Repository layout

| Path | What it is |
| --- | --- |
| `Package.swift` | SwiftPM manifest: the app, two libraries, tests, and a preview tool |
| `Sources/InkletMac/` | The app: models, services (API, session, token store, hot keys), views, theme |
| `Sources/InkletPresentationKit/` | Shared library used by the app and the widget: targetless Presentation client (`/api/app/v1`), Presentation cache, Virtual Display core and renderer, widget data and deep links |
| `Sources/InkletPresentationWidget/` | Widget views: Quick Send, Activity, Virtual Display, plus bundled fonts |
| `WidgetExtension/` | The Xcode project and entitlements that turn the widget library into a real `.appex`. See [WidgetExtension/README.md](WidgetExtension/README.md) |
| `PreviewSupport/` | `InkletWidgetPreview`, an offline renderer for widget layouts in both appearances |
| `Scripts/` | Build, widget, App Group, and disk image scripts used locally and in CI |
| `Resources/` | App entitlements and the 1024px source icon |
| `Tests/` | SwiftPM tests for the app and the shared library |
| `docs/` | Virtual Display behavior, acceptance notes, implementation audit |
| `design/` | Reference design and fonts |

## Requirements

- macOS 26 with full Xcode 26. Command Line Tools alone cannot build the
  widget extension.
- The build uses `/Applications/Xcode.app` automatically when `DEVELOPER_DIR`
  is unset.

## Build and run

```sh
./Scripts/build-app.sh debug
```

The script builds `InkletMac` with SwiftPM, builds `InkletWidgets.appex` with
Xcode, generates the app icon, writes the Info.plist, embeds the extension,
and signs the bundle. The result is `build/inklet Portal.app`.

Set `INKLET_INSTALL=1` to also copy it to `~/Applications/inklet Portal.app`.

Useful environment variables:

| Variable | Purpose |
| --- | --- |
| `INKLET_VERSION`, `INKLET_BUILD_NUMBER` | Marketing version and build number written to the Info.plist |
| `INKLET_ARCHS` | Comma-separated architectures, e.g. `arm64,x86_64` for a universal build |
| `INKLET_SIGN_IDENTITY` | Developer ID identity; ad-hoc (`-`) when unset |
| `INKLET_TEAM_ID` | Required when the identity string does not end with the Team ID |
| `INKLET_APP_GROUP` | Overrides the App Group derived from the Team ID |
| `INKLET_RELEASE=1` | Compiles with `-DINKLET_RELEASE` |
| `INKLET_OUTPUT_DIR` | Output directory, default `build/` |

Ad-hoc builds use per-app widget storage. Only signed builds share live data
between the app and the widget through the App Group; see
`Scripts/widget-configuration.sh`.

## Test

```sh
xcrun swift test
xcrun swift run InkletWidgetPreview build/widget-previews
```

The first runs the shared data, routing, cache, and client tests. The second
renders every widget in light and dark appearance for visual review.

## Release

Pushing an annotated `v*` tag runs `.github/workflows/release.yml`:

1. create a draft GitHub Release from the tag message;
2. build the universal app, sign it and the widget with Developer ID;
3. create and sign `dist/inklet-portal-<version>-mac-universal.dmg`;
4. notarize with Apple, staple the ticket, upload the versioned disk image and
   a stable `inklet-portal-macOS.dmg`;
5. publish the Release.

`workflow_dispatch` can rebuild the macOS assets for an existing Release.

Required repository secrets:

| Secret | Purpose |
| --- | --- |
| `CSC_LINK` | Base64-encoded Developer ID Application `.p12` |
| `CSC_KEY_PASSWORD` | Password for that `.p12` |
| `APPLE_API_KEY` | Base64-encoded App Store Connect API `.p8` |
| `APPLE_API_KEY_ID` | Key ID for the `.p8` |
| `APPLE_API_ISSUER` | Issuer ID for the `.p8` |

`.github/workflows/ci.yml` validates the scripts, runs the tests, and packages
a universal ad-hoc build on every pull request and push to `main`.

## Backend dependencies

The app talks to `https://dev.iminklet.com` with an inklet user access token:

- `/api/devices`, `/api/raw-items`: Display and Content endpoints shared with
  the Portal and iOS.
- `/api/app/v1/contents`, `/api/app/v1/presentations`: targetless
  Presentations (Scene v1 and PNG renditions) used by widgets and Virtual
  Displays. The contract lives in the `inklet-sdk` repository.
- `/api/virtual-displays`: account-owned Virtual Displays; see
  [docs/virtual-displays.md](docs/virtual-displays.md).

Identifiers that must stay stable across releases: bundle ID
`com.iminklet.mac`, widget bundle ID `com.iminklet.mac.widgets`, URL schemes
`inklet` and `inklet-mac`, and the App Group derived in
`Scripts/widget-configuration.sh`.

## Related repositories

- `inklet-ios`: the iOS app, also named inklet Portal.
- `inklet-sdk`: the server-side SDK and the API contracts.
- `inklet-backend`: the API.
