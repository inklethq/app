# inklet Portal for macOS

The native SwiftUI client for inklet. It signs in with an inklet account
(password, Google, or Apple),
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
| `SPARKLE_PRIVATE_KEY` | EdDSA private key for signing Sparkle updates (see Automatic updates) |
| `CSC_LINK` | Base64-encoded Developer ID Application `.p12` |
| `CSC_KEY_PASSWORD` | Password for that `.p12` |
| `APPLE_API_KEY` | Base64-encoded App Store Connect API `.p8` |
| `APPLE_API_KEY_ID` | Key ID for the `.p8` |
| `APPLE_API_ISSUER` | Issuer ID for the `.p8` |

`.github/workflows/ci.yml` validates the scripts, runs the tests, and packages
a universal ad-hoc build on every pull request and push to `main`.

## Settings that reach the system

| Setting | How it works |
| --- | --- |
| Launch at login | `SMAppService.mainApp`; the toggle reads the system's status, and a "requires approval" state links to System Settings |
| Show in Dock | Switches the activation policy between regular and accessory. The menu bar item is always present, so the app stays reachable with the Dock icon off |
| Notifications | `UNUserNotificationCenter`: a card on its way, a failed send, a display that went offline. Permission is requested the first time an alert is turned on |
| Weather on Home | CoreLocation for an approximate position, conditions from Open-Meteo (no key, no WeatherKit entitlement) |

All four need a packaged `.app`; under `swift run` they show as unavailable.

## Automatic updates

Installed apps update themselves through [Sparkle](https://sparkle-project.org)
(SwiftPM dependency, embedded by `Scripts/build-app.sh`). Users get the standard
Sparkle sheet (Install Update, Remind Me Later, Skip This Version), a
"Check for Updates…" item in the application menu, and toggles under
Settings → General → Updates.

- Feed: `https://raw.githubusercontent.com/inklethq/app/appcast/appcast.xml`,
  maintained on the `appcast` branch by the release workflow. Never edit it by
  hand; run the workflow instead so signatures stay valid.
- Channels: a pre-release tag (`v0.2.0-beta.1`) is published to the `beta`
  channel. Pre-release builds and users who enable "Include beta versions" see
  it; stable builds otherwise only see stable releases.
- Signing: updates are signed with an EdDSA key. The public half is in
  `Scripts/build-app.sh` (`SPARKLE_PUBLIC_KEY`); the private half is the
  `SPARKLE_PRIVATE_KEY` repository secret and lives in the release manager's
  login Keychain as "Private key for signing Sparkle updates". Losing the
  private key means no installed copy can be updated again, so back it up
  (`generate_keys -x <file>` from the Sparkle `bin/` directory).
- Versions: Sparkle compares `CFBundleVersion`, which the workflow sets to the
  GitHub run number, so every release must be built by the workflow.

Ad-hoc local builds have the feed configured but Gatekeeper will not let
Sparkle replace an unsigned app, so test the full update path with a Developer
ID build.

## Backend dependencies

The app talks to `https://dev.iminklet.com` with an inklet user access token:

- `/api/app/v1/contents`, `/api/app/v1/analyses`, `/api/app/v1/presentations`:
  the Content → Analysis → Presentation pipeline. Every send from the composer
  uploads a Content and starts an Analysis; Knowledge lists Contents; Virtual
  Displays and widgets read Scene v1 and PNG renditions. The agent's progress
  is followed through the Analysis event stream. The contract lives in the
  `inklet-sdk` repository (`ANALYSIS_CONTRACT.md`) and
  `inklet-backend/docs/api/sdk-v1.md`.
- `/api/devices`: legacy Display reads, rename, unbind, queue advance, and
  history, shared with the Portal and iOS.
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
