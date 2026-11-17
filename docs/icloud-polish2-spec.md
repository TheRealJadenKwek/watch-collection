# iCloud sync polish round 2: spec (designer, 2026-11-17)

Worktree `~/watch-collection-polish`, branch `icloud-polish2` (from main 578544c). Items: `docs/icloud-polish.md`
8 to 17. Findings and probes: `~/Offload/watch-collection/review/icloud-p8/round2/` (B, C1, C2). One builder, one
pass, in the order under "Order of work". Paths below are under `ios/` unless they say otherwise.

Rules: no CloudKit schema, record type or field change; no hub API change; no new entitlement. No git writes. No
emojis or em-dashes. UI copy in plain words and it names no brand. Every behaviour change has a unit test that fails
with its fix reverted (say how you proved it). A healthy library (every photo readable, zone present, signed in) must
behave exactly as today; each item says why.

## Items 1 to 7 (earlier round): all in the code
1. Done: `SettingsView.swift:190-204` label and value rows. 2. Done: `MacSyncLine` (`SyncHealth.swift:448`).
3. Done: `AppStore.mirrorsAtLaunch`. 4. Done: `Mac/Bridge.swift` makes no `NSApplication` (D7).
6. Done: `SyncCheckpoint.revision` and `hubRevisionAtLaunch`. 7. Done: `tools/bridge/install.sh --label/--watch`, 11befac.
5. The rule stands, and the code still allows the slip: a DEBUG run with `-WCDataRoot` and no `-WCHub` falls back to
   the real hub (`AppStore.initialSyncAddress` ends in `Platform.defaultSyncAddress`). Cheap, so it is in this round:
   - Change: pull the choice into `static func initialAddress(hub: String?, ownData: Bool, saved: String?,
     legacy: String?, fallback: String) -> String`: `hub` if given; with `ownData`, `saved ?? ""` (never `legacy`
     or `fallback`); else today's chain. `initialSyncAddress` calls it (`ownData` is DEBUG `AppPaths.dataRoot != nil`).
   - Test (SyncRoutingTests): `testARunOnItsOwnDataNeverFallsBackToTheRealHub` (own data and no hub gives "", own
     data and a hub gives the hub, no own data gives today's chain with fallback `http://127.0.0.1:8931`).
   - Healthy: a Release build has no data root, so `ownData` is false and the chain is today's.

## 8. D3 give-up: keep the reference, hold it back from the hub only
Decision. A name the Mac (or, with item 11, the phone) has given up on is neither dropped nor waited on. The hub
exchange sends the hub a copy of the collection without that reference and lays the reference back into what it
installs. The reference stays in this device's collection, the iCloud document and the phone; only the hub, which
has no file to show, goes without it.
Why not the two options as written: the hub answers 409 to any document naming a file it lacks (`server.py:749-751`),
so "keep the reference and skip the file" cannot be sent as it is; and leaving `unreadable` out of `lost` with nothing
else stops the Mac's hub link for good on one damaged photo.

Changes:
- `Sources/CloudPhotos.swift`: `CloudPhotoMarks.lost` is `Set(notInCloud.keys)` only. New
  `var kept: Set<String> { Set(unreadable.keys) }`. The give-up log line ends "installing without it; its reference
  is kept". Fix the doc comments on `unreadable` and `lost`.
- `Sources/CloudSyncSession.swift`: `func namesKeptWithoutFile() async -> Set<String>` returns `link.marks.kept`,
  with no gate: keeping is the safe side whether or not iCloud can answer. (No cloud session means none kept.)
- `Sources/CollectionSync.swift`:
  - `static func photoPlan(gone: Set<String>, dropping: Set<String>?, keeping: Set<String>)
    -> (drop: Set<String>, keep: Set<String>)?`. `keep = gone ∩ keeping`; the rest of `gone` is dropped when
    `dropping` is nil or holds all of it; otherwise nil (wait). With `keeping` empty this is today's rule.
  - `exchange(..., dropping:, keeping: Set<String> = [])` uses it. A kept asset is skipped in the send loop before
    the gone-on-both-sides branch (also when its file vanished after the first check). The collection sent is
    `removingPhotos(lost ∪ kept, from: local)`. The base sent is unchanged.
  - `static func restoringPhotos(_ keys: Set<String>, from local: CollectionData, into data: CollectionData)
    -> CollectionData`, the inverse of `removingPhotos` over the same four things, only on items `data` still has:
    a photo `local` names and `data` lacks goes back after the nearest earlier photo of `local`'s order that `data`
    has (first if none); its `photoFocus` entry goes back; a `boxCutout` made from it goes back only if `data` has
    no cutout; a tile slot whose file is a key goes back only if `data` has nothing in that slot (items and
    `emptyBoxTiles`). Running it twice gives the same result as once.
- `Sources/AppStore.swift` `hubPass`: read `keeping = await cloud?.namesKeptWithoutFile() ?? []` beside `dropping`
  and pass it. After `BoxModel.installing` and the three settings lines:
  `if !keeping.isEmpty, let local { merged = CollectionSyncClient.restoringPhotos(keeping, from: local, into: merged) }`.
  `syncBase` and the checkpoint's `base` stay `result.data` (the hub's own answer). Fast path: its last clause
  becomes "no named file is missing here, or every missing one is in `keeping`" (ask for `keeping` only when
  something is missing), so a kept photo does not force a full exchange and a `sync.json` rewrite every tick.
