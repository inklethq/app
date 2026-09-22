# Virtual Display acceptance — in progress

## Installed artifacts

- Native macOS app: installed in the tester's `~/Applications/inklet.app`.
- Developer ID signed arm64 Release bundle with embedded `InkletWidgets.appex`.
- Shared App Group: `5X22PG79XX.com.iminklet.mac`.
- The previously installed app was kept as a backup; the Release output was built into a local scratch directory.
- iPhone 17 Pro and iPad Pro 13-inch (M5) simulators have the latest iOS app/widget installed.
- iOS build: a Debug simulator build of `portal.app` in a local scratch directory.

## Verified

- 23 Swift tests passed, including background authentication completion and duplicate callback protection.
- macOS Release build and nested Developer ID signature verification passed.
- iOS app and widget simulator build passed.
- Backend PR #28 includes the Targetless main baseline, migration, scoped credentials,
  revision conflicts, generation isolation after delete/recreate, and full ETag validation.
- Backend local Go suite/race checks and PostgreSQL 16 CI passed on `3bc28a9`.

## Pending — do not describe these as passed

- AI auto generation with an entitled account (current account is FREE).
- macOS desktop widget gallery, display selection, deep link, restart and offline retention.
- iPhone large and iPad extra-large widget configuration/display in the simulator UI.

The Mac was subsequently available. Actual Google sign-in in the installed Release
app succeeded and opened Home as the existing FREE account. Virtual Displays opens
and handles the unavailable backend without crashing. No lock-screen or credential
protection was bypassed.

A live acceptance harness using the actual native controller and Widget reader is
prepared locally. It compiles, but its network acceptance test
has not run; the profile-only probe reported no loadable credentials. Run only after
service deployment and legitimate account access are available.

## Release and current blockers

- Final backend head `3bc28a9` received a new approval and was merged as `3aeb9252eadfe23e566446a1d575d7e454474936`.
- Backend `v0.26.0` Build & Release succeeded.
- Worker `v0.9.0` Build & Release succeeded.
- Final installed macOS App and Widget build number: `2026091102`.
- Light/dark and extra-large offline SwiftUI renders were inspected locally.
- Deployment task: INK-158 in the internal tracker.
- Deployment was blocked on operator access to the production environment; no
  authorized access path was available to the team at the time.
- Last unauthenticated dev probes still returned 404 for both `/api/app/v1/presentations` and `/api/virtual-displays`. No deployment or live main-chain acceptance is claimed.

Deployment work was paused at the user's explicit request because they did not have
access. Recovery steps for an authorized resumption are kept with the operators, not
in this repository; once access is restored the backend team can resume the
fixed-image deployment and smoke tests.

A proposed 15-minute unattended continuation automation was rejected by automatic approval review. It was NOT created. A separate explicit authorization question is pending; current task authorization has not been treated as approval to bypass that rejection.

## Authentication crash fixed — build 2026091102

Reports `inklet-2026-09-11-093129.ips` and `inklet-2026-09-11-093149.ips`
showed `_swift_task_checkIsolatedSwift` / `_dispatch_assert_queue_fail` in
`WebAuthCoordinator.run(url:)` on the SafariLaunchAgent XPC callback queue.
The AuthenticationServices callback inherited MainActor isolation.

A nonisolated, Sendable continuation relay now accepts background callbacks and
uses a lock to ensure immediate start failures and late callbacks resume only once.
Both cases have regression coverage. Release build and nested signature checks
passed; build 2026091102 was installed and actual Google login reached Home.
No newer Inklet crash report was present after the login and navigation checks.

## Live backend acceptance — resumed September 11

Supersedes the earlier deployment blockers above. User requested renewed backend
coordination. Production agent successfully executed on the existing server; it
reported backend v0.26.0 and worker v0.9.0 deployed at fixed tag@digest, healthy
backend and five polling workers. Duplicate queued deployment was cancelled.

Independently verified from this Mac:

- Both new unauthenticated API probes now return 401 instead of 404.
- Actual signed-in macOS app created `My inklet`, ID
  `345454f5-ee93-406f-b360-fad6c5f14284`, and published Chinese text, revision 1.
- Text publication uses PNG → Targetless hardcode Content/upload/confirm →
  Presentation/rendition download → Virtual Display PUT. Cached service output
  confirms presentation `01a09105-9bf9-7a61-a9e3-cb32983417ea`, rendition
  `01a09105-9c17-7b31-8625-a43149e76661`, PNG 720×752.
- Independent HTTP fetch using only that display's existing Widget credential
  returned 200 with valid PNG (36,295 bytes), revision 1; ETag revalidation returned 304.
  No credentials were printed or transmitted to the backend agent.
- The retrieved frame was saved locally and inspected.
- My inklet is retained for the user. Findings were sent to the backend agent for INK-158.

Still pending: AI auto with Pro entitlement, actual macOS desktop widget gallery
and configuration, and iPhone/iPad widget UI acceptance. HTTP Widget protocol
acceptance does not imply WidgetKit UI or scheduled refresh acceptance.
