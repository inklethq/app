# Virtual Display (native apps)

## Use

1. Sign in, open **New Display → Virtual Display**, and give it a name.
2. In its detail page, publish text or choose an image. Text is rendered locally;
   images fit completely inside the display with white margins when necessary.
3. Add **inklet → Virtual Display** in the largest available Widget size.
4. Edit the Widget and choose the named display. Clicking it opens that display's
   content editor and settings. Multiple Widgets can use the same display.

macOS supports large and extra large. iPhone supports large; iPad also supports
extra large. The configurable iOS Widget requires iOS 17+, while the app retains
its existing iOS 16 deployment target. Existing small/medium widgets are unchanged.

The native display list synchronizes from the account API, including names,
deletions, and the current PNG. Publishing has a revision check: if another device
published first, refresh the display, review the latest frame, then publish your
draft again. Removing a Widget does not delete the display. Deleting a display
removes its frame and makes Widgets ask for another selection.

## Distribution requirements

Deploy the accompanying inklet-backend `docs/api/virtual-displays.md` routes first.
Both clients use `https://dev.iminklet.com/api/virtual-displays`; widget reads use
`/api/virtual-display-widget/{id}` with a per-display read-only credential.

App and Widget extension must be signed with matching App Group entitlements.
iOS uses `group.com.iminklet.portal`; macOS's existing build scripts derive the
Team-ID group for signed releases. Ad-hoc macOS builds use local preview storage
and cannot verify real desktop Widget sharing. Cross-platform sync uses the
backend, not a shared iOS/macOS filesystem container.

Open inklet periodically to refresh its 30-day Widget access. The extension never
stores account login/refresh tokens. Last successful frames remain available
offline. WidgetKit controls refresh timing; the 30-minute requested timeline does
not guarantee immediate or periodic delivery.

The text/image/AI modes now share the documented targetless Presentation pipeline:
`POST /api/app/v1/contents` → upload binary assets without Authorization → confirm
→ poll Content → poll the requested PNG rendition → download (renew expired URLs
with GET Presentation) → publish PNG to the selected Virtual Display → cache PNG
and Scene in the App Group → reload Widget timelines.

Text is rendered locally and submitted as a hardcode PNG; Image uses hardcode;
AI uses auto and requires Pro. The existing macOS Auto composer now requires an
explicit Virtual Display selection. Both native display detail pages offer all
three modes. Output requests use the display's logical dimensions at 2× density.
An existing Scene can supply a missing output size through POST /renditions.

Nullable rendition URLs/expiry, preparing/failed states, aggregate-ready with a
failed PNG, sliding access-token renewal, and 429 Retry-After are handled. A failed
publish preserves the previous frame and keeps the generated Presentation for
retry. Draft request IDs survive failures within the current editor session;
retries of generation reuse the same Content idempotency key. Closing/restarting
the app does not currently restore an unfinished editor draft. A version conflict
requires refreshing before publishing again; it does not silently replace another
device's new frame. Signing out during generation prevents subsequent publishing.

Scene metadata is cached on the generating host alongside its published frame;
other devices currently synchronize the PNG through Virtual Display frame APIs.
Virtual Display registration/frame APIs remain a separate deployment requirement.
Queues/history, Quote/0, and SDK/BYOD enrollment remain outside this implementation.

Contract: https://docs-dev.iminklet.com/api/targetless-presentations/#macos

## Shared code

Keep `VirtualDisplayCore.swift`, `VirtualDisplayRenderer.swift`,
`VirtualDisplayController.swift`, `VirtualDisplayViews.swift`, and
`VirtualDisplayWidget.swift`, `PresentationModels.swift`, and `TargetlessClient.swift` equivalent between inklet-app/macos and inklet-ios.
The iOS `Shared` synchronized group belongs to both the app and extension. macOS
uses InkletPresentationKit and InkletPresentationWidget SwiftPM targets.

## Validation (2026-09-11)

- Swift tests cover multi-display isolation, deletion, stale revisions, account
  changes, logout, safe deep links, Chinese text and text overflow (including existing widget/cache tests).
- macOS app compiled; real Widget extension builds for arm64 and x86_64. App Intent
  metadata includes the selectable Virtual Display entity and configuration.
- iOS app and Widget extension build for arm64/x86_64 simulators; configuration
  metadata is present. No iOS deployment-target bump.
- Shared-client tests cover null URLs, failed PNGs, async polling, appended sizes,
  signed-URL renewal, uploads without account headers, and cancellation. Host
  controller tests cover failed publication/retry and logout during download
  (21 Swift tests pass across both test targets).
- Offline preview executable renders the production Widget views and text renderer
  in large/extra-large sizes. Whole-frame image placement and Chinese text checked.
- Backend suite and race checks pass. The real Postgres migration/concurrency test
  requires TEST_DATABASE_URL and skips without it.

Still requires deployment plus signed-device acceptance: register on one device,
choose the same ID on the other, publish from each, verify Widget refresh, then
exercise logout/deletion and offline fallback. Compilation and offline renders
are not a substitute for that live check.

Development endpoint check on 2026-09-11 (no credentials sent): the existing
`GET https://dev.iminklet.com/api/sdk/v1/displays` returns 401 as expected, while
`/api/app/v1/presentations` and `/api/virtual-displays` return 404. The app prefix
also returns 404 on auth.iminklet.com. The documented targetless routes and virtual
registration/frame routes must be deployed or routed before live acceptance can
pass. Documentation availability alone does not establish deployment readiness.
