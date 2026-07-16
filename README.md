# Watch Collection

A local-first watch collection tracker with a self-hosted web app, a native iOS companion, and a
six-lens **purchase-decision engine** that tells you what your collection is missing — and what to
hunt next.

Your data is one JSON file on your own machine. No accounts, no cloud, no analytics, no frameworks —
a stdlib-only Python server, vanilla JS, and SwiftUI.

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
- **Native iOS app** — full feature parity plus camera-roll photo uploads and an offline cache;
  point it at your server over Tailscale and your collection is in your pocket.

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
the server URL in the app's Settings at the machine running `server.py` (a
[Tailscale](https://tailscale.com) address works beautifully). The server binds `0.0.0.0` but only
accepts loopback + Tailscale CGNAT (`100.64/10`) clients — see `ALLOWED_CLIENT_NETS` in `server.py`.

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
server.py          stdlib HTTP server: static files + JSON API + photo storage (port 8931)
app.js/index.html  vanilla-JS single-page web app
export_sheet.py    stats/scoring/suggestion engine + CSV exporter (single source of truth)
data/watches.json  ALL your data — one atomic-write JSON file (gitignored)
ios/               SwiftUI companion app (xcodegen project)
```

The scoring and suggestion engines live server-side in `export_sheet.py`; both UIs render from
`/api/wishlist/scores` and `/api/suggestions` so they can never disagree.

## License

MIT
