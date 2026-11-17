# iCloud sync: P8 fix round (lead's spec, 2026-11-17)

Findings: `~/Offload/watch-collection/review/icloud-p8/` (A-merge.md, B-link-store.md + B-link-store-probes.swift,
C1-wiring.md, C2-ui-bridge.md) and `docs/icloud-polish.md`. Three builders, three worktrees, strict file ownership.
Every fix gets a regression test that fails before it and passes after (the reviewers' probes are a head start).

## Lead decisions (binding)
- **D1 Book of a fresh document (B2, C1#2).** Before `write(over: nil)`, the link persists a book carrying
  `pendingEpoch` and `pendingBase` (= exactly the body it is about to write) through a persist hook the caller
  supplies (CloudSyncSession saves `cloud.json` at once). On any later pass: a document whose epoch == pendingEpoch
  adopts pendingBase as its base and clears pending; any other epoch, or no document, clears pending and follows the
  normal rules. In CloudSyncSession, a pass overtaken by an edit keeps the new book only when it wrote and the body it
  wrote equals the projection of that round's local input (a pure push); otherwise drop both as today. Back-off
  fields (`notBefore`, `quotaFullAt`, `paused`) from the new book are kept even when the rest is dropped (B lower).
- **D2 Unreadable held photo (B1).** A send-time read failure counts as "file gone" only if `!files.exists(name)`
  when rechecked. Any other read error holds the document back this pass (no write) and reports a wait.
- **D3 Mac download failures (B3).** The Mac installs past a failed download only for "not in iCloud" (marked
  notInCloud). A checksum mismatch is retried on later passes; after 3 failures spread over at least 1 hour it is
  marked unreadable. Every other failure waits for the next pass. Unreadable counts as notInCloud for the drop rule
  (D4), logged loudly.
- **D4 Narrowed drop rule (C1#1).** It applies only while the cloud link can answer: link on, account available,
  not paused, not off, not newer format, and the book holds a document epoch. Otherwise the old rule (drop what is
  gone on both sides) applies, exactly as before iCloud.
- **D5 Manual link switch on the phone (B4).** The first pass of the newly active link after a flip of "Sync
  directly with the Mac instead" (either direction) merges with no base: union, nothing deleted, differing fields ask.
- **D6 `write(over: nil)` (B5).** Save the record first; only on `zoneNotFound` save the zone and retry once; on
  `userDeletedZone` throw `.purged`. `prepareZone()` stays the only other zone save.
- **D7 Bridge without NSApplication (C2#1).** Bridge mode never creates `NSApplication` and drops the Info-dictionary
  trick. Prove it: with a bridge tick running, `open` on the app starts the GUI, and the tick steps aside.
- **D8 Bridge install safety (C2#2).** The app carries a marker string `WCBridgeEntry-v1` used by `Entry`;
  `install.sh` refuses a binary without it (`grep -a`), never by running it. Plan section 9 rollback gains a first
  step `tools/bridge/install.sh remove`. Versions: iOS MARKETING_VERSION 5.1; Mac MARKETING_VERSION 5.1,
  CURRENT_PROJECT_VERSION 2.
- **D9 The app never syncs without the lock (C2#3).** No 5 s fallback. The app keeps its want raised and retries
  every 0.5 s; the UI works throughout, edits save locally and sync once the lock is held. If the lock file cannot be
  opened at all, the app syncs without it (logged), as now.
- **D10 Joined phone, no document (C2#4).** Not "healthy": for a joined phone, AppStore records `.noDocument` as
  `syncFailures.failed(.other(CloudSyncCopy.missing))` instead of `reachedMac()`, so the staleness notice can fire
  (E); `CloudSyncCopy.sentence` returns `CloudSyncCopy.missing` for a joined phone waiting on `.noDocument` (U). The
  constant is already in SyncHealth.swift (lead commit); neither builder renames it.
- **D11 Mac status line (C2#5, polish 2).** The sidebar headline is the worse of the hub and iCloud states. iCloud
  paused, blocked, signed out or full shows at once; offline, failed or throttled only after the stale threshold.
- **D12 Transient account state (C2#12).** CloudKitStore maps `couldNotDetermine` to the network failure (quiet,
  `.offline`, stale notice only after the threshold). `noAccount`, `restricted` and `temporarilyUnavailable` stay
  `.noAccount`. E only; no new CloudWait case.

## Builder E: engine and wiring (worktree ~/watch-collection-icloud, branch icloud-sync)
Owns: CloudSync, CloudPhotos, CloudKitStore, CloudRecords, CloudSyncSession, SyncRouting, CloudFiles, AppStore
(except the `SyncStatus` class, see U), CollectionSync, PhotoStore, LocalBackup, APIClient, WatchCollectionApp,
BoxTrial (if the trials key lives there), FakeCloudStore, CloudLinkTests, CloudRecordsTests, SyncRoutingTests.
Does: D1 to D6, D10 (failure record), D12, C2#7 (hub-pass conflicts count into status-mac.conflicts),
C2#10 (atomic pre-iCloud copy), C1#3 (DEBUG data root leaks: backup folder, box trials key, sync settings keys under
the data root; `-WCHub` ignored without `-WCDataRoot`), C1#4 (fill re-checks the path before each batch and stops
on expensive or constrained; bulk fill calls disallow cellular), C1 lows (hub conflicts at join, pre-iCloud copy
right before the first cloud write or install instead of the first pass, cancelled calls not failures, phone never
runs the hub after a cloud round that wrote, no no-op reinstall after a write, a joined phone switched to direct
never drops photos it has not downloaded), polish 3 and 6. Make the fake behave like CloudKit where B says it is
kinder; add B's and C1's probes as tests.

## Builder U: Mac shell and status UI (worktree ~/watch-collection-icloud-u, branch icloud-fix-u)
Owns: Mac/Bridge, Mac/MacApp, Mac/CloudKitCheck, SyncLock, SyncHealth, SyncNotice, SettingsView, SyncLockTests,
SyncHealthTests, tools/bridge/*, project.yml, docs/icloud-plan.md; in AppStore.swift ONLY the `SyncStatus` class, if
a new published field is needed (say so in the report).
Does: D7, D8, D9, D10 (sentence), D11, polish 1 and 2, C2#6 (with the switch on, Settings shows the hub
copy, never the frozen iCloud sentence), C2#8 (document in docs/icloud-plan.md how the check runs in Production:
`WC_CLOUDKIT_ENV=Production` on a Debug build), C2#9 (the check deletes `CollectionCheck` at start too), C2#11 (note
in the plan's risks).

## Builder M: merge tests (worktree ~/watch-collection-icloud-m, branch icloud-fix-m)
Owns: tools/merge_vectors.py, ios/UnitTests/CollectionMergeTests.swift, ios/UnitTests/Fixtures/merge-vectors.json,
comments only in ios/Sources/JSONValue.swift and CollectionMerge.swift.
Does: A6 to A8 (look-alike Unicode ids, strings and keys; whole numbers above 2^53; 6.0 box sizes; byte-for-byte
output comparison; answers matched by exact code-point path; the reviewer's broken-copy check must now fail), and
corrects the "same bytes as Python" comments for numbers above 2^53. Behaviour changes only if a new vector shows a
divergence on input the apps can write; report anything else.

## Commands
Each builder uses its own derived data: `~/Offload/watch-collection/derived/icloud-fix-<e|u|m>/{unit,mac}` in the
commands of `docs/icloud-p4-brief.md` (same flags otherwise, sandbox-only entitlements file for ad-hoc Mac builds,
throwaway simulators deleted after). Never the real hub on 8931; never the real bundle id, never a signed build.
D7's proof uses the ad-hoc build (its own bundle id): a DEBUG-only flag may hold a tick open long enough to `open`
the same .app while it runs. Never quit, open or touch his installed Watch Collection app.

## Shared names (do not change)
`CloudWait` keeps its cases. `CloudDisplay` keeps its fields. `CloudSyncCopy.missing` exists. If U needs a new
`SyncStatus` field, U adds it with a default and E does not touch that class; E does not edit SyncHealth.swift.

## Rules
No git writes (the lead commits and merges). No emojis or em-dashes. Never touch the Arsenal Duo, Dentiza Duo, iPhone
Duo or Arc Records simulators. Report: files and line counts, tests and result, each item done with its test, any
departure with the reason, three spots for the re-review.
