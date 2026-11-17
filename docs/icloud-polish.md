# Polish queued for the P8 fix round (lead, from the P4 screenshots)

1. iPhone Settings, iCloud joined: "Last synced 2 min ago" and "Mac's library checked in 9:41 PM" are plain small-text
   rows, while the hub mode uses label/value rows ("Status / Up to date", "Last synced / <date>"). Use the same
   label/value rows in iCloud mode: Status / "Through iCloud"; Last synced / "2 min ago"; Mac's library / "Checked in
   9:41 PM". Keep the section 7 sentence "Syncs with your Mac through iCloud." as the first row.
2. Mac sidebar, iCloud erased (and full, signed out, newer format): the headline still reads "Up to date" (the hub
   link) above the erased sentence. When the iCloud link is paused or blocked, the headline names that state
   ("iCloud paused") and the dot is amber; the hub line stays below it.
Evidence: ~/Offload/watch-collection/test-evidence/icloud-p4/phone-joined.png, mac-erased-window.png.
3. Bridge backup churn (P5 finding): `AppStore.start()` rewrites the JSON mirror at every launch when autoBackup is on
   (AppStore.swift:212), so the bridge would rewrite it every 60 s. In bridge mode, mirror only after a tick that
   installed something.
4. Bridge Dock-icon guard (P5, kept by the lead): Bridge.swift marks the process background-only by mutating the
   in-memory Info dictionary before AppKit starts. If a future macOS breaks that, only the bridge fails, visibly
   (status-mac.at goes stale). Review it in P8; the fallback is a bridge without NSApplication.
5. Rehearsal and any debug run must pass `-WCHub` explicitly: with no saved address the Mac app falls back to the real
   hub http://127.0.0.1:8931 (Theme.swift:16).
6. Rehearsal finding: each bridge process does a full hub exchange and rewrites the Mac's `sync.json` every tick
   though only `lastSuccess` changed. Skip the rewrite (and the hub POST if the hub fast path allows) when nothing
   but `lastSuccess` moved. Low priority; local disk churn only.
7. Rehearsal: `tools/bridge/install.sh` gained `--label` and `--watch` (uncommitted until the fix round; commit it).
Rehearsal evidence: ~/Offload/watch-collection/test-evidence/icloud-rehearsal/ (all six of 13 B pass).

## Later (docs/icloud-fixes.md round 3, "Later, not now"; findings in ~/Offload/watch-collection/review/icloud-p8/round2/)
8. B F1: D3's give-up on the Mac drops the photo's reference everywhere through the hub exchange, even on the phone
   that still holds a good copy, and nothing sends it again (the phone trusts its `inCloud` mark). Options, both lead
   calls: keep the reference and skip the file in the exchange (a third state in the drop rule), or leave
   `unreadable` out of `lost` and accept that the exchange waits on that name.
9. B F5: a held photo that stays unreadable (D2) stops that device's iCloud link both ways, pass after pass, and the
   message names no file. Name the photo (and its watch) in the reason or an error-level log line; consider
   installing the merge without writing while the photo is held (the base stays as it was).
10. B F6: a head that shows no document clears a pending creation, so a save that commits late is merged with no
    base. Hardening: keep the pending book across a nil head and reuse its epoch and base in the next creation.
11. B F7 / C1 6: the phone never gives up on a damaged photo (`failedLately`, 10 minutes, memory only), so with the
    switch on its hub exchange can wait on it for good ("Waiting for photos from iCloud"). Apply D3's strikes rule
    on the phone too.
12. B F8, the small items left: `strike` leaves an old `notInCloud` entry in place, so a name iCloud now has, damaged,
    counts in `lost` before its hour is up (clear it in `strike`); the fake's `uploadPhoto` re-checks the file against
    the given sha, which CloudKit does not (a file rewritten under the same name between the read and the upload,
    `PhotoStore.restore`); in a partial failure `.cancelled` and `.other` share rank 0 in CloudRecords and the tie is
    not broken. (The stale `wroteDocument` and the plan drift were fixed in round 3.)
13. C1 3: D4's "cannot answer" cases are forgotten at every launch (`lastWait` and `link.disabled` live in memory),
    and every bridge tick is a launch, so a deleted (not erased) zone with a reference gone on both sides leaves the
    bridge on `needsHubFirst` until the app is opened. Seed `lastWait` from `cloud-status.json` or the book, or run
    the account and head gate before the hub exchange when no cloud pass has run this launch.
14. C1 4: on the phone in direct mode, a sign-out seen earlier in the launch keeps the old drop rule for the rest of
    the launch. When a fetch reached iCloud, its result should decide; `lastWait` only when no fetch ran.
15. C1 7: flipping the switch leaves the other link's questions on screen, and their answers go nowhere. In
    `setPreferHub`, clear the conflicts of the link that stops being active.
16. C2 round 2 item 2 (gate test): no test covers the app's gate (`Entry.library.whenReady()` in MacApp and in
    `restore`); removing either leaves the suite green. Add a test hook that counts `keepAsking` rounds, or one slow
    test. (The D9 test's patience was fixed in 32c7bc9.)
17. C2 round 2 notes: (4) the CloudKit check's start-of-run zone delete assumes a missing zone answers
    `zoneNotFound`; confirm it on the next check run (13 C). (5) D10's copy could also say "Check that this iPhone
    uses the same Apple ID as your Mac." (6) After a long sleep the Mac line can show amber for one pass; left as is.
    (7) "Opening the collection" has no message if a tick outlives its watchdog; a line after about 60 s. (8) "1
    changes need a choice" in the Mac headline; the unused-result warning at MacApp.swift:49; a lock file unlinked
    while held allows two holders.