- `docs/icloud-plan.md` (sections 4 step 6, 5, 8's table row) and `docs/icloud-fixes.md` D3: "counts as not in
  iCloud for the drop rule" becomes "its reference is kept and held back from the hub".

Tests:
- BoxModelTests `testRestoringPhotosUndoesRemovingPhotos`: for a first, middle and last photo with framing, a
  cutout and a tile, `restoringPhotos(K, from: D, into: removingPhotos(K, from: D)) == D`; empty keys return the input.
- BoxModelTests `testRestoringPhotosLeavesTheHubsOwnChangesAlone`: an item the answer deleted stays deleted; a photo
  the answer added or reordered stays where the answer put it; a cutout or tile slot the answer filled is not replaced.
- SyncRoutingTests `testThePhotoPlanKeepsAGivenUpNameAndDropsOrWaitsOnTheRest`: the table for `photoPlan` (keeping
  empty equals today's rule for `dropping` nil, [], and a superset; kept names never make it wait, also with
  `dropping` nil). Extend `testTheHubExchangeWaitsForAPhotoICloudMayStillHave`: with `dropping: []` and
  `keeping: [key]` the exchange reaches for the hub (URLError) instead of returning nil.
- CloudLinkTests `test41AGivenUpPhotoKeepsItsReferenceEverywhere` (B probe P1 turned round): the phone sends p1,
  iCloud's copy is damaged, the Mac gives up after the hour; `marks.kept` has it and `marks.lost` does not; apply
  the exchange's two steps to the Mac's data (`removingPhotos` then `restoringPhotos`); the Mac's next pass writes
  nothing, the iCloud document still names p1, and the phone's pass leaves its `photos` as `["p1.jpg"]`.
- Update test26's assertion at `CloudLinkTests.swift:942` to the new meaning.
Healthy library: `unreadable` only gains a name after iCloud has handed over bytes failing their checksum three times
across an hour. While it is empty, `keeping` is empty, `photoPlan` is today's rule, `restoringPhotos` is not called,
and the fast path's new clause is not reached (nothing is missing).
Accepted limit: a kept photo deleted in the web app comes back on the Mac as a reference (no file). It needs a
damaged iCloud copy and a web delete of that same photo; nothing is lost, and deleting it on a device removes it.

## 9. D2 held photo that cannot be read: name it; no install-without-write
Decision. Name the watch in the reason and log the names at error level. Do not install the merge while the photo
is held: it needs an install from the middle of a pass or a new outcome, a "keep mine" answer would be asked again
every pass (the book cannot move), and the screens would have to say two things at once. The stall is now loud and
names what to fix.
- `Sources/CloudPhotos.swift`: `static func photoOwner(_ name: String, in data: CollectionData) -> String?` on
  `CloudLink` (the watch whose id is the folder, or the wishlist item for `wl-<id>`; nil otherwise).
  `CloudPhotoPush.wait` becomes `func wait(naming data: CollectionData? = nil) -> CloudWait?`. Reasons: one photo,
  "a photo of <name> on this device could not be read; sync will try it again"; several, "<n> photos on this device
  could not be read, the first of <name>; sync will try them again"; no owner found, today's `unreadableReason`.
- `Sources/CloudSync.swift` `run` and `create`: call `push.wait(naming: installed)`; when `push.unreadable` is not
  empty, `photoLog.error` once with the names ("dir/file", public) and "the document waits".
- `Sources/CollectionSync.swift`: `UnreadablePhotoError` gains `var owner: String? = nil`, set from `local` in
  `unreadable(_:)`; description "A photo of <owner> on this device could not be read. Sync will retry." (today's
  sentence when nil).
Tests: CloudLinkTests `test42AnUnreadablePhotoIsNamedByItsWatch` (one, several, and a box-tile name with no
owner); test27 also asserts the reason holds the watch's name; the R4 test in SyncRoutingTests asserts `owner`.
Healthy library: these strings exist only when a held file cannot be read.

## 10. Pending creation across a nil head: leave it
Reusing the pending epoch is only sound when the next creation writes the same body, and that case already merges
clean with no base. With a changed body, a reused epoch could pair the document with the wrong base and read new
items as remote deletes: worse than today, where the late commit ends in a union and at most a question (B probe
P6: no record lost). The trigger needs CloudKit to commit a save more than a tick after the client gave up on it.
The pending life cycle took three review rounds; it is not reopened for this.

## 11. The phone gives up on a damaged photo as the Mac does
Confirmed, with item 8's meaning (kept, never dropped).
- `Sources/CloudPhotos.swift`: lift the give-up test out of `pullPhotos` into
  `private func struck(_ name: String, at: Date) -> Bool` (strikes it; when `damagedStrikes` over `damagedSpan` are
  reached, `noteUnreadable` plus the log line; returns whether it gave up). `pullPhotos` uses it. In `note`,
  `.failure(.damagedPhoto)` sets `failedLately` as today and calls `struck`; `.failure(.other)` is unchanged.
Tests: CloudLinkTests `test43ThePhoneGivesUpOnADamagedPhotoAfterThreeTriesOverAnHour` (fetches 11 minutes apart;
before the hour `marks.damaged` counts up; after it `marks.kept` has the name, later fetches and the fill ask
iCloud no more; a repaired photo fetched before the hour clears the strikes). SyncRoutingTests
`testAPhoneOnTheHubStopsWaitingOnADamagedPhoto` (C1 probe 6 turned round: before the hour `photoPlan` with the
session's two sets is nil; after it, it keeps the name).
Healthy library: only a fetch whose bytes fail their checksum strikes.

## 12. Small items
- (a) `CloudPhotoMarks.strike` clears `notInCloud[name]`. Test: CloudLinkTests
  `test44AStrikeClearsAnOlderNotInICloudMark` (`lost` no longer holds the name).
- (b) The fake stops being kinder: `FakeCloudStore.uploadPhoto` stores the bytes the file holds under the sha and
  size it was given (drop the "described wrongly" throw), and gains `onNextUploadRead(_:)`, run once before it reads
  the file. Test: `test45AFileRewrittenWhileItGoesUpMakesARecordTheMacCannotRead` (the phone's file is rewritten in
  the hook; the Mac's pass waits with `damagedReason` and holds one strike). No engine change; see "Not doing".
- (c) `CloudRecords.precedes`: every case its own rank, highest first: misconfigured, noAccount, purged, quotaFull,
  retryAfter, changed, network, photoFileMissing, damagedPhoto, other, cancelled. Test: CloudRecordsTests
  `testAPartialFailureNeverTiesOnItsItems` (cancelled with other is `.other`, network with damaged is `.network`,
  each built in both item orders).
Healthy library: none of these paths runs without a failure.

## 13 and 14. The drop rule's memory of "iCloud cannot answer" must be fresh
Decision: one rule for both. What the session remembers (`lastWait`) is trusted for 10 minutes
(`CloudLink.missingRecheck`); older than that, or never set this launch, iCloud is asked first, and only when the
answer matters (a file is gone on both sides). On the phone, a fetch made in this hub pass outranks an old sign-out.
- `Sources/CloudSync.swift`: `func gate(_ book: CloudBook) async -> CloudWait?` on `CloudLink`. Two reads
  (`account`, `head`), nothing written, nothing kept, `statuses` untouched. Returns nil at once when `running`,
  `disabled`, or `book.notBefore` is ahead. `.noDocument` for another account, no document, or another epoch;
  `.newerFormat`; a thrown `.noAccount` gives `.noAccount`, `.purged` gives `.erased`; any other failure gives nil.
- `Sources/CloudPhotos.swift`: `fetchPhotos` returns `(asked: Bool, stoppedBy: CloudFailure?)`, `asked` true when
  it called the store at least once (two call sites in CloudLinkTests change).
- `Sources/CloudSyncSession.swift`: `private var gateAt: Date?`, set in `report` and after a `gate` call.
  `fetch(_:)` resets `fetchAsked` and `fetchFailure` first, then records both. `namesNotInCloud(gone: Bool = false)`:
  1. today's guard (link on, not paused, an epoch);
  2. if `fetchAsked`: `.noAccount`, `.purged`, `.misconfigured` return nil; anything else clears a remembered
     `.noAccount`;
  3. if `gone` and `gateAt` is nil or 10 minutes old: `lastWait = await link.gate(book)`, `gateAt = now()`;
  4. today's switch on `lastWait`, then `marks.lost`.
- `Sources/AppStore.swift` `hubPass`: compute the gone files once (`CollectionSyncClient.goneFiles`), use them for
  the phone's fetch, and pass `gone: !Set(gone).subtracting(keeping).isEmpty`.
Tests (SyncRoutingTests):
- `testAFreshLaunchAsksICloudBeforeNarrowingTheDropRule` (C1 probe 3): the Mac makes the document, the zone is
  deleted, a new session over the same folder: `namesNotInCloud(gone: true)` is nil (today `[]`); same for a
  signed-out relaunch.
- `testTheGateIsAskedOnlyForAGoneFileAndAtMostEveryTenMinutes`: with `gone: false` the store's head count does not
  move; with `gone: true` it moves once, not again within 10 minutes, again after; a pass in between resets the clock.
- `testAnUnreachableICloudKeepsTheNarrowedRule`: offline relaunch gives `[]`, not nil.
- `testAFetchThatReachedForICloudOutranksAnOldSignOut` (C1 probe 4): signed-out pass, signed in again, the fetch
  fails with `.network`: the answer is a set without the name (the exchange waits), not nil.
Healthy library: nothing is gone on both sides, so `gone` is false and iCloud is never asked (the head count test);
the Mac never fetches, so step 2 does not run there.
Left as it is: the Mac app's first hub pass after he signs back in still uses the previous tick's `.noAccount`, once.

## 15. A flip clears the questions of the link it leaves
Confirmed. `Sources/SyncRouting.swift`: `static func linkLeft(from old: SyncRoute, to new: SyncRoute) -> SyncLinkKind?`
(`old.active` when the active link changes, else nil). `AppStore.setPreferHub`: `if let left = SyncRoute.linkLeft(
from: before, to: route) { conflictSet.clear(left) }` right after the baseless line.
Test: SyncRoutingTests `testAFlipClearsTheQuestionsOfTheLinkItLeaves` (a set with hub and cloud questions and one
answer; after clearing `linkLeft` only the other link's remain; no change of active link gives nil).
Healthy library: runs only on a flip; with nothing waiting it clears an empty set.

## 16. The gate lives in the store, so a test can hold it shut
Adjusted: a round counter alone cannot cover call sites that only the Mac target compiles. Move the load-bearing
gate into shared code.
- `Sources/AppStore.swift`: `init(library: SyncLock? = nil)`, stored as `private let library`. `start()` begins
  with `if let library { _ = await library.whenReady() }`, before `guard !started`. `restore` replaces its
  `#if os(macOS)` block with `if library != nil { await start() }`. Add `var hasStarted: Bool { started }`.
- `Mac/MacApp.swift`: `AppStore(library: Entry.library)`; the window's `.task` keeps its own wait for the spinner,
  written `_ = await Entry.library.whenReady()` (also clears the warning, item 17). `Mac/Bridge.swift` keeps
  `AppStore()`: a tick holds the tick lock, not the app's.
- `Sources/SyncLock.swift`: `private(set) var asks = 0`, raised under `state` at each `keepAsking` round.
Tests (SyncLockTests, in a temp data root set through the `WCDataRoot` and `WCHub` defaults, removed in teardown):
- `testTheStoreReadsNothingUntilItHoldsTheLibrary`: a `sync.json` is on disk, another `SyncLock` holds the file,
  `holdForApp(retry: 0.02)` is `.waiting`; `start()` runs in a task; after `asks >= 20`, `hasStarted` is false and
  `data` is nil; the holder lets go; the task ends with the collection loaded.
- `testARestoreWaitsForTheLibraryToo`: same hold; `restore` in a task; after 20 asks `sync.json` is unchanged on
  disk; after release the restore is in.
If an `AppStore` cannot be built cleanly in the test host, stop and report; do not weaken the test to a helper.
Healthy library: on iOS and in the bridge `library` is nil and both lines are skipped. On the Mac the window already
waited on the same lock, so `start()`'s wait returns at once.

## 17. C2 notes
Become changes:
- (5) `CloudSyncCopy.missing`: "The iCloud copy is missing. Check that this iPhone and your Mac use the same Apple
  Account. If they do, open Watch Collection on your Mac to start iCloud sync again." (Apple's current name for the
  Apple ID.) SyncHealthTests: one assertion on the sentence; the D10 tests compare the constant and stay green.
- (7) `Sources/SyncHealth.swift`: `enum OpeningCopy { static let slowAfter: TimeInterval = 60; static func
  line(waited: TimeInterval) -> String? }`, nil before 60 s, then "Still waiting for the last background sync to
  finish." `Mac/MacApp.swift` `MacRootView`: a `.task(id: opening)` sleeps `slowAfter` and sets a flag; the line
  shows under "Opening the collection…" in the same secondary style; the flag clears when `opening` ends.
  SyncHealthTests `testTheOpeningLineAppearsAfterAMinute`.
- (8) plural: `CloudSyncCopy.choices(_ count: Int) -> String` ("1 change needs a choice", "3 changes need a
  choice") for `MacSyncLine.evaluate`, and `CloudSyncCopy.choicesInSettings(_:)` ("1 change needs your choice in
  Settings", "3 changes need your choice in Settings") for the two `AppStore` messages at :494 and :609.
  SyncHealthTests `testOneChangeNeedsAChoice`.
- (8) the unused-result warning at `MacApp.swift:49`: done under item 16.
Stay notes:
- (4) the check's zone delete and `zoneNotFound`: nothing to build; confirm from the rollout's 13 C run.
- (6) one amber pass after a long sleep: the phone's documented rule, consistent.
- (8) a lock file unlinked while held: needs something outside the app to delete the container folder, which takes
  `sync.json` with it; a guard in `SyncLock` would be new risk for no real case.

## Not doing
- Repairing a damaged iCloud photo (the phone sending it again): a `Photo` record never changes, and the Mac has no
  channel to tell the phone without a schema change. The reference is kept instead; adding the photo again fixes it.
- Uploading from a private copy of the bytes that were hashed (the one app-made cause of a damaged record, 12 b):
  it would put a temp-file write on every photo upload of a healthy library. Item 8 makes the outcome harmless.
- Installing while a held photo is unreadable (item 9), the pending-book hardening (item 10), a `SyncLock` inode
  guard (17.8): reasons above.
- A line on screen for kept photos: `cloud-status.json` already counts them (`photos.unreadable`) and the give-up
  is logged at error level. Worth a line only if it ever happens.

## Order of work and tiers
Builder (Opus, xhigh), one pass: 12a, 12c, 15, 17, item 5; then 9; then 11; then 8; then 13 and 14; then 16. Run
the suite after 8 and at the end. Reviewer (Fable, high) once on the whole diff before merge, reading in full:
`hubPass`, `exchange`, `photoPlan`, `restoringPhotos`, `namesNotInCloud`, `gate`. No scout needed.
Done means: the unit suite is green (372 today plus about 21 new, none removed, test26 and the two `fetchPhotos`
call sites edited); the ad-hoc Mac build succeeds with no new warning; for items 8, 11, 13, 14, 15 and 16 the report
says which revert made which new test fail; the plan and fixes wording for D3 is updated; nothing committed.

## Commands
As `docs/icloud-fixes.md` "Commands" (the lines of `docs/icloud-p4-brief.md`, own derived data, throwaway simulator
deleted after, never the real hub on 8931, never the real bundle id or a signed build, never his installed app):
```
cd ~/watch-collection-polish/ios && xcodegen generate >/dev/null && U=$(xcrun simctl create wc-polish2-test com.apple.CoreSimulator.SimDeviceType.iPhone-17 com.apple.CoreSimulator.SimRuntime.iOS-27-2) && xcodebuild test -project WatchCollection.xcodeproj -scheme WatchCollection -destination id=$U -derivedDataPath ~/Offload/watch-collection/derived/icloud-polish2/unit -only-testing:WatchCollectionTests 2>&1 | grep -E "error:|Executed [0-9]+ tests.*seconds|TEST (SUCCEEDED|FAILED)|failed \(" | tail -20; xcrun simctl delete $U && echo "sim deleted"
```
```
cd ~/watch-collection-polish/ios && xcodebuild -project WatchCollection.xcodeproj -scheme WatchCollectionMac -destination platform=macOS -derivedDataPath ~/Offload/watch-collection/derived/icloud-polish2/mac -configuration Debug PRODUCT_BUNDLE_IDENTIFIER=com.jadenkwek.watchcollection.mac.icloudcheck CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= CODE_SIGN_ENTITLEMENTS=$HOME/Offload/watch-collection/derived/icloud/adhoc-mac.entitlements build 2>&1 | grep -E "warning:|error:|BUILD (SUCCEEDED|FAILED)"
```
