# Watch Collection: iCloud sync plan (designer, 2026-11-16)

Goal: the iPhone and the Mac stay in step through iCloud, with no Tailscale and no need for the MacBook to be awake
for the phone's own edits to be safe. The hub stays exactly as it is (server.py and sync.py are not edited at all).

Facts come from `map.md` beside this file (cited as A1..B10) and from the code read for this plan:
`ios/Sources/CollectionSync.swift`, `AppStore.swift:1-330`, `Models.swift`, `PhotoStore.swift:60-135`, `sync.py` (whole),
`ios/project.yml`, `ios/Mac/MacApp.swift:1-60`, Arsenal's `Mac/CloudKitCheck.swift` and `Sources/LooksCloudKit.swift:20-75`.

## 1. Decisions

1. **One document record, not one record per watch.** The whole collection is one `Collection` record in his private
   CloudKit database, its JSON in a `CKAsset`. Each device does the same thing it does with the hub today: read the
   other side, three-way merge against its own base, write back only if nobody wrote in between
   (`ifServerRecordUnchanged`). The merge runs on the device, as a Swift twin of `sync.py`.
2. **Photos are one immutable `Photo` record per file**, named by its existing path, bytes sent as they are. Photos
   go up before any document that mentions them, the same invariant the hub enforces with its 409 (B2).
3. **Plain CloudKit calls by record id, no `CKSyncEngine`.** With one small document and blobs fetched on demand the
   engine has nothing to track, and it downloads every asset of every changed record, which would pull 147 MB onto
   the phone on first fetch. By-id calls map one to one onto the existing `syncNow` loop and are trivial to fake.
   Arsenal's own check harness already proves these exact calls on this team (`Mac/CloudKitCheck.swift:71-91`).
4. **Topology is a chain: iPhone <-> iCloud <-> Mac app <-> hub.** The Mac app is the only bridge. So that "Mac app
   closed" does not stop the bridge, a LaunchAgent runs the same signed app binary headless (`-WCBridge 1`) every
   60 s and whenever the hub's data folder changes. The hub cannot reach the private database itself (see Rejected).
5. **The phone leaves the Tailscale path the moment it first syncs through iCloud, and does not go back on its own.**
   Until a cloud document exists it keeps syncing with the hub as today, so nothing regresses during rollout.
6. **Only the Mac creates the cloud document, and only straight after a clean hub sync.** That one rule is what lets
   the stale phone join with its old hub base as a true common ancestor: its 11 hours of missed changes arrive
   silently, its own offline edits go up, nothing is resurrected, and he sees a conflict only for a field both sides
   really changed.
7. **Deletes need no tombstones.** A delete is "in my base, gone from my copy", which the three-way merge already
   carries. With no base nothing is ever deleted (`sync.py:1`). A missing cloud record, zone or photo never deletes
   anything on a device.
8. **No push in v1.** Fetch on activation, after every local change, every 20 s in the foreground on the phone, every
   15 s in the Mac app, every 60 s in the bridge. No `aps-environment`, no Push capability, no remote-notification
   background mode.
9. **No server-to-server key.** His web steps are: one container, two App IDs, one schema deploy.

### Rejected, so nobody reopens them
- **One record per watch / wishlist item / box with `CKSyncEngine`** (Arsenal's shape). Arsenal's looks never change
  after they are made; a watch does. Field-level merging would still need the Swift merge, and on top of it we would
  need tombstones, list order (box tab order, photo cover order), and a translator between records and the hub's
  document in the bridge. More moving parts, no gain at 76 KB.
- **Hub talks to iCloud with a server-to-server key.** Those keys reach the public database only. The private
  database from Python needs a user web-auth token that rotates on every request and expires; not something to run
  unattended. Public database for his collection: no.
- **iCloud Drive files** (the hub could read `~/Library/Mobile Documents` directly). Sync timing belongs to the file
  daemon and stalls silently, files can be evicted on the Mac, conflicts arrive as file versions, and a launchd
  Python process needs a privacy grant it cannot ask for. CloudKit calls return errors we can show.
- **Phone keeps Tailscale as an automatic fallback.** Two live links on the phone make the graph a cycle; the same
  conflict would be asked twice, once per link. The hub code path stays in the app (needed before the first join and
  as a manual switch), but only one link is ever active on the phone.
- **Photo cleanup in v1.** Nothing deletes `Photo` records yet. See section 10.

## 2. CloudKit model

Container `iCloud.com.jadenkwek.watchcollection`, private database, one custom zone `Collection`
(`CKRecordZone.ID(zoneName: "Collection", ownerName: CKCurrentUserDefaultName)`). No indexes, no queries, no
subscriptions.

| Record type | Record name | Fields |
|---|---|---|
| `Collection` | `collection` | `format` Int64 (1), `epoch` String (UUID made at creation), `origin` String (`hub`), `revision` String (fingerprint of the body), `document` Asset (canonical JSON), `device` String, `writtenAt` Date |
| `Photo` | `photo/<dir>/<file>` e.g. `photo/wl-abc/3f...jpg`, `photo/_box/empty-black-1a2b3c4d.jpg` | `format` Int64, `dir` String, `file` String, `bytes` Int64, `sha256` String, `data` Asset |
| `Status` | `status-mac`, `status-iphone` | `format` Int64, `name` String, `build` String, `at` Date (last finished cloud pass), `revision` String (what that device holds), `hubAt` Date, `hubRevision` String, `conflicts` Int64, `note` String |

- The record name carries a `photo/` prefix because record names may not start with an underscore and `_box` does.
  The check harness (P6) saves exactly such a name; if CloudKit refuses `/`, the fallback is `|` as the separator,
  changed in one function (`CloudRecords.photoID`).
- The body is an asset, not a field, because a record's fields are capped at 1 MB and wear sessions only grow.
- `document` holds only what syncs: the keys in `sync.py` `TOP`, with `settings` cut to `SETTINGS`
  (`autoImage`, `suggestExclude`, `wrist`). Device-only settings (`autoBackup`, `backupRemote`, `lastBackup`) and
  `headlineStats` never go up. Unknown keys from a newer build are kept (section 3).
- `format` above what a build knows: that device stops its cloud link and says so. Adding fields or JSON keys never
  bumps `format`.
- `Status` is overwritten whole (`savePolicy: .allKeys`), at most once per 5 minutes unless `revision` or `conflicts`
  changed. `status-mac` is written by whichever Mac process holds the lock (GUI or bridge). It replaces the hub's
  `lastRemoteSync` (B3) as the source of "iPhone, 2 min ago" on the Mac and gives the phone "Mac's library checked
  in at 9:41 PM".

## 3. The merge on the device

New `CollectionMerge` (pure Swift, no I/O) is the twin of `sync.py`: `normalize`, `merge` (the `walk` with identity
lists from `COLLECTIONS`, the `ORDERED` rule, string-list union, conflicts with fingerprint ids and `resolutions`),
`clean_boxes` and `clean_cutout`. It works on a raw `JSONValue`, not on `CollectionData`, for one reason:

- **base and local** are `CollectionData` encoded to `JSONValue` (so both have lost any key this build does not know);
- **remote** is the cloud body parsed raw (unknown keys intact);
- so an unknown key is "absent, absent, present" and survives into the output, which is written back raw.

Output rule as in `sync.py:205-210`: start from the remote, lay the merged keys over it, merge `settings` into the
remote's. To install it locally: add this device's `autoBackup`, `backupRemote`, `lastBackup` (or `false`, nil, nil)
into `settings` before decoding, because `CollectionSettings.autoBackup` is not optional (`Models.swift:33`), then
`BoxModel.installing(_, hubSupportsBoxes: true, local:)` as today.

Conflicts keep today's shape (`id, path, local, remote, localDeleted, remoteDeleted`) and today's screen
(`SettingsView.swift:139`, `resolveSyncConflict`). Each conflict is tagged with the link it came from (hub or
iCloud) so the answer goes to that link's `resolutions`. For the cloud link "local" is this device and "remote" is
iCloud. A pass with conflicts writes nothing, exactly as the hub does.

Number rule: compare numbers as `Double` (Python treats `42` and `42.0` as equal). Fingerprints and conflict ids are
this implementation's own; they never need to equal the hub's strings.

## 4. One cloud pass (`CloudLink.pass`)

Per device, strictly one link at a time (the existing `isSyncing` flag), never two passes at once.

1. Gate: container entitlement, account `available`, same account as the book, not paused, not before `notBefore`.
2. Head: `records(for: [collection, status-mac, status-iphone], desiredKeys:` everything but `document`). One request.
   - No zone or no record (and not purged): "no document" (section 6).
   - Same change tag as the book, nothing changed locally since the last pass, no photo work left: up to date.
