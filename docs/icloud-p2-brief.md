You are building part P2 of the Watch Collection app's iCloud sync, in the worktree `~/watch-collection-icloud`
(branch `icloud-sync`). The design is `~/watch-collection-icloud/docs/icloud-plan.md`: read sections 1 to 9 whole,
then P2 in section 11, which is your spec. `docs/icloud-p0.md` has the caller map.

## What is already there (committed; do not change their behaviour)
- P1, the merge twin: `ios/Sources/JSONValue.swift`, `ios/Sources/CollectionMerge.swift` (twin of `sync.py`, proven
  equal on generated vectors). Use `CollectionMerge.normalize/merge/cleanBoxes/fingerprint` and `JSONValue`; do not
  write another merge.
- P3, the real store: `ios/Sources/CloudKitStore.swift`, `ios/Sources/CloudRecords.swift`. You never construct it;
  your tests use a fake. Its contract, which your link must rely on exactly:
  - `document()` returns nil when the zone or record is missing; an unreadable record throws `.other`.
  - `write(... over: nil)` creates (makes the zone first). Saving over a record or zone that has gone throws
    `.changed`, so the link re-fetches and finds no document.
  - `uploadPhoto` returns false when a photo of that name exists with other bytes ("mismatch", never retry); it
    creates the zone itself if missing. A missing local file throws `.photoFileMissing`: drop that photo's mark.
  - `downloadPhoto` returns false for "not in iCloud"; it verifies size and sha256 and writes atomically.
  - `photosPresent` answers by name; batching and `limitExceeded` halving are inside the store.
  - Errors reach you as `CloudFailure` (`ios/Sources/CloudSync.swift`).
- `ios/Sources/CloudSync.swift` already holds `CloudHead`, `CloudDocument`, `CloudStatus`, `CloudFailure`,
  `CloudStore`, `PhotoFiles`. Add `CloudBook`, `CloudRole`, `CloudOutcome`, `CloudWait`, `CloudInput`, `CloudLink`
  to it as the plan's P2 sketch shows; do not change the existing types or the protocol (if you must, stop and say
  why in your report).

## First
Run the unit suite once before you change anything. P1 and P3 were built apart and this is their first build
together: expect 246 tests, all green. If it does not build or a test fails, stop and report; do not fix P1 or P3.

## Build
- `ios/Sources/CloudSync.swift` (additions), new `ios/Sources/CloudPhotos.swift` (marks, push, fill), new
  `ios/UnitTests/CloudLinkTests.swift`, new `ios/UnitTests/FakeCloudStore.swift`.
- `CloudLink` holds sections 4, 5, 6 and 8 and knows nothing about `AppStore` or the disk layout beyond `PhotoFiles`
  and the book/marks it is handed and returns. It does not import CloudKit.
- All 19 tests listed under P2, plus any you need. Two or three `CloudLink`s on one fake, temp folders, injected
  clock. Count writes and uploads where the test says so.
- Section 4 step 9's write order (data before book) is the caller's job in P4, but `pass` must return the book that
  goes with the installed data so the caller can save them in that order; test 19 covers a crash between them.

## Test and build commands
```
cd ~/watch-collection-icloud/ios && xcodegen generate >/dev/null && U=$(xcrun simctl create wc-p2-test com.apple.CoreSimulator.SimDeviceType.iPhone-17 com.apple.CoreSimulator.SimRuntime.iOS-27-2) && xcodebuild test -project WatchCollection.xcodeproj -scheme WatchCollection -destination id=$U -derivedDataPath ~/Offload/watch-collection/derived/icloud/unit -only-testing:WatchCollectionTests 2>&1 | grep -E "error:|Executed [0-9]+ tests.*seconds\)$|TEST (SUCCEEDED|FAILED)|failed \(" | tail -20; xcrun simctl delete $U && echo "sim deleted"
```
```
cd ~/watch-collection-icloud/ios && xcodebuild -project WatchCollection.xcodeproj -scheme WatchCollectionMac -destination platform=macOS -derivedDataPath ~/Offload/watch-collection/derived/icloud/mac -configuration Debug PRODUCT_BUNDLE_IDENTIFIER=com.jadenkwek.watchcollection.mac.icloudcheck CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```

## Rules
- No `git add`, `git commit` or any git write; the lead commits.
- Touch only the files named above.
- Never touch the simulators named Arsenal Duo, Dentiza Duo, iPhone Duo or Arc Records; use only your throwaway one
  and delete it.
- Never launch anything against the real hub on port 8931. Nothing here talks to the network.
- No emojis or em-dashes in comments.

## Report (short)
Files and line counts; test count and result; the Mac build result; every place you departed from the plan or
chose something it left open, with the reason; and the three spots you would want a reviewer to read first.
