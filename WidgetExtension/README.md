# inklet macOS Widgets

`InkletWidgets.xcodeproj` builds a real WidgetKit `.appex` with three widgets:

| Widget | Family | Content | Click |
| --- | --- | --- | --- |
| Quick Send | Small | iOS logo, plus button and seven rotating prompts | Open the composer |
| Activity | Medium | iOS 26-week activity heatmap | Open Home |
| Virtual Display | Large / Extra Large | Latest frame of the selected account-owned display, fitted without cropping | Open the selected display |

Quick Send and Activity use the same Newsreader / Inter fonts, paper colors and
heatmap shades as `inklet-ios/portal/portalWidget`. Virtual Display preserves the
rendered image's colors in light, dark and accented widget appearances. Empty
and signed-out states contain guidance, never fabricated user content.

## Build and add to the desktop

Requires full Xcode 26 with the macOS SDK, not only Command Line Tools.
From the repository root:

```sh
./Scripts/build-app.sh debug
# Universal production build (use your Developer ID identity):
INKLET_ARCHS=arm64,x86_64 INKLET_RELEASE=1 \
  INKLET_SIGN_IDENTITY='Developer ID Application: Your Name (YOURTEAMID)' \
  ./Scripts/build-app.sh release
```

The script embeds `InkletWidgets.appex` in `inklet Portal.app/Contents/PlugIns`, includes
the fonts, declares `inklet-mac://` links, signs the extension before its host,
and verifies the complete bundle. It finds `/Applications/Xcode.app` without
changing the machine's `xcode-select` setting. `DEVELOPER_DIR` can override it.

Open the built app and sign in. Control-click the desktop, choose **Edit
Widgets**, search for **inklet**, and add the desired widget. macOS controls the
exact widget size and the timing of timeline refreshes.

## Shared data and signing

The authenticated host creates and publishes displays. Virtual Display widgets also
fetch their selected frame using a display-scoped, read-only credential; account
JWTs and refresh credentials are never shared with the widget. `WidgetDataStore` writes
account-scoped activity and a complete Presentation snapshot to `MacWidgets`
inside the shared App Group. Images are downloaded before publishing, so the
extension can render offline without tokens or expired image URLs. The host
asks WidgetKit to reload after a successful write and on account changes.

Each payload carries a login generation. Signing out or changing accounts
invalidates that generation before removing payloads. Late responses from an
old login cannot become the next widget snapshot. The latest display survives
an ordinary restart in the same account.

For Developer ID distribution, the build scripts derive
`<TEAMID>.com.iminklet.mac` from the signing identity and put the same identifier
in both bundles and their entitlements. This is Apple's macOS App Group format;
it does not require an App Group provisioning profile. When signing by a
certificate hash, also set `INKLET_TEAM_ID`. See Apple's
[App Group container documentation](https://developer.apple.com/documentation/xcode/accessing-app-group-containers).

`INKLET_APP_GROUP` can explicitly override the group. A `group.*` override must
be authorized by matching provisioning profiles; pass those as
`INKLET_APP_PROVISION_PROFILE` and `INKLET_WIDGET_PROVISION_PROFILE` when needed.
Ad-hoc local builds declare the development group `group.com.iminklet.portal`
but explicitly use per-process local preview storage. They do not attempt to
access an unprovisioned shared container, which can block the host at startup.
Their successful build/signature check is not a Developer ID shared-container
or desktop-gallery acceptance test. The Virtual Display page labels this mode.
Local Application Support storage cannot substitute for an entitled container.

## Data dependencies

Activity mirrors the host's existing raw-item activity data. The host pages
until it covers the season or reaches the end of the feed, instead of silently
truncating at 300 items. A failed refresh retains the previous snapshot. The targetless
Presentation flow requests a 720 × 752 PNG for the 360 × 376 logical display. It is wired
from the composer through image download, atomic storage, the app's Virtual
Display page and WidgetKit reload.

The backend implementation is tracked in [backend PR #28](https://github.com/inklethq/backend/pull/28).
Targetless generation still requires deployment of the matching backend and Scene
worker; successful local builds are not proof of live service readiness. See
[Virtual Displays](../docs/virtual-displays.md) for the current integration details.
These widgets never create hardware devices or hardware pushes.

## Verification

```sh
cd macos
xcrun swift test
xcrun swift run InkletWidgetPreview build/widget-previews
```

The offline renderer uses the actual widget content views with explicit sample
data. It writes light/dark PNGs without touching a user account or App Group.
Shared tests cover persistence, account isolation, logout, atomic image and
metadata replacement, calendar boundaries, and accepted click destinations.
CI also packages and verifies the universal app with the real extension.

Validation on 2026-09-05: seven Swift tests passed; debug and universal release
bundles built and passed nested signature verification; host/extension font
resources, URL registration and matching container settings were checked. The
light/dark offline previews were visually inspected. A startup hang traced to
unprovisioned shared-container access was addressed by the explicit local
preview mode. Its final interactive retest was blocked by the Mac being locked.
Developer ID shared-container/gallery acceptance and live targetless generation
remain unverified for the dependencies described above.