3. Fetch the full record. Check `sha256(body) == revision`; a mismatch is a failed fetch, retried next pass.
4. Pick the base (section 6), merge. Conflicts: publish them, stop.
5. Photos up: every file the merged document references **that this device holds** and has no "in iCloud" mark:
   ask which exist (`records(for:desiredKeys: [])`, 100 names a call, re-asked before each batch of 10 so two
   devices uploading the same set interleave instead of both sending everything), upload the rest in saves of 5.
   "Already there" is success. The document is not written while any of these is still outstanding.
   A file this device does not hold never blocks the write and is never dropped from the document here. A held
   file that cannot be read (or that CloudKit says it cannot read) counts as gone only if it no longer exists;
   otherwise it holds the document back this pass (docs/icloud-fixes.md D2).
6. Mac only: download the photos the merge introduces (referenced by merged, not by local) before installing. Only
   "not in iCloud" (unknownItem) lets the install go ahead without the photo; it is noted in `cloud-photos.json`. A
   photo whose bytes do not match its record is struck and fetched again on later passes (no sooner than 10
   minutes); after 3 strikes spread over at least an hour it is given up on as unreadable, logged, and the install
   goes ahead (D3). Every damaged photo a pass meets is struck in that pass, so their hours run side by side (R5).
   Any other failure (network, cancelled, a server error, a disk that will not take the file): do not install,
   retry next pass.
7. If merged differs from the remote body: save with `ifServerRecordUnchanged` over the fetched system fields.
   `serverRecordChanged`: back to step 3, at most 3 rounds.
8. If local edits landed meanwhile (`editGeneration` moved): install nothing and go round again (today's guard,
   AS:263). If this round's document write was confirmed (the store answered with the new record and its tag), keep
   its book (epoch, tag, back-off) with its base set to the normalized local collection the round started from: the
   document holds the merge of that collection with what iCloud had, so it is an ancestor of both (R1; a pure push
   is the case where the two are equal). Otherwise drop the result and the book, keeping only `notBefore`,
   `quotaFullAt` and `paused`. A write that may have landed but was not confirmed (its answer lost, cancelled, a
   network failure after sending) is dropped too: until the document is known to hold the merge, that collection's
   own additions would read as deletes in iCloud.
9. Install. Write order is a rule: **`sync.json` (data) first, `cloud.json` (base, tag, epoch) second.** A crash
   between them leaves an older base, which is still a true ancestor and merges cleanly; the reverse order would make
   the next merge read fresh remote changes as local reverts.
10. Phone only: fill missing photos afterwards (section 5). Write `Status` if due.

Per-link bookkeeping in `AppStore`: a `contentVersion` counter bumps when the synced projection of the data changes
(a user edit, or an install by either link; compare `CollectionMerge.fingerprint(normalize(data))`, so an install
that changes nothing does not bump). Each link remembers the version it settled at; its fast path needs that to be
current. This is what makes hub -> Mac -> iCloud and iCloud -> Mac -> hub flow, and why it cannot ping-pong: the
second link's pass finds merged == local, installs nothing, bumps nothing.

Files on each device, beside `sync.json`:
- `cloud.json`: `{format, account, epoch, base: CollectionData?, systemFields, tag, revision, lastSuccess, paused,
  quotaFullAt, notBefore, pendingEpoch, pendingBase}` (the pending pair: section 6). Separate from `sync.json` on
  purpose: an older build ignores it, so a rollback and re-upgrade finds a base that is still a valid ancestor.
- `cloud-photos.json`: names confirmed in iCloud, names iCloud said it does not have (with a time), mismatches. A
  cache: losing it costs one existence check.
- `cloud-status.json`: rewritten each pass for the lead to read (outcome, epoch, revision, photo counts, last error,
  the three `Status` records as fetched). No UI needed to check a Mac.
- `sync-before-icloud-<time>.json`: a copy of `sync.json` made once, before this device's first cloud write or
  install. Never deleted by the app.

## 5. Photos

