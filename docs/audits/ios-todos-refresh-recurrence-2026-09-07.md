# iOS refresh interruption and signing verification

Kent requested a root-cause recheck after repeated stale-data warnings and
development-certificate revocation emails. Verification used the live
kent@runner.now workspace on iPhone 17 / iOS 26.4 simulator
`1B948405-BFB9-4A8F-AE50-7D639732BBF5`.

## Navigation cancellation

Commit `017736c1` moved refresh ownership out of SwiftUI's transient list task.
The saved collection now finishes loading when a todo opens or a tab changes;
overlapping refresh callers await the same operation.

The recheck rebuilt the exact released source at `38f6759f` in an isolated
checkout, excluding unrelated local work. At 20:35 UTC, opening a todo during
refresh, switching through Today and Chat, and returning to Todos completed
all eight collection pages (offsets 0 through 1400). Cloud Run recorded a 200
for each page. The list finished without the stale-data warning.

## Additional cause found: a persisted partial-sync validator

The HTTP client still saved page one's collection ETag immediately. The sync's
`defer` removed that marker on a normal error, but process termination never
ran that cleanup. Relaunch could therefore get a 304 for a collection whose
later pages had not finished saving.

The before-fix reproduction is confirmed in production request logs:

- 20:36:09–20:36:16 UTC: pages at offsets 0, 200, 400, and 600 returned 200.
- The simulator app was terminated before the remaining pages completed.
- The persisted preferences still contained `todos.v5.cards`.
- 20:36:21 UTC: reopening Todos returned 304 for page one, skipping the rest.

The follow-up fix returns the collection ETag with the decoded listing without
persisting it. `ProductionDataSync` commits it only after every page, absent-row
reconciliation, and the final SwiftData save succeed. Failed or incomplete sync
still invalidates the marker. The `todos.v6` cache namespace forces a one-time
refresh for devices carrying markers from an interrupted older build.

After-fix manual checks retained the bad v5 marker to verify the upgrade path:

- The updated app ignored the old marker and began fetching all pages.
- Terminating this refresh after offset 600 left no v6 marker persisted.
- Relaunch fetched from offset 0 again, instead of accepting the incomplete
  collection as unchanged.
- Backgrounding and returning during this resumed refresh completed through
  offset 1400. Only then did `todos.v6.cards` appear in saved preferences, and
  the refresh indicator disappeared without a warning.
- A subsequent cold launch reopened the saved list without a warning; Cloud
  Run recorded the expected page-one 304 at 20:39:13 UTC after the full save.

No business message, todo completion, or dismissal was submitted. Existing
todo details were opened through the normal UI. These are simulator/manual
checks against production, not a physical-iPhone verification or an automated
test suite. Tests were intentionally not added or run under the repository's
manual-first policy. XcodeGen passed for the isolated checkout, and the narrow
simulator build passed for the final source. An initial build location under
Documents encountered macOS resource-fork signing metadata; rebuilding with
DerivedData under `/private/tmp` succeeded.

## Certificate recurrence

The former release cleanup explicitly revoked development certificates created
by earlier automatic-signing runs. Commit `38f6759f` removes that script and
uses the existing Apple Distribution identity plus `Maraithon AppStore CI` for
manual archive/export. Neither step allows automatic provisioning updates.

Two consecutive fresh GitHub runners completed releases successfully:

- [34159375573](https://github.com/argonavis-labs/maraithon/actions/runs/34159375573)
- [34159839209](https://github.com/argonavis-labs/maraithon/actions/runs/34159839209)

The team certificate inventory remained the same 11 IDs across both runs:
zero created, zero revoked. Both builds were processed and available to
Founders, including Kent's verified tester membership. Normal certificate
expiry still requires scheduled renewal; per-release certificate churn is
removed.

## Final release

The additional validator fix shipped from `a164cac4` as TestFlight
**1.0.1 (20260907204020)** through successful workflow
[34160278360](https://github.com/argonavis-labs/maraithon/actions/runs/34160278360).
Apple reports the build as `VALID`; the release verified Founders access and
Kent's tester membership. A third certificate inventory comparison after
archive/upload again found the same 11 IDs, with zero created or revoked.
