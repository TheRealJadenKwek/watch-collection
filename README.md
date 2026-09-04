# Watch Collection

A local-first watch collection tracker with a standalone native iOS app, an optional self-hosted web app, and a
six-lens **purchase-decision engine** that tells you what your collection is missing — and what to
hunt next.

No accounts, cloud service, or analytics are required. The iOS app stores its JSON and photos on the
phone; the optional desktop version remains a stdlib-only Python server with a vanilla JS frontend.

## Features

- **Collection & history** — current rotation and every watch you've ever owned (sold, gifted,
  broken, traded…), with photo galleries, stories, and prices.
- **Stats that audit** — spend distribution, percentiles, size histograms against your wrist
  profile, brand breadth, a price ledger with running subtotals, and tappable charts (iOS).
- **Six-lens wishlist scoring** — every candidate scored live against your actual collection:
  category gaps, price-tier holes, brand novelty, dial-colour variety, case-material variety, and
  wrist fit (lug-to-lug aware — L2L beats diameter when known).
- **"Next move" suggestions** — deterministic recommendations composed from your gaps: *"Bronze
  field watch, green or brown dial, 36–41mm — you've never owned either, and your $1000–2500 tier
  is empty"*, complete with curated brands to explore, filtered by what you're already saturated in.
- **Wishlist with auto-images** — candidates fetch their own product shots (best-effort scrape;
  clipboard-paste always works), and a "Bought" flow converts them into collection entries and
  re-ranks everything else.
- **Editable taxonomies** — categories, dial colours, and materials are your lists, not the app's.
  Renames propagate atomically.
- **Daily backup** — CSV + JSON export, optionally rclone'd to your own cloud remote on a launchd
  schedule.
- **Standalone native iOS app** — full feature parity, camera-roll uploads, local scoring, and
  writable on-device storage. It does not need a Mac or server after its one-time migration.
- **Files backup** — keeps a portable JSON copy under On My iPhone and can copy the complete photo
  library there on demand.

## Quick start

```bash
git clone https://github.com/TheRealJadenKwek/watch-collection.git
cd watch-collection
cp data.sample/watches.json data/watches.json   # then make it yours
python3 server.py                                # http://localhost:8931
```

Python 3.11+, no dependencies. Set `settings.ownerName` in your data file to put your name over
the door.

### iOS app

```bash
cd ios
xcodegen generate        # brew install xcodegen
open WatchCollection.xcodeproj
```

Set your own development team + bundle identifier in `project.yml`, run it on your phone, and point
the first v2 launch at the previous server with the `WATCH_MIGRATION_URL` launch environment variable.
The app imports the latest JSON and every referenced photo, then becomes completely standalone.
Updates from an older installed version normally reuse its existing Application Support cache without
needing a fresh import.

### Backups

`python3 export_sheet.py` writes a detailed CSV + JSON snapshot to `exports/`; with
`settings.autoBackup` on (and [rclone](https://rclone.org) configured) it also copies them to the
remote in `settings.backupRemote`. Templates for daily launchd scheduling are in `launchd/`.

## Tests

```bash
python3 -m unittest tests.test_watch_app
```

The suite runs against whatever `data/watches.json` you have; a handful of regression assertions
pinned to the author's personal dataset skip themselves elsewhere.

## Architecture

```
server.py          optional desktop/legacy-import server (port 8931)
app.js/index.html  vanilla-JS single-page web app
export_sheet.py    stats/scoring/suggestion engine + CSV exporter (single source of truth)
data/watches.json  ALL your data — one atomic-write JSON file (gitignored)
ios/               standalone SwiftUI app (xcodegen project; on-device JSON + photos)
```

The Python scoring engine lives in `export_sheet.py`; its Swift port lives in
`ios/Sources/DecisionEngine.swift`. Regression verification compares both implementations against the
same collection data.

## License

MIT