- Bytes travel unchanged (no recompression): names are content-unique (uuid uploads, `box-<finish>-<sha8>` tiles,
  B6) and the hub refuses the same name with different bytes, so a name must mean the same bytes everywhere.
- A `Photo` record never changes. Saving a name that exists comes back `serverRecordChanged` and is adopted. If the
  server's `sha256` differs from the local file's, log it, keep both as they are, mark `mismatch`, never retry.
- First upload: about 260 referenced files, 147 MB, from the Mac, before the document is created. Resumable (a mark
  per confirmed file). The Mac app shows "Sending 120 of 260 photos to iCloud". Roughly 2 to 20 minutes depending on
  his upload speed. The phone already holds these files (today's sync downloads them all, CS:162), so on joining it
  uploads only photos it added itself.
- A held photo that cannot be read when it is sent is not gone while its file is still there: the document waits
  for it (D2), and the hub exchange stops that pass with a retryable error, dropping and sending nothing, and logs
  the path (R4). Only a file that no longer exists counts as gone.
- Mac downloads (step 6): only "not in iCloud" is installed past. A photo iCloud hands over with bytes that do not
  match its record is retried; after 3 such fetches over at least an hour it is given up on as unreadable and counts
  as not in iCloud for the drop rule below (D3), with a loud log line. A pass strikes every damaged photo it meets,
  then waits once (R5).
- Phone downloads are lazy. `PhotoStore.load` gets a cloud source: local file, else iCloud by record name (verify
  size and `sha256`, write atomically), else a placeholder. After an install, a background fill fetches what is
  still missing, 3 at a time, only on a path that is not expensive or constrained; on cellular only what a screen
  asks for is fetched. A fresh phone shows the collection at once and the pictures fill in.
- Bridge flow, no new code on the hub: a phone photo reaches the Mac from iCloud (step 6), then the existing hub
  exchange uploads it (`CollectionSyncClient.uploads`). A hub tile reaches the Mac by today's download, then step 5
  sends it to iCloud before the document that names it.
- One existing rule is narrowed. The hub exchange drops references to files "gone on both sides" (CS:147-157). While
  the cloud link can answer (link on, account available, not paused, not turned off for this launch, not a newer
  format, and the book holds a document epoch), a reference is dropped only if iCloud has said it does not have that
  file, or the Mac has given up on it as unreadable (`cloud-photos.json`). Otherwise the hub exchange is skipped for
  this tick. When the cloud link cannot answer, the old rule applies, exactly as before iCloud (D4). A phone on the
  hub link first fetches from iCloud the files the exchange would drop. Without this, a photo that simply has not
  come down yet could lose its reference everywhere.

## 6. Who creates the document, and what base a device joins with

"No document" (zone or record missing, not purged):
- **Mac**, and the hub pass of this same tick finished clean with no conflicts and no edits since: create it. New
  `epoch`, `origin: hub`, photos first (section 5), then the body = `normalize(local)`. The new epoch and that body
  are saved in `cloud.json` as `pendingEpoch` and `pendingBase` before the save goes out (D1): a save whose answer is
  lost, or a process that dies after it lands, still finds its base. The next pass whose head shows that epoch takes
  `pendingBase` as its base; any other head (another epoch, no document) clears the pair. The save stores the record
  first and saves the zone only on `zoneNotFound`, never a zone he erased (D6). If the save says a record appeared
  meanwhile, treat it as "document exists".
- **Mac without a clean hub pass**: wait. Status: "iCloud sync starts once this Mac reaches its library."
- **Phone**: never creates. It keeps using the hub link as today.

Document exists, this device has local data, and `cloud.json` has no base for that `epoch`:

| Device | Base for the first merge | Why |
|---|---|---|
| iPhone, never joined before (`cloudJoinedOnce` false), hub checkpoint base present for the current address | **its hub base** (`SyncCheckpoint.base`) | The document was made from the hub right after a hub sync, and the hub's history is one line, so the phone's last hub state is an ancestor of both sides. If the bridge happened to be behind the phone's last hub sync, the phone briefly shows older values for those fields and writes nothing about them (it only ever writes its own edits); the next bridge pass brings them back. Nothing is lost because the phone has no other link to carry a revert anywhere. |
| iPhone otherwise (joined before, epoch changed, no hub base) | none | Union, nothing deleted, differing fields ask. |
| Mac | none, always | The Mac writes through to the hub, so a borrowed base could turn "older in iCloud" into a real revert in the hub. It never borrows. In the normal flow the Mac creates the document and never needs this row. |

A device with no local data installs the remote as it is. That makes a new phone zero-setup: no address to type.

Whatever the base, a round whose write is confirmed and then overtaken by an edit keeps its book with that round's
own collection as base (section 4 step 8, R1). So a merge with no base (the Mac's join, the phone after an epoch
change, the switch below) is never repeated against its own write within a pass, and a delete made during it holds.

After its first successful cloud install the phone sets `cloudJoinedOnce` and its active link becomes iCloud. The
hub address stays stored. Settings (iPhone, bottom of the sync section) keeps one switch, "Sync directly with the
Mac instead", which only flips the active link. It exists so the lead can recover a phone without shipping a build
if Production CloudKit misbehaves. The first pass of the link that becomes active after a flip, either way, merges
with no base: union, nothing deleted, differing fields ask (D5). Its base may be far behind or ahead of the other
link's, and a three-way merge would read the gap as deletes and reverts. On the iCloud side the no-base merge holds
only until a round of that pass confirms a write; later rounds use the book that round kept (R2). The flag itself is
cleared when the link settles.

## 7. What he sees

No new choices. Copy for the existing sync line and tonight's notice (which must speak for the active link):

- iPhone, joined: "Syncs with your Mac through iCloud." then the hub mode's label and value rows: Status "Through
  iCloud", Last synced "2 min ago", Mac's library "Checked in 9:41 PM" (from `status-mac.hubAt`; plain information,
  no warning: the MacBook sleeping overnight is normal). With "Sync directly with the Mac instead" on, Settings shows
  the hub's rows only, never an iCloud sentence frozen where the last cloud pass left it.
- Mac: "iPhone, 2 min ago" now reads `status-iphone.at`.
- Sending: "Sending 120 of 260 photos to iCloud."
- Signed out: "Sign in to iCloud to sync with your Mac." (banner)
- Full: "iCloud storage is full, so changes stay on this iPhone." (banner)
- A choice is waiting on the other device: "1 change needs your choice on your Mac." (banner; from `conflicts`)
- Newer format: "Update Watch Collection on this iPhone to keep syncing." (banner)
- Erased: "The iCloud copy was erased. Nothing on this Mac was removed." with one button on the Mac, "Sync through
  iCloud again". On the phone: "...Open Watch Collection on your Mac to start iCloud sync again."
- A joined phone finds no iCloud copy: "The iCloud copy is missing. Open Watch Collection on your Mac to start iCloud
  sync again." (docs/icloud-fixes.md D10)
- Mac sidebar: the headline is the worse of the hub and iCloud states, with the hub's own line kept below it when
  iCloud takes it (docs/icloud-fixes.md D11). At once, amber dot: "iCloud paused" (erased), "iCloud sync stopped"
  (newer format), "Signed out of iCloud", "iCloud is full", "Choice waiting" (the iPhone's). Only once the cloud link
  has not settled for 3 minutes: "Can't reach iCloud" (offline) or "iCloud sync did not finish" (failed, throttled),
  with "Last synced through iCloud 3 hr ago. It will keep trying." A tie goes to the hub.

## 8. Failures

| Event | Rule |
|---|---|
| No account, restricted, could not determine | Cloud link sleeps (could not determine is a quiet network failure, D12). Nothing local is removed, ever. Mac keeps syncing with the hub, dropping gone photos by the old rule (D4). |
| Account switched (`userRecordID` differs from `cloud.json`) | Clear base, tag, epoch and photo marks; keep all local data. Next pass is a join with no base (Mac) or per the table (phone). |
| Signed out, then the same account again | Book still valid; carry on. |
| `quotaExceeded` | `quotaFullAt = now`, retry no sooner than 10 minutes, banner. Edits stay local and, on the Mac, still reach the hub. |
| `userDeletedZone` (he erased the app's iCloud data in Settings) | `paused = erased`. Do not re-upload on our own (Apple's rule, Arsenal's rule). Local and hub untouched. The Mac button clears it and the Mac creates a new document with a new epoch. A paused phone keeps reading the head only, and resumes when it sees a new epoch (join with no base). |
| `zoneNotFound` | "No document": the Mac creates it (new epoch) after a clean hub pass. The creating save stores the record first and saves the zone only on `zoneNotFound`; `userDeletedZone` there is the erase above (D6). |
| `serverRecordChanged` on the document | Re-fetch, re-merge, 3 rounds, then next tick. |
| Document save's answer lost (timeout, `serverResponseLost`), cancelled, or a network failure after sending | Not a confirmed write: it may have landed. Nothing installed; the next pass's head decides. A creation finds its `pendingEpoch` and `pendingBase` on disk and adopts them if the head shows that epoch (D1). If an edit overtook the round, its result and book are dropped, keeping `notBefore`, `quotaFullAt` and `paused` (R1). |
| An edit lands while a pass runs | Nothing installed; go round again. After a confirmed write the round's book is kept with the round's own collection as base (R1), and a no-base pass (D5) uses that book from then on (R2). |
| `unknownItem` for a photo | Not an error. Never deletes anything. Whoever holds the file and sees it referenced uploads it. |
| A held photo cannot be read (also `assetFileNotFound` while the file is still there) | Not gone while the file exists: the document waits this pass (D2), and the hub exchange stops with a retryable error, sending and dropping nothing, and logs the path (R4). |
| Photo bytes do not match their record (Mac download) | Retried no sooner than 10 minutes on; the install waits. After 3 such fetches over at least an hour: given up on as unreadable, logged, and installed past; it then counts as not in iCloud for the drop rule (D3). Every damaged photo met in a pass is struck in that pass (R5). Any other download failure waits for the next pass. |
| `requestRateLimited`, `zoneBusy`, `serviceUnavailable` | `notBefore = now + retryAfter`. |
| Network errors | Quiet; next tick. The staleness notice covers a long gap. |
| `assetFileNotFound` | Drop that photo's mark, next pass re-checks the file (a file still there: the held-photo row above). |
| `limitExceeded` | Halve the batch. |
| `missingEntitlement`, `badContainer`, `permissionFailure` | Cloud link off for this launch, one loud log line. A build problem, not his. |
| `format` too new | Cloud link off on that device, banner. |
| Body fails its `sha256` or does not decode | Treat as a failed fetch. Never install, never overwrite. |

## 9. Migration and safety

State today: Mac == hub (B5); the phone holds a full copy last synced 10:22 AM plus whatever he edited since; its
address and copy could not be read from here.

Order, with backups before any cloud write:
1. Lead, before installing the new Mac build (plain copies, nothing is moved):
   `~/Offload/watch-collection/backups/pre-icloud-<date>/` gets the hub's `data/watches.json`, `data/sync-history/`,
   `data/photos/` (147 MB) and the Mac app's `Application Support` folder from its container (149 MB).
2. Each device, in code, before its first cloud write or install: `sync-before-icloud-<time>.json`, and
   `LocalBackup.mirrorJSON` once regardless of the `autoBackup` setting.
3. Mac build installed (Release, Production). First tick: hub pass clean, photos go up, document created.
4. TestFlight build reaches the phone. On first open with a network: join with its hub base. Missed changes come
   down, its own edits go up, real double edits ask. Its link becomes iCloud.
5. If the phone's build arrives before step 3 finishes: there is no document, the phone stays on the hub link,
   nothing changes for him.

Why nothing can be lost: no rule in this design removes local data or a local file; the cloud never receives a
document before its photos; a device writes to iCloud only merged output and only when nobody wrote in between; every
hub write that results still gets the hub's own sync-history snapshot (server.py:753).

Rollback: first `tools/bridge/install.sh remove` (a build from before the bridge ignores `-WCBridge` and would open
its whole window from launchd every minute; install.sh also refuses to install one), then reinstall the previous Mac
build and the previous TestFlight build. They ignore `cloud.json`, the hub path
is untouched, the cloud data just sits there. Coming forward again needs no reset.

Debug builds can never touch his data: Debug is pinned to the Development environment, and in DEBUG the cloud link
is off unless the run was given `-WCDataRoot <folder>` (which also moves `sync.json` and the photo folder there) or
`-WCCloudKitCheck`. The one sanctioned exception to the Development pin is the P6 check's Production run (section 13
C), a Debug build with `WC_CLOUDKIT_ENV=Production`: it opens no collection and never the `Collection` zone.

## 10. Later, not in this job
- **Photo cleanup.** Rule when built: Mac only, at most daily, list the zone with no assets, delete a `Photo` record
  only after it has gone unreferenced (by the cloud document, the Mac's copy and the hub base) for 30 days running.
  Safe by construction, because a missing photo record never deletes anything and any holder re-uploads a referenced
  file. Each full tile re-render leaves tens of MB behind until then.
- **Push** (a database subscription) to cut the 20 s wait when both apps are open.
- **Answering a Mac-side conflict from the phone.**

## 11. Build parts

Worktree: a new one, `~/watch-collection-icloud`, branch `icloud-sync`, cut after tonight's notice is merged (it
edits `SyncHealth.swift` / `SyncNotice.swift`, which P4 changes). One commit per part. Unit tests live in
`ios/UnitTests` (iOS simulator target) and never touch CloudKit: the real store is behind a protocol and a gate.

Order: P0 scout -> P1, P2, P3, P6 (no account needed; P1 first, P2 and P3 can overlap) -> P4 -> P5 -> owner's
sitting 1 -> P7 -> P6 run in Development -> owner's sitting 2 -> P6 run in Production -> rehearsal (section 13 B) ->
P8 review -> P9 rollout. Everything through P6 is built before he is asked for anything, so both web visits fit in
one hour and one sign-in.

### P0. Facts to confirm (scout, haiku)
- Does `server.py` take a port and a data folder from the environment or arguments (for a throwaway hub in the
  rehearsal)? If not, name the constants to override.
- What `ios/fastlane/Fastfile` does about provisioning profiles (Arsenal's forces a fresh one).
- Which configuration the installed `/Applications/Watch Collection.app` was built with and how it gets there.
- Every caller of `SyncHealth.evaluate`, `SyncNotice`, `status.lastPhoneSync`, `hubSupportsBoxes`,
  `canOfferStartingLayout`, `PhotoStore.shared.load`. Two scouts searching differently, compared.
Done: a short list with path:line for each.

### P1. The merge twin (builder, opus xhigh)
Files: new `ios/Sources/JSONValue.swift`, `ios/Sources/CollectionMerge.swift`; new `tools/merge_vectors.py`;
new `ios/UnitTests/CollectionMergeTests.swift`, `ios/UnitTests/Fixtures/merge-vectors.json`.

```swift
indirect enum JSONValue: Codable, Equatable, Sendable { case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue]) }
extension JSONValue {
    init<T: Encodable>(encoding value: T) throws
    func decoded<T: Decodable>(_ type: T.Type) throws -> T
    var canonicalData: Data          // sorted keys, compact, whole numbers without a fraction
}
enum CollectionMerge {
    struct Conflict: Equatable { var id: String; var path: [String]; var local: JSONValue?; var remote: JSONValue?; var localDeleted: Bool; var remoteDeleted: Bool }
    static func normalize(_ document: JSONValue) -> JSONValue
    static func cleanBoxes(_ document: JSONValue) -> JSONValue
    static func merge(base: JSONValue?, local: JSONValue, remote: JSONValue, resolutions: [String: String]) -> (output: JSONValue, conflicts: [Conflict])
    static func fingerprint(_ value: JSONValue) -> String
}
```
Follow `sync.py` line for line, including its edges (an empty list takes the string-list branch; the baseless boxes
rule at `sync.py:141-146`; key order of emitted conflicts). `JSONValue` may replace `SyncValue` if the strings its
`description` produces stay identical.

`tools/merge_vectors.py` imports the repo's `sync.py`, runs a fixed set of hand-written cases plus 300 seeded random
ones, and writes `{base, local, remote, resolveByPath, output, conflicts}`. Resolutions are given by path, so each
implementation uses its own ids.

Tests: every vector gives the same output and the same conflicts (path, sides, deleted flags) as Python; then by
name: edit on each side of different fields; same field both sides; delete against edit, both directions; no base
never deletes; boxes with no base; box reorder on one side; photo list union and cover order; unknown key in a
watch, a wishlist item and at top level survives when base and local lack it; `42` equals `42.0`; a watch in two
boxes after a merge is cleaned; normalize drops nulls and empty `wearSessions`.
Done: all green on the iPhone simulator; no file outside the list touched.

### P2. Cloud link logic against a fake (builder)
Files: new `ios/Sources/CloudSync.swift` (types, protocol, `CloudBook`, `CloudLink`), `ios/Sources/CloudPhotos.swift`
(marks, push, fill); new `ios/UnitTests/CloudLinkTests.swift`, `ios/UnitTests/FakeCloudStore.swift`.

```swift
struct CloudHead: Equatable { var tag: String; var revision: String; var epoch: String; var format: Int }
struct CloudDocument { var head: CloudHead; var origin: String; var body: Data; var systemFields: Data; var device: String; var writtenAt: Date }
struct CloudStatus: Codable, Equatable { var name, build, revision: String; var at: Date; var hubAt: Date?; var hubRevision: String?; var conflicts: Int; var note: String }
enum CloudFailure: Error, Equatable { case noAccount, changed, purged, quotaFull, retryAfter(TimeInterval), network, misconfigured(String), other(String) }

protocol CloudStore: Sendable {
    func account() async throws -> String                                   // user record name
    func head() async throws -> (document: CloudHead?, statuses: [String: CloudStatus])   // nil document = none
    func document() async throws -> CloudDocument?
    func write(body: Data, revision: String, epoch: String, origin: String, device: String, over systemFields: Data?) async throws -> CloudDocument  // nil = create (record first, zone only on zoneNotFound, D6); throws .changed
    func photosPresent(_ names: [String]) async throws -> Set<String>
    func uploadPhoto(_ name: String, file: URL, sha256: String, bytes: Int) async throws -> Bool   // false = already there with other bytes
    func downloadPhoto(_ name: String, to file: URL) async throws -> Bool                           // false = not in iCloud
    func writeStatus(_ key: String, _ status: CloudStatus) async throws
}
protocol PhotoFiles: Sendable { func url(_ name: String) -> URL?; func exists(_ name: String) -> Bool }   // "dir/file"

enum CloudRole { case phone, mac }
enum CloudOutcome { case upToDate, installed(CollectionData, wroteCloud: Bool), conflicts([CollectionMerge.Conflict]),
                    waiting(CloudWait) }   // noAccount, noDocument, needsHubFirst, erased, full, newerFormat, offline, sendingPhotos(done: Int, of: Int)
struct CloudInput { var local: CollectionData?; var book: CloudBook; var hubBase: CollectionData?; var hubSettledNow: Bool
                    var joinedBefore: Bool; var resolutions: [String: String]; var changedSinceLastPass: Bool }
actor CloudLink {
    init(store: CloudStore, files: PhotoFiles, marks: CloudPhotoMarks, role: CloudRole, device: String, now: @escaping @Sendable () -> Date)
    func pass(_ input: CloudInput) async -> (outcome: CloudOutcome, book: CloudBook)
    func fillPhotos(for data: CollectionData, allowBulk: Bool) async
}
```
`CloudLink` holds sections 4, 5, 6 and 8 and nothing about `AppStore` or disk layout beyond `PhotoFiles`.

`FakeCloudStore`: records by name with a change tag, photo bytes copied into its own folder, switches for offline,
quota full, erased, no account, another account, rate limit, and a hook that lets a second device write between
`document()` and `write()`.

Tests (two or three `CloudLink`s on one fake, temp folders, injected clock):
1. Mac creates the document only when `hubSettledNow`; photos are all present before the document appears.
2. Phone never creates; with no document it reports `noDocument`.
3. Stale phone joins with its hub base: Mac-side adds, edits and deletes arrive, phone's own edits go up, deleted
   items are not resurrected, a field changed on both asks once.
4. Same join when iCloud is behind the phone's hub base: the phone writes nothing about those fields; after the Mac
   catches up the phone converges to the hub's values.
5. Mac join with a document present and no base uses no base; a hub-newer value is never silently replaced.
6. Epoch change: the phone merges with no base; nothing deleted.
7. Round trip both ways; second pass on each side is `upToDate` and writes nothing (no ping-pong, counted writes).
8. A competing write between fetch and save: re-merge, both edits kept, one final write.
9. Conflict: nothing written; after a resolution the chosen value is written and the other device takes it.
10. Photos: document blocked until held files are up; "already there" adopted; a file not held does not block and is
    not dropped; two devices uploading the same set send each file once (count uploads).
11. Mac install waits on a photo download that fails with a network error and proceeds on "not in iCloud".
12. Phone installs first and fills later; `allowBulk: false` fetches nothing in bulk.
13. Quota: no retry inside 10 minutes; after it clears, the edit goes up.
14. Erased: paused, nothing uploaded; a new epoch resumes the phone; local data intact throughout.
15. Account switch clears the book and marks, keeps data; same account back keeps the book.
16. Unknown keys written by a "newer" device survive a pass by an older one.
17. Body with a wrong `sha256`: no install, no write.
18. `format` 2: `newerFormat`, nothing written.
19. Crash order: data saved but book not saved, then a pass: converges, nothing reverted.
Done: all green; `CloudSync.swift` does not import CloudKit.

### P3. The real store (builder)
Files: new `ios/Sources/CloudKitStore.swift`, `ios/Sources/CloudRecords.swift`; new
`ios/UnitTests/CloudRecordsTests.swift`.
- `CloudKitStore: CloudStore` with `static let containerID`, `zoneID`, and `static func live() -> CloudKitStore?`:
  nil on a simulator, under XCTest, with `-WCNoCloud`, without the container entitlement (the `SecTask` check from
  Arsenal `LooksCloudKit.swift:65-72`, on both platforms where available), without the `WC_CLOUDKIT` compile flag,
  and in DEBUG unless `-WCDataRoot` is set. Nothing constructs `CKContainer` before this gate (a missing entitlement
  ends the process).
- Calls: `accountStatus`, `userRecordID`, `records(for:desiredKeys:)`, `record(for:)`,
  `modifyRecords(saving:deleting:savePolicy:atomically:)` with `.ifServerRecordUnchanged` for `Collection` and
  `Photo`, `.allKeys` for `Status`, `modifyRecordZones` on create. `qualityOfService = .userInitiated`; request
  timeout 30 s, 120 s for photo calls. Photo assets point at the file in the photo folder; the document asset at a
  temp file removed after the call. Downloads copy out of the asset's URL before returning.
- `enum CloudRecords` (pure): `collectionRecord`, `photoRecord`, `statusRecord`, the three readers, `photoID(_:)`,
  `failure(_ error: Error) -> CloudFailure` (unwraps `partialFailure`), system-fields archive and restore.
- `os.Logger(subsystem: "com.jadenkwek.watchcollection", category: "cloud-sync")`: one line per call with counts,
  names and error codes, never contents.
Tests: each record type round-trips through a real `CKRecord` and `CKAsset` offline with every field set; a photo
name with `_box` and with `wl-`; hostile names (`../x`, `a/b/c`) refused by the same check `PhotoStore` uses; every
`CKError` code in section 8 maps as the table says.
Done: green; grep shows `CKContainer(` only inside `CloudKitStore` and the check harness.

### P4. App wiring (builder; the largest part)
Files: `ios/Sources/AppStore.swift`, `CollectionSync.swift`, `PhotoStore.swift`, `SyncHealth.swift`,
`SyncNotice.swift`, `SettingsView.swift`, `WatchCollectionApp.swift`, `ios/Mac/MacApp.swift`; tests
`ios/UnitTests/SyncHealthTests.swift` (extend), new `ios/UnitTests/SyncRoutingTests.swift`.
- `AppStore`: `contentVersion` and per-link settle state; the tick runs hub then cloud on the Mac, and exactly one
  link on the phone (`activeLink`: hub until `cloudJoinedOnce`, then iCloud, unless the manual switch is on).
  `syncNow` keeps its behaviour for the hub link. New `cloudPass()` builds `CloudInput`, runs the link, and on
  `.installed` does today's install steps (device-only settings kept, `BoxModel.installing`, publish, cache, backup
  mirror) with the write order of section 4 step 9. `hubSettledNow` is true only when the hub pass of this tick
  returned success and no edit has happened since.
- `resolveSyncConflict` routes by the conflict's link tag. `canOfferStartingLayout` also accepts a finished cloud
  pass. With no data and no address, the empty state waits for iCloud instead of asking for an address.
- The narrowed drop rule in `CollectionSyncClient.exchange` (section 5).
- `PhotoStore.load`: cloud source after the local file; hub URL only when the hub link is the active one.
- Phone cadence: on activation, after a commit, every 20 s while active; the existing BGAppRefresh task runs one
  document-only pass. Mac: inside the existing 15 s loop.
- `SyncHealth` and the notice take the active link; copy from section 7. `lastPhoneSync` reads `status-iphone.at`.
- DEBUG: `-WCDataRoot <folder>` moves `SyncDisk.url`, the photo root, the cloud files and the cache under that
  folder; `-WCRole phone|mac` overrides the role; `-WCHub <address>` overrides the sync address for that run.
Tests: routing (which link runs for each combination of joined, switch, platform); `contentVersion` bumps only on a
projection change; an install from the hub link makes the cloud link due and the reverse; conflicts from the two
links resolve to the right link; `SyncHealth` cases for each row of section 7.
Done: full unit suite green; the app on both named simulators behaves as before (the gate returns nil there);
screenshots of Settings with each status forced by a DEBUG flag `-WCCloudStatus <case>`.

### P5. Headless bridge (builder)
Files: `ios/Mac/MacApp.swift` (entry), new `ios/Mac/Bridge.swift`, new `ios/Sources/SyncLock.swift`, new
`tools/bridge/com.jaden.watch-collection-bridge.plist`, `tools/bridge/install.sh`; test
`ios/UnitTests/SyncLockTests.swift`.
- Entry: `@main enum Entry` decides before SwiftUI starts: `-WCCloudKitCheck` (DEBUG) -> check; `-WCBridge` ->
  `Bridge.runAndExit()`; else `WatchCollectionMacApp.main()`. Same pattern as Arsenal `CloudKitCheck.runAndExit`.
- `SyncLock`: an exclusive `flock` on `Application Support/WatchCollection/sync.lock`. The GUI takes it before it
  reads `sync.json` and holds it for life; while waiting it drops a `sync.lock.want` file. It never syncs without it
  (docs/icloud-fixes.md D9): the window opens at once and the collection opens once the lock is held, asking again
  every 0.5 s; only a lock file that cannot be opened at all lets it carry on without (logged). The bridge tries without
  blocking and exits 0 if it is taken; between network calls it checks for `want` and exits early.
- `Bridge`: no `NSApplication` at all (docs/icloud-fixes.md D7: one checks the process in with LaunchServices as a
  running copy of the app, and opening the app during a tick then fails with -600), so no window and no Dock icon; one tick (hub pass, cloud pass, hub pass again if the cloud pass
  installed), `Status` write, `cloud-status.json`, exit 0. Watchdog exits at 50 s whatever is running; every step is
  resumable. Conflicts are not answerable here: they are counted into `status-mac.conflicts` and wait for a screen.
- LaunchAgent: `ProgramArguments` = the app's binary in `/Applications/Watch Collection.app/Contents/MacOS/` with
  `-WCBridge 1`; `StartInterval` 60; `RunAtLoad`; `WatchPaths` = the hub's `data` folder (the folder, not
  `watches.json`, because the hub replaces the file by rename); `ThrottleInterval` 10; `ProcessType` Background;
  logs to `~/Library/Logs/watch-collection-bridge.log`. `install.sh` refuses a binary without the marker `WCBridgeEntry-v1` that `Entry` carries (found with
  `grep -a`, never by running it; `--dry-run` checks and prints the plist only), writes it to `~/Library/LaunchAgents` and
  bootstraps it; `install.sh remove` undoes that.
Tests: lock taken twice in one process fails the second time without blocking; released on close; the `want` file
makes a holder that polls it give up.
Done: with the GUI closed, a real launchd run in the rehearsal (section 13 B) completes a tick and exits 0; with the
GUI open it exits at once.

### P6. CloudKit check (builder)
File: new `ios/Mac/CloudKitCheck.swift` (DEBUG, Mac), modelled on Arsenal's.
`-WCCloudKitCheck <folder in the app's container>`: no window, no collection, never the `Collection` zone. Account
status; save zone `CollectionCheck`; through `CloudRecords`, save a `Collection` (every field, a 1 KB body), a
`Photo` named `photo/_box/empty-black-0123abcd.jpg` (16 px JPEG), `status-mac` and `status-iphone` with every field
set (`hubAt`, `hubRevision`, `note` too); fetch each back by id and compare fields and asset bytes; head fetch with
desired keys returns no asset; `photosPresent` for one real and one made-up name returns exactly the real one; a
second save of the `Collection` from stale system fields comes back `.changed`; delete the zone; write
`cloudkit-check.json` (`environment`, `account`, `saved`, `roundTrip`, `conflictSeen`, `error`); exit 0 or 1 inside
60 s.
Done: builds in Debug. Later: `roundTrip: true` and `conflictSeen: true` in Development (this run creates the schema,
every field of all three types), then in Production after the deploy.

### P7. Entitlements and signing (builder; after sitting 1)
File: `ios/project.yml` (and the generated entitlement files).
- Both targets: `SWIFT_ACTIVE_COMPILATION_CONDITIONS` gains `WC_CLOUDKIT`.
- iOS (it has no entitlements file today): `entitlements.path: WatchCollection.entitlements` with
  `com.apple.developer.icloud-container-identifiers: [iCloud.com.jadenkwek.watchcollection]`,
  `com.apple.developer.icloud-services: [CloudKit]`. No environment key (TestFlight is Production). No
  `aps-environment`. `UIBackgroundModes` stays `fetch` only.
- Mac: the same two keys added to the existing three, plus
  `com.apple.developer.icloud-container-environment: $(WC_CLOUDKIT_ENV)`; `WC_CLOUDKIT_ENV` is `Production` in
  Release and `Development` in Debug.
- Build the Mac app with `-allowProvisioningUpdates` and the ASC key flags (map A5).
Done: `codesign -d --entitlements -` on the Release Mac app shows the container, CloudKit, Production, sandbox and
network client; the embedded profile lists the container and allows Production; the iOS archive's entitlements show
the container. If the Mac profile does not allow Production, stop and tell the lead.

### P8. Review (reviewer, fable high; once, on the whole diff, before anything ships)
Give it this plan, `sync.py`, and the diff in three sittings of about 2,000 lines: (1) P1 with the vectors script,
(2) P2 and P3, (3) P4, P5, P6. Ask specifically for: any path that removes local data or a photo reference; any
write to iCloud not guarded by `ifServerRecordUnchanged`; any place a base newer than the data can be saved; any
divergence from `sync.py`; anything that constructs `CKContainer` before the gate. Builder fixes; the lead reads a
fix diff under 200 lines itself.

### P9. Rollout (lead)
Section 9 steps 1 to 4, then section 13 C and D. Installing the LaunchAgent is part of it.

## 12. His web steps (one ask, one sign-in)

Ask once: "Sign in to developer.apple.com in Safari (the 2FA code is yours). Codex does the rest in two short
visits." Everything through P6 is built first so the two visits are under an hour apart.

Visit 1, developer.apple.com, Certificates, Identifiers & Profiles:
1. Identifiers, filter iCloud Containers, +, description `Watch Collection`, identifier
   `iCloud.com.jadenkwek.watchcollection`, Register.
2. Identifiers, App IDs, `com.jadenkwek.watchcollection`: tick iCloud, choose "Include CloudKit support", Configure,
   tick `iCloud.com.jadenkwek.watchcollection`, Continue, Save, confirm.
3. The same for `com.jadenkwek.watchcollection.mac`.

Then the builder: P7, then the P6 run in Development.

Visit 2, icloud.developer.apple.com, CloudKit Database, container `iCloud.com.jadenkwek.watchcollection`: Deploy
Schema Changes; confirm `Collection` (7 fields), `Photo` (6), `Status` (9) are listed; Deploy.

Not needed: Push Notifications, any key, any server-to-server key, App Store Connect changes. If the Apple session
has expired by visit 2, that is a second sign-in; nothing else is his.

## 13. Proof

A. Unit tests: P1 to P5 suites green on the iPhone simulator; the vectors prove the Swift merge equals `sync.py`.

B. Rehearsal on real CloudKit with none of his data (builder, after visit 1; Development environment, which is a
separate database from Production): a throwaway hub on a spare port over a copy of `data/` (P0 says how), and two
data roots in the Mac app's container, one seeded from a current copy (`-WCRole mac -WCHub <throwaway>`), one from a
copy made stale by hand: a wishlist item removed, a note edited, a photo added (`-WCRole phone`). Run the debug Mac
build headless against each in turn and check, from `cloud-status.json` and the two `sync.json` files:
1. Mac creates the document after its photos; counts match.
2. "Phone" joins: gets the Mac-side changes, its note edit and photo reach the throwaway hub after the next Mac
   tick (the hub's `watches.json`, its photo folder, and a new sync-history file).
3. A wishlist add through the throwaway hub's `/api/wishlist` reaches the "phone" root after one Mac tick and one
   phone tick.
4. The same field edited on both: one conflict, nothing written until resolved.
5. One tick driven by the real LaunchAgent pointed at the debug build and the Mac root: exits 0, did the work.
6. All three fingerprints equal at the end: throwaway hub projection, cloud `revision`, both roots.

C. Production, Mac (lead): P6 check `roundTrip: true` in Production. Debug is pinned to Development, so this run
overrides it on the command line (section 9's one exception), signed as usual (the check needs the container):
```
cd ios && xcodebuild -project WatchCollection.xcodeproj -scheme WatchCollectionMac -configuration Debug \
  -derivedDataPath ~/Offload/watch-collection/derived/cloudkit-check-production WC_CLOUDKIT_ENV=Production build
"$HOME/Offload/watch-collection/derived/cloudkit-check-production/Build/Products/Debug/Watch Collection.app/Contents/MacOS/Watch Collection" \
  -WCCloudKitCheck "$HOME/Library/Containers/com.jadenkwek.watchcollection.mac/Data/cloudkit-check-production"
```
Its `cloudkit-check.json` must say `"environment" : "Production"` (read from the signed entitlement) as well as
`roundTrip` and `conflictSeen` true. A run cut off by its watchdog leaves `CollectionCheck` behind; the next run
deletes it first. Backups made. Install the Release build, open
it once. Read `cloud-status.json` and the `cloud-sync` log: photos N of N, document created, epoch set,
`revision` equal to the fingerprint of the hub's projection. Quit the app; install the LaunchAgent; add a test
wishlist item through the hub; within 70 s `cloud-status.json` shows a new `revision` written by the bridge.
Remove the test item the same way.

D. Production, iPhone on TestFlight, Tailscale off: he opens the app once. No screen needs reading: on the Mac,
`status-iphone.at` is fresh and its `revision` equals the cloud's and the hub projection's. Then both directions
without the Mac app open: a hub wishlist add shows on the phone within about 80 s if it is open (at once when
opened); an edit he makes on the phone appears in the hub's `watches.json` with a new sync-history file within
about 80 s. What he should see himself: the wishlist on the phone matches the Mac, and Settings says "Syncs with
your Mac through iCloud."

## 14. Risks and what could not be confirmed
1. **The phone's own state** was not readable. If its hub base is missing (address changed, never synced), it joins
   with no base: safe, but every differing field asks. Its `sync-before-icloud` copy and the hub backups cover it.
2. **Record names with `/`**: believed fine, proven by P6 before anything depends on it; one-line fallback.
3. **A sandboxed, CloudKit-entitled app run headless by launchd**: Arsenal proves headless from a shell, not from
   launchd. Rehearsal step 5 proves it. Fallback if it fails: the Mac app registers as a login item and keeps
   running with no window after its window closes.
4. **The Mac team profile allowing Production** for this new container: proven for Arsenal's Release build on the
   same team (A4); P7 checks before anything depends on it.
5. **Schema deploys that miss a field**: the Production run of P6 sets every field of every type.
6. **Server-to-server keys and the private database**: stated from Apple's documentation as I know it (public
   database only); nothing in the design depends on it being otherwise.
7. **The first upload** holds back the first document for as long as 147 MB takes on his line. It is one time and
   resumable; the phone keeps its hub path until it is done.
8. **A conflict raised in the headless bridge** waits for a screen. The phone says so, but it can only be answered on
   the Mac in v1.
9. **A photo that takes more than about 45 s to send cannot finish in the bridge** (C2#11, unproven): the 50 s
   watchdog ends every tick in the middle of it (the deadline is checked only between photos) and the next tick starts
   it again, so the document waits on that photo until the app is opened, which has no watchdog. The largest hub photo
   today is 3.1 MB, so this needs an uplink below about 0.6 Mbps. Other photos' progress is kept (`photosPresent` asks
   iCloud first).
