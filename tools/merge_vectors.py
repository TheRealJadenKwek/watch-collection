#!/usr/bin/env python3
"""Merge vectors for CollectionMerge, the Swift twin of sync.py.

Run from the repo root with the system python3:

    python3 tools/merge_vectors.py

It imports this repo's sync.py, runs the hand-written cases below, RANDOM_COUNT seeded random ones and
TWIN_COUNT seeded random ones built from look-alike pools (TwinGen), and writes
ios/UnitTests/Fixtures/merge-vectors.json:

    {seed, random, twinSeed, twins, vectors: [{name, base, local, remote, resolveByPath, output,
     outputCanonical, conflicts, idsComparable}]}

How a vector is made, and how the Swift test replays it: merge once with no resolutions; every conflict
whose path is listed in resolveByPath (matched code point by code point) gets that choice under the
implementation's own conflict id; merge again with those resolutions. output and conflicts are that
second merge's.

outputCanonical, and each conflict's localCanonical and remoteCanonical, are the bytes the Swift test
compares against: see `canonical`. A hand-written case that sync.py refuses holds `raises` (the exception's
name) instead of an output.

Conflict ids are Python's. Swift's equal them only when every number in the inputs is spelled the same by
both, which idsComparable says: no float with a whole value (Swift reads 42.0 as 42; Python writes it back
as 42.0) and no integer a Double cannot hold exactly or at or past 2^63.
"""
import json
import random
import sys
import unicodedata
from copy import deepcopy
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import sync  # noqa: E402

OUT = ROOT / "ios" / "UnitTests" / "Fixtures" / "merge-vectors.json"
SEED = 20261116
RANDOM_COUNT = 300
TWIN_SEED = 20261117
TWIN_COUNT = 200


# MARK: Running a vector

def run(base, local, remote, resolve_by_path):
    """Merge, resolve by path with this implementation's ids, merge again."""
    _, first = sync.merge(deepcopy(base), deepcopy(local), deepcopy(remote), {})
    # Keyed by json.dumps, which escapes every non-ASCII code point: two paths match only when every
    # step is spelled with the same code points.
    chosen = {json.dumps(item["path"]): item["choice"] for item in resolve_by_path}
    resolutions = {conflict["id"]: chosen[json.dumps(conflict["path"])]
                   for conflict in first if json.dumps(conflict["path"]) in chosen}
    return sync.merge(deepcopy(base), deepcopy(local), deepcopy(remote), resolutions)


def numbers_spelled_alike(value):
    """True when Swift spells every number in value as Python does: no whole float, and every integer one
    a Double holds exactly, below 2^63 (JSONValue keeps numbers as Doubles)."""
    if isinstance(value, bool):
        return True
    if isinstance(value, float):
        return not value.is_integer()
    if isinstance(value, int):
        return abs(value) < 2 ** 63 and float(value) == value
    if isinstance(value, dict):
        return all(numbers_spelled_alike(v) for v in value.values())
    if isinstance(value, list):
        return all(numbers_spelled_alike(v) for v in value)
    return True


def swift_numbers(value):
    """value with each float that has a whole value below 2^63 as an int (-0.0 as 0): how Swift writes it."""
    if isinstance(value, float) and value.is_integer() and abs(value) < 2 ** 63:
        return int(value)
    if isinstance(value, dict):
        return {k: swift_numbers(v) for k, v in value.items()}
    if isinstance(value, list):
        return [swift_numbers(v) for v in value]
    return value


def canonical(value):
    """sync.fingerprint's spelling (keys sorted by code point, no spaces, ASCII with \\u escapes), which
    JSONValue.canonicalData copies. The one agreed difference is applied first: a float with a whole
    value is written as an integer, because Swift cannot tell 42.0 from 42. Everything else (keys, strings
    code point by code point, true against 1, integers past 2^53) is compared as Python wrote it."""
    return json.dumps(swift_numbers(value), sort_keys=True, separators=(",", ":"), allow_nan=False)


def look_alike_keys(*docs):
    """True when two object keys anywhere in docs are canonically equivalent but spelled differently
    (Swift's String treats them as one key; Python keeps both)."""
    keys = set()

    def collect(value):
        if isinstance(value, dict):
            keys.update(value)
            for child in value.values():
                collect(child)
        elif isinstance(value, list):
            for child in value:
                collect(child)
    for d in docs:
        collect(d)
    folded = {}
    for key in keys:
        folded.setdefault(unicodedata.normalize("NFC", key), set()).add(key)
    return any(len(spellings) > 1 for spellings in folded.values())


def whole_float_box_size(*docs):
    """True when a box holds columns or rows as a float with a whole value (sync.py refuses it as a size;
    Swift reads it as the integer)."""
    for d in docs:
        boxes = d.get("boxes") if isinstance(d, dict) else None
        for b in boxes if isinstance(boxes, list) else []:
            if isinstance(b, dict) and any(isinstance(b.get(k), float) and b[k].is_integer()
                                           for k in ("columns", "rows")):
                return True
    return False


def integers_held(value):
    """True when every integer in value is one a Double holds exactly, below 2^63."""
    if isinstance(value, int) and not isinstance(value, bool):
        return abs(value) < 2 ** 63 and float(value) == value
    if isinstance(value, dict):
        return all(integers_held(v) for v in value.values())
    if isinstance(value, list):
        return all(integers_held(v) for v in value)
    return True


def swift_reads_alike(*docs):
    """No input the known differences in CollectionMergeTests cover: look-alike keys, whole-float box
    sizes, integers a Double cannot hold. The random families must stay clear of them."""
    docs = [d for d in docs if d is not None]
    return (not look_alike_keys(*docs) and not whole_float_box_size(*docs)
            and all(integers_held(d) for d in docs))


def vector(name, base, local, remote, resolve=(), check=None, raises=None):
    resolve_by_path = [{"path": list(path), "choice": choice} for path, choice in resolve]
    made = {"name": name, "base": base, "local": local, "remote": remote, "resolveByPath": resolve_by_path}
    if raises is not None:
        try:
            run(base, local, remote, resolve_by_path)
        except raises as error:
            made.update(conflicts=[], idsComparable=False, raises=type(error).__name__)
        else:
            raise AssertionError("%s: sync.py was expected to raise %s" % (name, raises.__name__))
    else:
        output, conflicts = run(base, local, remote, resolve_by_path)
        if check is not None:
            check(output, conflicts)
        made.update(output=output, outputCanonical=canonical(output),
                    conflicts=[dict(c, localCanonical=canonical(c["local"]), remoteCanonical=canonical(c["remote"]))
                               for c in conflicts],
                    idsComparable=all(numbers_spelled_alike(d) for d in (base, local, remote) if d is not None))
    # Every vector must survive the trip through JSON unchanged, or the Swift side reads something else.
    assert json.loads(json.dumps(made, allow_nan=False)) == made, name
    return made


# MARK: Hand-written cases (the Swift tests name several of these)

def doc(watches=(), wishlist=(), **extra):
    d = {"settings": {"autoBackup": False, "backupRemote": "gdrive:WatchCollection", "autoImage": True,
                      "wrist": {"inches": 6.75, "lugMax": 49}},
         "watches": list(watches), "categories": ["Dive", "GMT"], "wishlist": list(wishlist),
         "brandWatchlist": [{"brand": "Baltic", "notes": "", "added": "2024-01"}],
         "dialColors": ["Black"], "materials": ["Steel"]}
    d.update(extra)
    return d


def watch(wid, **fields):
    w = {"id": wid, "name": wid.upper(), "story": "", "price": 100, "status": "owned", "statusNote": "",
         "photos": []}
    w.update(fields)
    return w


def candidate(cid, **fields):
    c = {"id": cid, "name": cid.upper(), "brand": "Baltic", "priceNote": "", "notes": "", "status": "considering",
         "added": "2024-01", "photos": []}
    c.update(fields)
    return c


def box(bid, slots, columns=6, rows=2, **fields):
    b = {"id": bid, "name": bid.title() + " Box", "finish": "black", "columns": columns, "rows": rows,
         "slots": dict(slots)}
    b.update(fields)
    return b


def by_id(items, wid):
    return next(item for item in items if item.get("id") == wid)


def expect(condition, message="expectation failed"):
    if not condition:
        raise AssertionError(message)


def hand_cases():
    cases = []
    add = lambda *args, **kwargs: cases.append(vector(*args, **kwargs))  # noqa: E731

    base = doc([watch("w1", name="Speedmaster", price=100), watch("w2")])
    add("edit different fields",
        base, doc([watch("w1", name="Moonwatch", price=100), watch("w2")]),
        doc([watch("w1", name="Speedmaster", price=200), watch("w2")]),
        check=lambda out, c: expect(not c and by_id(out["watches"], "w1")["name"] == "Moonwatch"
                                    and by_id(out["watches"], "w1")["price"] == 200))

    base = doc([watch("w1", name="Speedmaster")])
    local = doc([watch("w1", name="Moonwatch")])
    remote = doc([watch("w1", name="Speedy")])
    add("same field both sides", base, local, remote,
        check=lambda out, c: expect(len(c) == 1 and c[0]["path"] == ["watches", "w1", "name"]
                                    and by_id(out["watches"], "w1")["name"] == "Speedy"))
    add("same field both sides, local chosen", base, local, remote,
        resolve=[(["watches", "w1", "name"], "local")],
        check=lambda out, c: expect(not c and by_id(out["watches"], "w1")["name"] == "Moonwatch"))
    add("same field both sides, remote chosen", base, local, remote,
        resolve=[(["watches", "w1", "name"], "remote")],
        check=lambda out, c: expect(not c and by_id(out["watches"], "w1")["name"] == "Speedy"))
    add("same field both sides, unknown choice", base, local, remote,
        resolve=[(["watches", "w1", "name"], "neither")],
        check=lambda out, c: expect(len(c) == 1))
    add("same change both sides", base, local, deepcopy(local),
        check=lambda out, c: expect(not c and by_id(out["watches"], "w1")["name"] == "Moonwatch"))

    base = doc([watch("w1"), watch("w2", name="Black Bay")])
    edited = doc([watch("w1"), watch("w2", name="Black Bay 58")])
    without = doc([watch("w1")])
    add("local deletes, remote edits", base, without, edited,
        check=lambda out, c: expect(len(c) == 1 and c[0]["path"] == ["watches", "w2"] and c[0]["localDeleted"]
                                    and not c[0]["remoteDeleted"] and len(out["watches"]) == 2))
    add("remote deletes, local edits", base, edited, without,
        check=lambda out, c: expect(len(c) == 1 and c[0]["path"] == ["watches", "w2"] and c[0]["remoteDeleted"]
                                    and not c[0]["localDeleted"] and len(out["watches"]) == 1))
    add("remote deletes, local edits, local chosen", base, edited, without,
        resolve=[(["watches", "w2"], "local")],
        check=lambda out, c: expect(not c and by_id(out["watches"], "w2")["name"] == "Black Bay 58"))
    add("local deletes, remote edits, local chosen", base, without, edited,
        resolve=[(["watches", "w2"], "local")],
        check=lambda out, c: expect(not c and [w["id"] for w in out["watches"]] == ["w1"]))
    add("delete on one side only", base, without, deepcopy(base),
        check=lambda out, c: expect(not c and [w["id"] for w in out["watches"]] == ["w1"]))

    add("no base never deletes", None,
        doc([watch("w1"), watch("w2")], [candidate("c1")]),
        doc([watch("w1"), watch("w3")], [candidate("c2")]),
        check=lambda out, c: expect(not c and [w["id"] for w in out["watches"]] == ["w1", "w3", "w2"]
                                    and [w["id"] for w in out["wishlist"]] == ["c2", "c1"]))

    local_boxes = [box("black", {"0": "w1"}), box("travel", {"0": "w2"}, columns=3, rows=1)]
    remote_boxes = [box("brown", {"1": "w2"}, finish="brown")]
    watches = [watch("w1"), watch("w2")]
    add("boxes with no base", None, doc(watches, boxes=local_boxes), doc(watches, boxes=remote_boxes),
        check=lambda out, c: expect(not c and out["boxes"] == remote_boxes))
    add("boxes with a base that has none", doc(watches), doc(watches, boxes=local_boxes),
        doc(watches, boxes=remote_boxes),
        check=lambda out, c: expect(not c and out["boxes"] == remote_boxes))
    add("boxes with no base, remote has none", None, doc(watches, boxes=local_boxes), doc(watches, boxes=[]),
        check=lambda out, c: expect(not c and out["boxes"] == local_boxes))
    add("boxes with no base, remote lacks the key", None, doc(watches, boxes=local_boxes), doc(watches),
        check=lambda out, c: expect(not c and out["boxes"] == local_boxes))

    three = [box("black", {}), box("brown", {}, finish="brown"), box("travel", {}, columns=3, rows=1)]
    black, brown, travel = three
    add("box reorder on the local side", doc(watches, boxes=[black, brown]), doc(watches, boxes=[brown, black]),
        doc(watches, boxes=[black, brown, travel]),
        check=lambda out, c: expect(not c and [b["id"] for b in out["boxes"]] == ["brown", "black", "travel"]))
    add("box reorder on the remote side", doc(watches, boxes=[black, brown]),
        doc(watches, boxes=[black, brown, travel]), doc(watches, boxes=[brown, black]),
        check=lambda out, c: expect(not c and [b["id"] for b in out["boxes"]] == ["brown", "black", "travel"]))
    add("box reorder on both sides", doc(watches, boxes=[black, brown, travel]),
        doc(watches, boxes=[travel, black, brown]), doc(watches, boxes=[brown, black, travel]),
        check=lambda out, c: expect(not c and [b["id"] for b in out["boxes"]] == ["brown", "black", "travel"]))

    add("photo union and cover order", doc([watch("w1", photos=["a.jpg", "b.jpg", "c.jpg"])]),
        doc([watch("w1", photos=["c.jpg", "a.jpg", "b.jpg", "d.jpg"])]),
        doc([watch("w1", photos=["a.jpg", "c.jpg", "e.jpg"])]),
        check=lambda out, c: expect(not c and out["watches"][0]["photos"] == ["c.jpg", "a.jpg", "d.jpg", "e.jpg"]))
    # sync.py:201 puts the remote's order first only when left equals previous, and a left equal to a list
    # base has already returned at sync.py:163. So any local change to the list (here an addition) makes the
    # local order win, and the remote's new cover is lost.
    add("photo order follows local whenever local changed the list",
        doc([watch("w1", photos=["a.jpg", "b.jpg"])]), doc([watch("w1", photos=["a.jpg", "b.jpg", "d.jpg"])]),
        doc([watch("w1", photos=["b.jpg", "a.jpg"])]),
        check=lambda out, c: expect(not c and out["watches"][0]["photos"] == ["a.jpg", "b.jpg", "d.jpg"]))
    add("photo order from the remote when local is empty and there is no base", None,
        doc([watch("w1", photos=[])]), doc([watch("w1", photos=["b.jpg", "a.jpg"])]),
        check=lambda out, c: expect(not c and out["watches"][0]["photos"] == ["b.jpg", "a.jpg"]))

    plain = doc([watch("w1")], [candidate("c1")])
    future = doc([watch("w1", futureField={"strap": "NATO"})], [candidate("c1", futureField=[1, 2])],
                 futureTop={"version": 2})
    future["watches"][0]["name"] = "Edited on the hub"
    add("unknown keys survive", plain, deepcopy(plain), future,
        check=lambda out, c: expect(not c and out["futureTop"] == {"version": 2}
                                    and out["watches"][0]["futureField"] == {"strap": "NATO"}
                                    and out["wishlist"][0]["futureField"] == [1, 2]))
    local_future = deepcopy(plain)
    local_future["localOnlyTop"] = True
    add("unknown top-level key from local is dropped", plain, local_future, deepcopy(plain),
        check=lambda out, c: expect(not c and "localOnlyTop" not in out))

    add("42 equals 42.0", doc([watch("w1", price=42, name="A")]), doc([watch("w1", price=42.0, name="B")]),
        doc([watch("w1", price=42, name="A", story="Remote story")]),
        check=lambda out, c: expect(not c and out["watches"][0]["name"] == "B"
                                    and out["watches"][0]["story"] == "Remote story"))
    add("42.0 on one side, a new price on the other", doc([watch("w1", price=42)]),
        doc([watch("w1", price=42.0)]), doc([watch("w1", price=43)]),
        check=lambda out, c: expect(not c and out["watches"][0]["price"] == 43))
    add("True equals 1, as Python compares", doc([watch("w1", original=True)]),
        doc([watch("w1", original=1)]), doc([watch("w1", original=True, name="Remote")]),
        check=lambda out, c: expect(not c and out["watches"][0]["original"] is True))
    add("True and 1 added on both sides with no base", None, doc([watch("w1", original=True)]),
        doc([watch("w1", original=1)]),
        check=lambda out, c: expect(not c and out["watches"][0]["original"] is True))

    two = [watch("w1"), watch("w2")]
    add("watch in two boxes after a merge is cleaned",
        doc(two, boxes=[box("black", {"0": "w1"}), box("brown", {}, finish="brown")]),
        doc(two, boxes=[box("black", {"0": "w1", "1": "w2"}), box("brown", {}, finish="brown")]),
        doc(two, boxes=[box("black", {"0": "w1"}), box("brown", {"0": "w2"}, finish="brown")]),
        check=lambda out, c: expect(not c and out["boxes"][0]["slots"] == {"0": "w1", "1": "w2"}
                                    and out["boxes"][1]["slots"] == {}))
    add("normalize drops nulls and empty wear lists", None,
        doc([watch("w1", purchased=None, wearSessions=[], wearDates=[], serviceRecords=[], brand="Omega")]),
        doc([watch("w1", brand="Omega")]),
        check=lambda out, c: expect(not c and "purchased" not in out["watches"][0]
                                    and "wearSessions" not in out["watches"][0]))
    add("wear sessions merge by id", doc([watch("w1", wearSessions=[{"id": "s1", "date": "2026-01-01",
                                                                     "durationMinutes": 60}])]),
        doc([watch("w1", wearSessions=[{"id": "s1", "date": "2026-01-01", "durationMinutes": 90},
                                       {"id": "s2", "date": "2026-01-02", "durationMinutes": 30}])]),
        doc([watch("w1", wearSessions=[{"id": "s1", "date": "2026-01-03", "durationMinutes": 60},
                                       {"id": "s3", "date": "2026-01-04", "durationMinutes": 15}])]),
        check=lambda out, c: expect(not c and [s["id"] for s in out["watches"][0]["wearSessions"]]
                                    == ["s1", "s3", "s2"]))

    add("empty list takes the string-list branch", doc(categories=["Dive"]), doc(categories=[]),
        doc(categories=["Dive", "Pilot"]),
        check=lambda out, c: expect(not c and out["categories"] == ["Pilot"]))
    add("unknown top-level list comes from the remote", None, doc(straps=[]),
        doc(straps=[{"kind": "NATO"}]),
        check=lambda out, c: expect(not c and out["straps"] == [{"kind": "NATO"}]))
    add("empty against a list of objects inside a watch", doc([watch("w1")]), doc([watch("w1", straps=[])]),
        doc([watch("w1", straps=[{"kind": "NATO"}])]),
        check=lambda out, c: expect(len(c) == 1 and c[0]["path"] == ["watches", "w1", "straps"]))
    add("numbers in the base list block the string union", doc([watch("w1", tags=[1, 2])]),
        doc([watch("w1", tags=["a"])]), doc([watch("w1", tags=["b"])]),
        check=lambda out, c: expect(len(c) == 1))
    add("strings added on both sides with no base", None, doc(categories=["Dive", "Field"]),
        doc(categories=["GMT", "Dive"]),
        check=lambda out, c: expect(not c and out["categories"] == ["Dive", "Field", "GMT"]))

    add("top-level delete keeps the remote's", doc(), {k: v for k, v in doc().items() if k != "materials"},
        doc(),
        check=lambda out, c: expect(not c and out["materials"] == ["Steel"]))
    settings_base = doc()
    settings_local = doc()
    settings_local["settings"].pop("wrist")
    settings_local["settings"]["autoBackup"] = True
    settings_local["settings"]["autoImage"] = False
    settings_remote = doc()
    settings_remote["settings"]["backupRemote"] = "hub-only"
    add("settings: synced keys merge, device keys stay the remote's", settings_base, settings_local,
        settings_remote,
        check=lambda out, c: expect(not c and out["settings"]["autoImage"] is False
                                    and out["settings"]["autoBackup"] is False
                                    and out["settings"]["backupRemote"] == "hub-only"
                                    and "wrist" in out["settings"]))
    no_settings = doc()
    no_settings.pop("settings")
    add("remote with no settings", doc(), doc(), no_settings,
        check=lambda out, c: expect(not c))

    many_base = doc([watch("w1", price=100, name="A"), watch("w2", name="B")],
                    [candidate("c1", notes="x")],
                    boxes=[box("black", {"0": "w1"})])
    many_base["settings"]["wrist"]["inches"] = 6.75
    many_local = deepcopy(many_base)
    many_remote = deepcopy(many_base)
    many_local["watches"][1]["name"] = "B local"
    many_remote["watches"][1]["name"] = "B remote"
    many_local["watches"][0]["price"] = 150
    many_remote["watches"][0]["price"] = 175
    many_local["wishlist"][0]["notes"] = "local"
    many_remote["wishlist"][0]["notes"] = "remote"
    many_local["settings"]["wrist"]["inches"] = 7.25
    many_remote["settings"]["wrist"]["inches"] = 6.5
    many_local["boxes"][0]["slots"] = {"0": "w2"}
    many_remote["boxes"][0]["slots"] = {"5": "w1"}
    many_local["categories"] = "not a list"
    many_remote["categories"] = {"also": "not a list"}
    add("conflicts come out in Python's order", many_base, many_local, many_remote,
        check=lambda out, c: expect([x["path"][0] for x in c]
                                    == ["boxes", "categories", "settings", "watches", "watches", "wishlist"]))
    add("conflicts in Python's order, some resolved", many_base, many_local, many_remote,
        resolve=[(["watches", "w2", "name"], "local"), (["categories"], "local"),
                 (["boxes", "black", "slots", "0"], "remote")])

    add("box rules: capacity, owned, invalid keys, more than eight, duplicate ids",
        doc([watch("w1"), watch("w2", status="sold"), watch("w3")]),
        doc([watch("w1"), watch("w2", status="sold"), watch("w3")]),
        doc([watch("w1"), watch("w2", status="sold"), watch("w3")],
            boxes=[box("b1", {"0": "w2", "05": "w1", "+5": "w1", "12": "w1", "11": "w1", "3": "ghost", "4": 7}),
                   box("b1", {"0": "w3"}, name="Duplicate"),
                   box("b2", {"0": "w3", "1": "w1"}, columns=2.5),
                   box("b3", {"1": "w3"}, columns=True),
                   box("b4", {"0": "w3"}, rows="2"),
                   box("b5", {"0": "w3"}, columns=-1),
                   dict(box("b6", {}), slots=None),
                   "not a box",
                   box("b8", {"0": "w3"}),
                   box("b9", {"1": "w3"})]),
        check=lambda out, c: expect(not c and len(out["boxes"]) == 7 and out["boxes"][0]["slots"] == {"11": "w1"}))
    add("cutouts kept in range", None,
        doc([watch("w1", boxCutout={"photo": "a.jpg", "x": -0.5, "y": 1.5, "r": 0.01, "turn": 270,
                                    "caseOnly": 1, "useCutout": True}),
             watch("w2", boxCutout={"photo": "a.jpg", "x": 0.5, "y": "0.5", "r": 0.2, "turn": 0,
                                    "caseOnly": True, "useCutout": False})],
            [candidate("c1", boxCutout={"photo": "b.jpg", "x": 0.25, "y": 0.75, "r": 0.9, "turn": -12.5})]),
        doc([watch("w1"), watch("w2")], [candidate("c1")]),
        check=lambda out, c: expect(not c and out["watches"][0]["boxCutout"] == {
            "photo": "a.jpg", "x": 0, "y": 1, "r": 0.05, "turn": 180, "useCutout": True}))

    add("duplicate ids in an identity list", doc([watch("w1", name="First"), watch("w1", name="Second")]),
        doc([watch("w1", name="First"), watch("w1", name="Second"), watch("w2")]),
        doc([watch("w1", name="Remote"), watch("w1", name="Second")]))
    add("brand watchlist merges by brand", doc(),
        doc(brandWatchlist=[{"brand": "Baltic", "notes": "local", "added": "2024-01"},
                            {"brand": "Tudor", "notes": "", "added": "2026-11"}]),
        doc(brandWatchlist=[{"brand": "Baltic", "notes": "", "added": "2024-02"}]),
        check=lambda out, c: expect(not c and [b["brand"] for b in out["brandWatchlist"]] == ["Baltic", "Tudor"]))
    add("scalar against object is a conflict", doc([watch("w1", story="plain")]),
        doc([watch("w1", story={"text": "rich"})]), doc([watch("w1", story="edited")]),
        check=lambda out, c: expect(len(c) == 1 and c[0]["path"] == ["watches", "w1", "story"]))
    nfc = unicodedata.normalize("NFC", "Café")
    nfd = unicodedata.normalize("NFD", "Café")
    add("Unicode: escapes, key order and composed against decomposed", None,
        doc([watch("w1", name=nfc, story="Tab\tquote\" back\\slash ⌘ \U0001F600",
                   **{"Ünknown": 1.5, "zeta": "z", "Zeta": "Z", "日付": "x"})]),
        doc([watch("w1", name=nfd, story="Line\nbreak \u007f",
                   **{"Ünknown": 2.5, "zeta": "z2", "Zeta": "Z", "日付": "y"})]),
        check=lambda out, c: expect([x["path"][-1] for x in c] == ["name", "story", "zeta", "Ünknown", "日付"]))

    # sync.py:156-157 and 210: the object a conflict reports as "remote" is the one `conflict` returns into
    # the output, and clean_boxes(output) then edits cutouts and box slots in place. So the report shows a
    # remote cutout or box cleaned (its id was taken before). A value inside an edited object is a different
    # object and is reported as sent.
    raw_cut = {"photo": "a.jpg", "x": 1.5, "y": 0.5, "r": 0.9, "turn": 0, "caseOnly": False}
    clean_cut = {"photo": "a.jpg", "x": 1, "y": 0.5, "r": 0.5}
    add("conflict on a cutout reports the remote cleaned", doc([watch("w1", boxCutout={"photo": "a.jpg"})]),
        doc([watch("w1", boxCutout="automatic")]), doc([watch("w1", boxCutout=dict(raw_cut))]),
        check=lambda out, c: expect(len(c) == 1 and c[0]["path"] == ["watches", "w1", "boxCutout"]
                                    and c[0]["remote"] == clean_cut and c[0]["local"] == "automatic"))
    add("conflict inside a cutout reports the remote as sent",
        doc([watch("w1", boxCutout={"photo": "a.jpg", "x": 0.5, "y": 0.5, "r": 0.2})]),
        doc([watch("w1", boxCutout={"photo": "a.jpg", "x": 0.25, "y": 0.5, "r": 0.2})]),
        doc([watch("w1", boxCutout={"photo": "a.jpg", "x": 1.5, "y": 0.5, "r": 0.2})]),
        check=lambda out, c: expect(len(c) == 1 and c[0]["path"] == ["watches", "w1", "boxCutout", "x"]
                                    and c[0]["remote"] == 1.5 and out["watches"][0]["boxCutout"]["x"] == 1))
    add("delete against edit reports the remote watch cleaned", doc([watch("w1"), watch("w2")]),
        doc([watch("w1")]), doc([watch("w1"), watch("w2", name="Edited", boxCutout=dict(raw_cut))]),
        check=lambda out, c: expect(len(c) == 1 and c[0]["remote"]["boxCutout"] == clean_cut))
    add("delete against edit reports the remote candidate cleaned", doc([], [candidate("c1")]), doc([], []),
        doc([], [candidate("c1", notes="Edited", boxCutout=dict(raw_cut))]),
        check=lambda out, c: expect(len(c) == 1 and c[0]["path"] == ["wishlist", "c1"]
                                    and c[0]["remote"]["boxCutout"] == clean_cut))
    owners = [watch("w1"), watch("w2", status="sold")]
    first_box = box("black", {"0": "w1"})
    add("delete against edit reports the remote box cleaned",
        doc(owners, boxes=[first_box, box("brown", {}, finish="brown")]), doc(owners, boxes=[first_box]),
        doc(owners, boxes=[first_box, box("brown", {"0": "w2", "1": "w1", "99": "w1"}, finish="brown")]),
        check=lambda out, c: expect(len(c) == 1 and c[0]["path"] == ["boxes", "brown"]
                                    and c[0]["remote"]["slots"] == {} and out["boxes"][1]["slots"] == {}))
    slotless = {k: v for k, v in box("black", {}).items() if k != "slots"}
    add("conflict on a box's slots reports them as sent", doc(two, boxes=[box("black", {"0": "w1"})]),
        doc(two, boxes=[slotless]), doc(two, boxes=[box("black", {"0": "w1", "1": "ghost"})]),
        check=lambda out, c: expect(len(c) == 1 and c[0]["path"] == ["boxes", "black", "slots"]
                                    and c[0]["remote"] == {"0": "w1", "1": "ghost"}
                                    and out["boxes"][0]["slots"] == {"0": "w1"}))
    nine = [box("b%d" % i, {"0": "w1"}) for i in range(9)]
    add("conflict on the whole box list reports every box with its slots cleaned",
        doc(two, boxes=[box("black", {})]), doc(two, boxes={"black": {}}), doc(two, boxes=nine),
        check=lambda out, c: expect(len(c) == 1 and c[0]["path"] == ["boxes"] and len(c[0]["remote"]) == 9
                                    and [b["slots"] for b in c[0]["remote"]] == [{"0": "w1"}] + [{}] * 8
                                    and len(out["boxes"]) == 8))
    no_watch_list = doc([watch("w1")])
    no_watch_list["watches"] = {}
    add("conflict on the whole watch list reports the cutouts cleaned", doc([watch("w1")]), no_watch_list,
        doc([watch("w1", boxCutout=dict(raw_cut))]),
        check=lambda out, c: expect(len(c) == 1 and c[0]["path"] == ["watches"]
                                    and c[0]["remote"][0]["boxCutout"] == clean_cut))

    # Look-alike Unicode (review A6, A7). Canonically equivalent spellings are different strings to
    # Python, so every id, list string and value below stays apart from its twin, and an answer given for
    # one path never reaches its twin's.
    e_nfc, e_nfd = "\u00e9", "e\u0301"
    cafe_nfc, cafe_nfd = "Caf\u00e9", "Cafe\u0301"
    photo_nfc, photo_nfd = "caf\u00e9.jpg", "cafe\u0301.jpg"
    kelvin, angstrom, greek_question = "\u212a", "\u212b", "\u037e"
    hangul, jamo = "\ud55c", "\u1112\u1161\u11ab"
    for twin, plain in ((e_nfd, e_nfc), (cafe_nfd, cafe_nfc), (photo_nfd, photo_nfc), (kelvin, "K"),
                        (angstrom, "\u00c5"), (greek_question, ";"), (jamo, hangul)):
        assert twin != plain and unicodedata.normalize("NFC", twin) == plain, (twin, plain)

    add("Unicode: look-alike watch ids are two watches, each answered by its own path",
        doc([watch("K", name="a"), watch(kelvin, name="b")]), doc([]),
        doc([watch("K", name="a2"), watch(kelvin, name="b2")]),
        resolve=[(["watches", "K"], "local")],
        check=lambda out, c: expect([w["id"] for w in out["watches"]] == [kelvin]
                                    and [x["path"] for x in c] == [["watches", kelvin]]))
    add("Unicode: a look-alike category added on the local side is kept",
        doc(categories=[cafe_nfc]), doc(categories=[cafe_nfc, cafe_nfd]), doc(categories=[cafe_nfc, "GMT"]),
        check=lambda out, c: expect(not c and out["categories"] == [cafe_nfc, cafe_nfd, "GMT"]))
    add("Unicode: every kind of canonical look-alike in a string list",
        doc(categories=["K", "\u00c5", ";", hangul, cafe_nfc]),
        doc(categories=["K", kelvin, "\u00c5", ";", hangul, jamo, cafe_nfc]),
        doc(categories=[kelvin, angstrom, greek_question, jamo, cafe_nfd]),
        check=lambda out, c: expect(not c and out["categories"] == [kelvin, jamo, angstrom, greek_question, cafe_nfd]))
    add("Unicode: a look-alike photo added as the cover while the other side removes its twin",
        doc([watch("w1", photos=[photo_nfc, "a.jpg"])]), doc([watch("w1", photos=[photo_nfd, photo_nfc, "a.jpg"])]),
        doc([watch("w1", photos=["a.jpg"])]),
        check=lambda out, c: expect(not c and out["watches"][0]["photos"] == [photo_nfd, "a.jpg"]))

    owners = [watch(e_nfc + "1", name="Owned"), watch(e_nfd + "1", name="Sold", status="sold")]
    look_alike_boxes = doc(owners, boxes=[box(e_nfc, {"0": e_nfd + "1", "1": e_nfc + "1"}),
                                          box(e_nfd, {"0": e_nfc + "1"}, finish="brown")])
    renamed_here, renamed_there = deepcopy(look_alike_boxes), deepcopy(look_alike_boxes)
    renamed_here["boxes"][1]["name"] = "Renamed here"
    renamed_there["boxes"][0]["name"] = "Renamed there"
    add("Unicode: look-alike box ids, slot watch ids and owned ids stay apart", look_alike_boxes, renamed_here,
        renamed_there,
        check=lambda out, c: expect(not c and [(b["id"], b["name"], b["slots"]) for b in out["boxes"]]
                                    == [(e_nfc, "Renamed there", {"1": e_nfc + "1"}), (e_nfd, "Renamed here", {})]))
    two_boxes = [box(e_nfc, {}), box(e_nfd, {}, finish="brown")]
    add("Unicode: look-alike box ids moved on the local side keep the local order",
        doc(owners, boxes=two_boxes), doc(owners, boxes=two_boxes[::-1]),
        doc(owners, boxes=two_boxes + [box("travel", {}, columns=3, rows=1)]),
        check=lambda out, c: expect(not c and [b["id"] for b in out["boxes"]] == [e_nfd, e_nfc, "travel"]))

    sessions = [{"id": e_nfc, "date": "2026-01-01", "durationMinutes": 60},
                {"id": e_nfd, "date": "2026-01-02", "durationMinutes": 30}]
    brands = [{"brand": "\u00c5ngstr\u00f6m", "notes": "", "added": "2024-01"},
              {"brand": angstrom + "ngstr\u00f6m", "notes": "", "added": "2024-01"}]
    sessions_base = doc([watch("w1", wearSessions=sessions)], brandWatchlist=brands)
    sessions_local, sessions_remote = deepcopy(sessions_base), deepcopy(sessions_base)
    sessions_local["watches"][0]["wearSessions"][1]["durationMinutes"] = 45
    sessions_local["brandWatchlist"][0]["notes"] = "here"
    sessions_remote["watches"][0]["wearSessions"][0]["durationMinutes"] = 90
    sessions_remote["brandWatchlist"][1]["notes"] = "there"
    add("Unicode: look-alike wear session ids and brands merge one by one", sessions_base, sessions_local,
        sessions_remote,
        check=lambda out, c: expect(not c and [s["durationMinutes"] for s in out["watches"][0]["wearSessions"]]
                                    == [90, 45] and [b["notes"] for b in out["brandWatchlist"]] == ["here", "there"]))

    add("Unicode: a value respelled with look-alike code points is an edit",
        doc([watch("w1", name=cafe_nfc, story=cafe_nfd, brand="K")]),
        doc([watch("w1", name=cafe_nfc, story=cafe_nfc, brand="K")]),
        doc([watch("w1", name=cafe_nfd, story=cafe_nfd, brand=kelvin)]),
        check=lambda out, c: expect(not c and out["watches"][0]["name"] == cafe_nfd
                                    and out["watches"][0]["story"] == cafe_nfc and out["watches"][0]["brand"] == kelvin))
    add("Unicode: look-alike edits on both sides are a conflict",
        doc([watch("w1", name="Cafe")]), doc([watch("w1", name=cafe_nfc)]), doc([watch("w1", name=cafe_nfd)]),
        check=lambda out, c: expect(len(c) == 1 and c[0]["local"] == cafe_nfc and c[0]["remote"] == cafe_nfd))
    # Compatibility look-alikes (the fi ligature, fullwidth K and 5, superscript 2) are not canonically
    # equivalent: NFKC would fold them, Python and Swift's String both keep them apart.
    ligature, fullwidth_k, fullwidth_5, superscript_2 = "\ufb01", "\uff2b", "\uff15", "\u00b2"
    add("Unicode: compatibility look-alikes are different strings",
        None,
        doc([watch("fi", name="fi"), watch(ligature, name=ligature)], categories=["field", fullwidth_k + "2"],
            boxes=[box("black", {"5": "fi", fullwidth_5: ligature})]),
        doc([watch("fi", name="fi"), watch(ligature + "x", name="x" + superscript_2)],
            categories=[ligature + "eld", "K" + superscript_2]),
        check=lambda out, c: expect(not c and [w["id"] for w in out["watches"]] == ["fi", ligature + "x", ligature]
                                    and out["categories"] == ["field", fullwidth_k + "2", ligature + "eld",
                                                              "K" + superscript_2]
                                    and out["boxes"][0]["slots"] == {"5": "fi"}))

    # Numbers (review A8). Swift keeps every number as a Double, so the canonical bytes write a float with
    # a whole value as an integer (see `canonical`); everything else is spelled as Python spells it.
    floats = {"whole": [6.0, 42.0, -0.0, 1.0, 1e16, 2.0 ** 63 - 1024, 2.0 ** 63, 2.0 ** 64, 1e21, 1e300],
              "fractional": [0.1, 2.5, 6.75, -3.75, 1e-07, 2.5e-05, 5e-324, 123456789012.5]}
    add("numbers: floats with a whole value and floats without", doc([watch("w1", price=42)]),
        doc([watch("w1", price=42.0, diameter=40.0)]), doc([watch("w1", price=42, floats=floats)]),
        check=lambda out, c: expect(not c and out["watches"][0]["floats"] == floats
                                    and out["watches"][0]["diameter"] == 40.0))
    add("numbers: a conflict between a whole float and a fraction", doc([watch("w1", price=40)]),
        doc([watch("w1", price=42.0)]), doc([watch("w1", price=43.5)]),
        check=lambda out, c: expect(len(c) == 1 and c[0]["local"] == 42.0 and c[0]["remote"] == 43.5))
    held = [2 ** 53, 2 ** 53 + 2, -(2 ** 53 + 2), 2 ** 60, -(2 ** 62), 2 ** 63 - 1024, 9007199254740991]
    add("numbers: integers past 2^53 that a Double holds", doc([watch("w1")]),
        doc([watch("w1", price=2 ** 53 + 2)]), doc([watch("w1", serials=held)]),
        check=lambda out, c: expect(not c and out["watches"][0]["serials"] == held
                                    and out["watches"][0]["price"] == 2 ** 53 + 2))
    add("boxes: a size with a fraction holds nothing",
        doc(two, boxes=[box("black", {"0": "w1"})]), doc(two, boxes=[box("black", {"0": "w1"})]),
        doc(two, boxes=[box("black", {"0": "w1"}, columns=6.5),
                        box("brown", {"0": "w2"}, rows=1.5, finish="brown")]),
        check=lambda out, c: expect(not c and [b["slots"] for b in out["boxes"]] == [{}, {}]))

    # Known differences: CollectionMergeTests.knownDifferences names each of these with its reason. The
    # twin parts from sync.py on them by design, on input no app writes.
    focus = {"x": 0.5, "y": 0.5, "zoom": 1.25}
    add("look-alike object keys from the two sides",
        doc([watch("w1", photos=[photo_nfc, photo_nfd], photoFocus={})]),
        doc([watch("w1", photos=[photo_nfc, photo_nfd], photoFocus={photo_nfc: dict(focus)})]),
        doc([watch("w1", photos=[photo_nfc, photo_nfd], photoFocus={photo_nfd: dict(focus, x=0.25)})]),
        check=lambda out, c: expect(not c and len(out["watches"][0]["photoFocus"]) == 2))
    add("look-alike object keys in one object", doc([watch("w1")]), doc([watch("w1", name="Renamed")]),
        doc([watch("w1", futureField={"K": 1, kelvin: 2, cafe_nfc: 3, cafe_nfd: 4})]),
        check=lambda out, c: expect(not c and len(out["watches"][0]["futureField"]) == 4))
    add("integers past 2^53 that a Double cannot hold", doc([watch("w1")]), doc([watch("w1", name="Renamed")]),
        doc([watch("w1", serial=12345678901234567)],
            futureTop={"barcode": 9007199254740993, "debt": -9007199254740993}),
        check=lambda out, c: expect(not c and out["watches"][0]["serial"] == 12345678901234567
                                    and out["futureTop"] == {"barcode": 9007199254740993, "debt": -9007199254740993}))
    add("integers at or past 2^63", doc([watch("w1")]), doc([watch("w1", name="Renamed")]),
        doc([watch("w1", serials=[2 ** 63, -(2 ** 63), 2 ** 64, 10 ** 20])]),
        check=lambda out, c: expect(not c and out["watches"][0]["serials"] == [2 ** 63, -(2 ** 63), 2 ** 64, 10 ** 20]))
    add("integers that differ only past a Double's precision", doc([watch("w1", price=2 ** 53)]),
        doc([watch("w1", price=2 ** 53 + 1)]), doc([watch("w1", price=2 ** 53 + 3)]),
        check=lambda out, c: expect(len(c) == 1 and c[0]["path"] == ["watches", "w1", "price"]))
    add("a box size written as a whole float",
        doc(two, boxes=[box("black", {"0": "w1"}), box("brown", {"0": "w2"}, finish="brown")]),
        doc(two, boxes=[box("black", {"0": "w1"}), box("brown", {"0": "w2"}, finish="brown")]),
        doc(two, boxes=[box("black", {"0": "w1"}, columns=6.0, name="Renamed"),
                        box("brown", {"0": "w2"}, rows=2.0, finish="brown")]),
        check=lambda out, c: expect(not c and [b["slots"] for b in out["boxes"]] == [{}, {}]))

    # sync.py refuses these (the hub writes nothing). The twin's quiet answers are pinned in
    # CollectionMergeTests.testWhereSyncPyRaisesTheTwinAnswersQuietly.
    add("sync.py raises: a watch with no id", doc([watch("w1"), watch("w2")]),
        doc([watch("w1"), {"name": "No id", "status": "owned", "photos": []}]),
        doc([watch("w1"), watch("w2", name="Edited"), watch("w3")]), raises=KeyError)
    add("sync.py raises: a wishlist entry that is not an object", doc([], [candidate("c1")]),
        doc([], [candidate("c1", notes="Edited")]), doc([], [candidate("c1"), "not an object"]), raises=TypeError)
    settings_text = doc()
    settings_text["settings"] = "not an object"
    add("sync.py raises: settings that are not an object", doc(), doc(), settings_text, raises=AttributeError)
    return cases


# MARK: Random cases

NAMES = ["Speedmaster", "Submariner", "Black Bay 58", "SKX007", "Aquascaphe", "Ève Médaille", "時計",
         "Tab\there", 'Quote "q" back\\slash', "⌚ Watch 😀", "", unicodedata.normalize("NFD", "Café")]
STORIES = ["", "Gift", "First watch", "Bought in Tokyo", "Line\nbreak"]
STATUSES = ["owned", "owned", "owned", "sold", "gifted"]
NUMBERS = [0, 1, 2, 3, 42, -5, 1200, 9007199254740991, 0.5, 1.25, -3.75, 38.5, 0.1, 1e-07, 2.5e-05, 6.75, 39.5,
           123456.789]
PHOTOS = ["a1.jpg", "b2.jpg", "c3.png", "d4.heic", "e5.jpg", "f6.jpg"]
WATCH_IDS = ["w1", "w2", "w3", "w4", "w5", "w6", "w7", "café"]
CANDIDATE_IDS = ["c1", "c2", "c3", "c4", "c5"]
BRANDS = ["Omega", "Rolex", "Tudor", "Seiko", "Baltic"]
BOX_IDS = ["black", "brown", "travel", "b4", "b5", "b6", "b7", "b8", "b9", "b10", "b11"]
SESSION_IDS = ["s1", "s2", "s3", "s4", "s5"]
DATES = ["2026-01-01", "2026-02-14", "2026-03-30", "2026-11-16"]
STRINGS = ["Dive", "GMT", "Dress", "Field", "Pilot", "Chronograph", "Ünique", "日本"]
UNKNOWN_KEYS = ["futureField", "zeta", "Zeta", "Ünknown", "日付", "a b"]
SLOT_KEYS = ["0", "1", "2", "3", "5", "7", "11", "05", "+5", " 5", "99", "-1", "007", "1e1", "٣", ""]
CUT_VALUES = [0.5, 0.25, 0.75, -0.5, 1.5, 0.04, 0.6, 0.3, 0, 1, 2, -1, "0.5", True, None]
TURNS = [0, 15.5, -200, 270, 90, -45.25, "15", True, None]
FLAGS = [True, True, False, 1, 0, "true", None]
COLUMNS = [6, 6, 5, 4, 3, 2, 0, -1, 2.5, "6", True, None]
ROWS = [2, 2, 2, 1, 4, 0, -2, 1.5, "2", False]


class Gen:
    # The pools, as class attributes so TwinGen can swap them.
    NAMES, STORIES, STATUSES, NUMBERS, PHOTOS = NAMES, STORIES, STATUSES, NUMBERS, PHOTOS
    WATCH_IDS, CANDIDATE_IDS, BRANDS, BOX_IDS, SESSION_IDS = WATCH_IDS, CANDIDATE_IDS, BRANDS, BOX_IDS, SESSION_IDS
    DATES, STRINGS, UNKNOWN_KEYS, SLOT_KEYS = DATES, STRINGS, UNKNOWN_KEYS, SLOT_KEYS
    CUT_VALUES, TURNS, FLAGS, COLUMNS, ROWS = CUT_VALUES, TURNS, FLAGS, COLUMNS, ROWS

    def __init__(self, rng):
        self.rng = rng

    def chance(self, p):
        return self.rng.random() < p

    def pick(self, seq):
        return self.rng.choice(seq)

    def scalar(self):
        return self.pick([self.pick(self.NAMES), self.pick(self.NUMBERS), True, False, None])

    def value(self, depth=0):
        roll = self.rng.random()
        if depth >= 2 or roll < 0.45:
            return self.scalar()
        if roll < 0.6:
            return self.rng.sample(self.STRINGS, self.rng.randint(0, 3))
        if roll < 0.7:
            return [self.pick(self.NUMBERS) for _ in range(self.rng.randint(1, 3))]
        if roll < 0.9:
            return {self.pick(self.UNKNOWN_KEYS + ["x", "y"]): self.value(depth + 1) for _ in range(self.rng.randint(0, 3))}
        return self.pick([[], {}])

    def cutout(self, photos):
        c = {"photo": self.pick(photos or ["a1.jpg"])}
        for key in ("x", "y", "r"):
            if self.chance(0.85):
                c[key] = self.pick(self.CUT_VALUES)
        if self.chance(0.5):
            c["turn"] = self.pick(self.TURNS)
        for flag in ("caseOnly", "useCutout"):
            if self.chance(0.4):
                c[flag] = self.pick(self.FLAGS)
        return c

    def session(self, sid):
        return {"id": sid, "date": self.pick(self.DATES), "durationMinutes": self.pick([15, 30, 60, 90, 0])}

    def watch(self, wid):
        w = {"id": wid, "name": self.pick(self.NAMES), "story": self.pick(self.STORIES), "purchasedText": "",
             "price": self.pick(self.NUMBERS), "status": self.pick(self.STATUSES), "statusNote": "",
             "photos": self.rng.sample(self.PHOTOS, self.rng.randint(0, 4))}
        if self.chance(0.5):
            w["brand"] = self.pick(self.BRANDS)
        if self.chance(0.3):
            w["diameter"] = self.pick([38.5, 40, 41.5, 42])
        if self.chance(0.2):
            w["purchased"] = self.pick([None, "2019-04"])
        if self.chance(0.3):
            w["wearDates"] = self.rng.sample(self.DATES, self.rng.randint(0, 3))
        if self.chance(0.4):
            w["wearSessions"] = [self.session(s) for s in self.rng.sample(self.SESSION_IDS, self.rng.randint(0, 3))]
        if self.chance(0.2):
            w["serviceRecords"] = [{"id": r, "date": self.pick(self.DATES), "kind": "Service", "notes": ""}
                                   for r in self.rng.sample(["r1", "r2", "r3"], self.rng.randint(0, 2))]
        if self.chance(0.35):
            w["boxCutout"] = self.cutout(w["photos"])
        if self.chance(0.2):
            w["boxTiles"] = {"black": "box-black-1a2b3c4d.jpg"}
        if self.chance(0.2) and w["photos"]:
            w["photoFocus"] = {w["photos"][0]: {"x": 0.5, "y": 0.25, "zoom": 1.25}}
        if self.chance(0.15):
            w[self.pick(self.UNKNOWN_KEYS)] = self.value()
        if self.chance(0.15):
            w["original"] = self.pick([True, False, 1, 0])
        return w

    def candidate(self, cid):
        c = {"id": cid, "name": self.pick(self.NAMES), "brand": self.pick(self.BRANDS), "priceNote": "", "notes": "",
             "status": self.pick(["considering", "next", "dream"]), "added": "2024-01",
             "photos": self.rng.sample(self.PHOTOS, self.rng.randint(0, 3))}
        if self.chance(0.5):
            c["priceExpected"] = self.pick(self.NUMBERS)
        if self.chance(0.25):
            c["boxCutout"] = self.cutout(c["photos"])
        if self.chance(0.15):
            c[self.pick(self.UNKNOWN_KEYS)] = self.value()
        if self.chance(0.1):
            c["category"] = None
        return c

    def box(self, bid, watch_ids):
        slots = {}
        for _ in range(self.rng.randint(0, 5)):
            slots[self.pick(self.SLOT_KEYS)] = self.pick(watch_ids * 4 + ["ghost", 7, None])
        b = {"id": bid, "name": self.pick(["Black Box", "Brown Box", "Travel", "Ève"]),
             "finish": self.pick(["black", "brown", "teal"]), "columns": self.pick(self.COLUMNS),
             "rows": self.pick(self.ROWS), "slots": slots}
        if self.chance(0.05):
            b["slots"] = self.pick([None, [], "x"])
        if self.chance(0.03):
            b.pop("slots")
        return b

    def document(self):
        watch_ids = self.rng.sample(self.WATCH_IDS, self.rng.randint(1, 4))
        d = {"settings": {"autoBackup": self.chance(0.5), "backupRemote": "gdrive:WatchCollection",
                          "lastBackup": None, "autoImage": self.chance(0.5),
                          "suggestExclude": self.rng.sample(self.STRINGS, self.rng.randint(0, 3)),
                          "wrist": {"inches": 6.75, "perfect": 39, "lugMax": 49}},
             "watches": [self.watch(w) for w in watch_ids],
             "categories": self.rng.sample(self.STRINGS, self.rng.randint(0, 4)),
             "wishlist": [self.candidate(c) for c in self.rng.sample(self.CANDIDATE_IDS, self.rng.randint(0, 2))],
             "brandWatchlist": [{"brand": b, "notes": "", "added": "2024-01"}
                                for b in self.rng.sample(self.BRANDS, self.rng.randint(0, 3))],
             "dialColors": self.rng.sample(["Black", "Blue", "White", "Green"], self.rng.randint(0, 3)),
             "materials": self.rng.sample(["Steel", "Titanium", "Gold"], self.rng.randint(0, 2))}
        if self.chance(0.8):
            count = self.rng.randint(9, 11) if self.chance(0.06) else self.rng.randint(0, 3)
            d["boxes"] = [self.box(b, watch_ids) for b in self.BOX_IDS[:count]]
            if d["boxes"] and self.chance(0.06):
                twin = deepcopy(self.pick(d["boxes"]))
                twin["name"] = "Twin"
                d["boxes"].insert(self.rng.randint(0, len(d["boxes"])), twin)
        if self.chance(0.3):
            d["emptyBoxTiles"] = {"black": "empty-black-1a2b3c4d.jpg"}
        if self.chance(0.2):
            d["headlineStats"] = {"owned": {"count": 3, "total": 1200.5}}
        if self.chance(0.15):
            d[self.pick(self.UNKNOWN_KEYS)] = self.value()
        if self.chance(0.1):
            d["settings"]["ownerName"] = None
        return d

    # Mutations: each edits a document in place and keeps every identity list a list of objects with
    # string ids (anything else makes sync.py raise, and such cases are not vectors).

    def items(self, d, kind):
        value = d.get(kind)
        return value if isinstance(value, list) else []

    def some_item(self, d):
        kind = self.pick(["watches", "watches", "wishlist"])
        items = [i for i in self.items(d, kind) if isinstance(i, dict)]
        return (kind, self.pick(items)) if items else (kind, None)

    def m_edit_field(self, d):
        _, item = self.some_item(d)
        if item is None:
            return
        key = self.pick(["name", "story", "price", "status", "statusNote", "brand", "notes", "diameter",
                         "priceExpected"] + self.UNKNOWN_KEYS)
        if self.chance(0.75):
            item[key] = self.pick(self.NAMES) if key in ("name", "story", "brand", "notes", "statusNote") else (
                self.pick(self.STATUSES) if key == "status" else self.pick(self.NUMBERS))
        else:
            item[key] = self.value()

    def m_delete_field(self, d):
        _, item = self.some_item(d)
        if item:
            keys = [k for k in item if k != "id"]
            if keys:
                item.pop(self.pick(keys))

    def m_null_field(self, d):
        _, item = self.some_item(d)
        if item:
            item[self.pick(["purchased", "brand", "category", "story", "boxCutout"])] = None

    def m_add_item(self, d):
        kind = self.pick(["watches", "wishlist", "brandWatchlist"])
        items = d.setdefault(kind, []) if isinstance(d.get(kind, []), list) else None
        if items is None:
            return
        if kind == "brandWatchlist":
            taken = {i.get("brand") for i in items}
            free = [b for b in self.BRANDS if b not in taken]
            if free:
                items.insert(self.rng.randint(0, len(items)), {"brand": self.pick(free), "notes": self.pick(self.NAMES),
                                                               "added": "2026-11"})
            return
        pool = self.WATCH_IDS if kind == "watches" else self.CANDIDATE_IDS
        taken = {i.get("id") for i in items}
        free = [i for i in pool if i not in taken]
        if free:
            new = self.watch(self.pick(free)) if kind == "watches" else self.candidate(self.pick(free))
            items.insert(self.rng.randint(0, len(items)), new)

    def m_delete_item(self, d):
        kind = self.pick(["watches", "wishlist", "brandWatchlist", "boxes"])
        items = self.items(d, kind)
        if items:
            items.pop(self.rng.randrange(len(items)))

    def m_reorder(self, d):
        items = self.items(d, self.pick(["watches", "wishlist", "brandWatchlist", "boxes", "boxes"]))
        if len(items) > 1:
            i, j = self.rng.sample(range(len(items)), 2)
            items[i], items[j] = items[j], items[i]

    def m_photos(self, d):
        _, item = self.some_item(d)
        if not item or not isinstance(item.get("photos"), list):
            return
        photos = item["photos"]
        roll = self.rng.random()
        if roll < 0.3:
            free = [p for p in self.PHOTOS if p not in photos]
            if free:
                photos.insert(self.rng.randint(0, len(photos)), self.pick(free))
        elif roll < 0.55 and photos:
            photos.pop(self.rng.randrange(len(photos)))
        elif roll < 0.85 and len(photos) > 1:
            photos.insert(0, photos.pop(self.rng.randrange(1, len(photos))))
        else:
            self.rng.shuffle(photos)

    def m_sessions(self, d):
        watches = [w for w in self.items(d, "watches") if isinstance(w, dict)]
        if not watches:
            return
        w = self.pick(watches)
        sessions = w.get("wearSessions")
        if not isinstance(sessions, list) or not all(isinstance(s, dict) for s in sessions):
            w["wearSessions"] = sessions = []
        roll = self.rng.random()
        if roll < 0.35:
            taken = {s.get("id") for s in sessions}
            free = [s for s in self.SESSION_IDS if s not in taken]
            if free:
                sessions.append(self.session(self.pick(free)))
        elif roll < 0.55 and sessions:
            sessions.pop(self.rng.randrange(len(sessions)))
        elif roll < 0.8 and sessions:
            self.pick(sessions)["durationMinutes"] = self.pick([5, 45, 120])
        elif roll < 0.9:
            w["wearSessions"] = []
        else:
            w["wearDates"] = self.rng.sample(self.DATES, self.rng.randint(0, 2))

    def m_settings(self, d):
        s = d.get("settings")
        if not isinstance(s, dict):
            return
        roll = self.rng.random()
        if roll < 0.2:
            s["autoImage"] = self.pick([True, False, 1, 0])
        elif roll < 0.4:
            s["suggestExclude"] = self.rng.sample(self.STRINGS, self.rng.randint(0, 3))
        elif roll < 0.6 and isinstance(s.get("wrist"), dict):
            s["wrist"][self.pick(["inches", "perfect", "lugMax"])] = self.pick([6.5, 7.25, 40, 48])
        elif roll < 0.75:
            s["autoBackup"] = self.chance(0.5)
            s["lastBackup"] = self.pick([None, "2026-11-15"])
        elif roll < 0.85:
            s.pop(self.pick(["wrist", "suggestExclude", "autoImage", "autoBackup"]), None)
        elif roll < 0.97:
            s[self.pick(self.UNKNOWN_KEYS)] = self.value()
        else:
            d.pop("settings")

    def m_strings(self, d):
        kind = self.pick(["categories", "dialColors", "materials"])
        values = d.get(kind)
        roll = self.rng.random()
        if not isinstance(values, list) or roll < 0.05:
            d[kind] = self.rng.sample(self.STRINGS, self.rng.randint(0, 3))
        elif roll < 0.35:
            free = [v for v in self.STRINGS if v not in values]
            if free:
                values.insert(self.rng.randint(0, len(values)), self.pick(free))
        elif roll < 0.6 and values:
            values.pop(self.rng.randrange(len(values)))
        elif roll < 0.8:
            self.rng.shuffle(values)
        elif roll < 0.88:
            d[kind] = []
        elif roll < 0.94:
            d[kind] = [self.pick(self.NUMBERS)]
        else:
            d.pop(kind)

    def m_box(self, d):
        boxes = d.get("boxes")
        watch_ids = [w.get("id") for w in self.items(d, "watches") if isinstance(w, dict)] or ["w1"]
        roll = self.rng.random()
        if not isinstance(boxes, list):
            if roll < 0.5:
                d["boxes"] = [self.box(b, watch_ids) for b in self.BOX_IDS[:self.rng.randint(0, 2)]]
            return
        good = [b for b in boxes if isinstance(b, dict) and isinstance(b.get("slots"), dict)]
        if roll < 0.35 and good:
            b = self.pick(good)
            if b["slots"] and self.chance(0.5):
                key = self.pick(list(b["slots"]))
                b["slots"][self.pick(self.SLOT_KEYS)] = b["slots"].pop(key)
            else:
                b["slots"][self.pick(self.SLOT_KEYS)] = self.pick(watch_ids + ["ghost"])
        elif roll < 0.5 and good:
            b = self.pick(good)
            if b["slots"]:
                b["slots"].pop(self.pick(list(b["slots"])))
        elif roll < 0.6 and good:
            b = self.pick(good)
            b[self.pick(["columns", "rows"])] = self.pick(self.COLUMNS + self.ROWS)
        elif roll < 0.7 and good:
            self.pick(good)["name"] = self.pick(self.NAMES)
        elif roll < 0.8:
            taken = {b.get("id") for b in boxes if isinstance(b, dict)}
            free = [b for b in self.BOX_IDS if b not in taken]
            if free:
                boxes.insert(self.rng.randint(0, len(boxes)), self.box(self.pick(free), watch_ids))
        elif roll < 0.9 and boxes:
            boxes.pop(self.rng.randrange(len(boxes)))
        elif roll < 0.95:
            d.pop("boxes")
        else:
            d["boxes"] = []

    def m_cutout(self, d):
        _, item = self.some_item(d)
        if not item:
            return
        c = item.get("boxCutout")
        if not isinstance(c, dict) or self.chance(0.2):
            item["boxCutout"] = self.cutout(item.get("photos") if isinstance(item.get("photos"), list) else [])
        elif self.chance(0.2):
            item.pop("boxCutout")
        else:
            key = self.pick(["x", "y", "r", "turn", "caseOnly", "useCutout"])
            c[key] = self.pick(self.TURNS if key == "turn" else self.FLAGS if key in ("caseOnly", "useCutout") else self.CUT_VALUES)

    def m_status(self, d):
        watches = [w for w in self.items(d, "watches") if isinstance(w, dict)]
        if watches:
            w = self.pick(watches)
            w["status"] = "sold" if w.get("status") == "owned" else "owned"

    def m_duplicate(self, d):
        watches = self.items(d, "watches")
        if watches:
            twin = deepcopy(self.pick(watches))
            twin["name"] = "Twin " + str(twin.get("name"))
            watches.insert(self.rng.randint(0, len(watches)), twin)

    def m_top(self, d):
        roll = self.rng.random()
        if roll < 0.4:
            d[self.pick(self.UNKNOWN_KEYS)] = self.value()
        elif roll < 0.6:
            d["emptyBoxTiles"] = self.pick([{"black": "empty-black-9f8e7d6c.jpg"},
                                            {"black": "empty-black-1a2b3c4d.jpg", "brown": "empty-brown-1.jpg"}])
        elif roll < 0.7:
            d.pop("emptyBoxTiles", None)
        elif roll < 0.85:
            d["headlineStats"] = {"owned": {"count": self.pick(self.NUMBERS)}}
        else:
            for key in self.UNKNOWN_KEYS:
                d.pop(key, None)

    def m_nested(self, d):
        _, item = self.some_item(d)
        if not item:
            return
        if self.chance(0.5):
            photos = item.get("photos") if isinstance(item.get("photos"), list) else []
            focus = item.get("photoFocus") if isinstance(item.get("photoFocus"), dict) else {}
            focus[self.pick(photos or self.PHOTOS)] = {"x": self.pick([0.5, 0.25]), "y": 0.5, "zoom": self.pick([1, 1.5])}
            item["photoFocus"] = focus
        else:
            item["boxTiles"] = self.pick([{"black": "box-black-aaaa1111.jpg"},
                                          {"black": "box-black-1a2b3c4d.jpg", "brown": "box-brown-bbbb2222.jpg"},
                                          {}])

    MUTATIONS = ["m_edit_field", "m_edit_field", "m_edit_field", "m_delete_field", "m_null_field", "m_add_item",
                 "m_delete_item", "m_reorder", "m_photos", "m_photos", "m_sessions", "m_settings", "m_strings",
                 "m_box", "m_box", "m_box", "m_cutout", "m_status", "m_duplicate", "m_top", "m_nested"]

    def mutate(self, d, count):
        for _ in range(count):
            getattr(self, self.pick(self.MUTATIONS))(d)
        return d

    # Contests: the same place changed differently on the two sides, so conflicts and their resolutions
    # are common in the random set. Ids and brands are left alone (a number there gives Python a path
    # with a number in it, which no Swift conflict can hold).

    def addresses(self, value, trail=()):
        if isinstance(value, dict):
            for key, child in value.items():
                if key in ("id", "brand"):
                    continue
                yield trail + (key,)
                yield from self.addresses(child, trail + (key,))
        elif isinstance(value, list):
            for index, child in enumerate(value):
                if isinstance(child, dict):
                    yield trail + (index,)
                    yield from self.addresses(child, trail + (index,))

    def rival(self, current):
        if self.chance(0.15):
            return self.value()
        if isinstance(current, bool):
            return self.pick([True, False, 1, 0])
        if isinstance(current, (int, float)):
            return self.pick(self.NUMBERS)
        if isinstance(current, str):
            return self.pick(self.NAMES + self.STATUSES + self.WATCH_IDS)
        if isinstance(current, list):
            return self.rng.sample(self.STRINGS, self.rng.randint(0, 3))
        if isinstance(current, dict):
            changed = dict(current)
            changed[self.pick(list(current) + self.UNKNOWN_KEYS) if current else self.pick(self.UNKNOWN_KEYS)] = self.scalar()
            return changed
        return self.scalar()

    def contest(self, local, remote):
        places = [a for a in self.addresses(local) if len(a) > 1]
        if not places:
            return
        place = self.pick(places)
        parents = []
        for side in (local, remote):
            node = side
            for step in place[:-1]:
                node = node[step]
            parents.append(node)
        last = place[-1]
        roll = self.rng.random()
        for side_index, parent in enumerate(parents):
            deletes = (roll < 0.15 and side_index == 0) or (0.15 <= roll < 0.3 and side_index == 1)
            if deletes:
                parent.pop(last)
            elif isinstance(last, int):
                entry = parent[last]
                key = self.pick([k for k in entry if k not in ("id", "brand")] or ["notes"])
                entry[key] = self.rival(entry.get(key))
            else:
                parent[last] = self.rival(parent[last])


class TwinGen(Gen):
    """Gen with look-alike pools (review A6, A8): ids, list strings, brands and photo names in pairs that
    are canonically equivalent but spelled with other code points (NFC and NFD, K and KELVIN SIGN, A-ring
    and ANGSTROM SIGN, ";" and GREEK QUESTION MARK, a Hangul syllable and its jamo), which Python keeps
    apart; compatibility look-alikes nothing may fold (the fi ligature, fullwidth letters and digits);
    floats with a whole value; integers past 2^53 that a Double holds. A case that would hand the merge
    look-alike object keys or a whole-float box size is skipped (swift_reads_alike): those are known
    differences, each pinned by a hand-written case."""
    NAMES = Gen.NAMES + ["Caf\u00e9", "\u212a\u00e9", "\uff2b2"]
    NUMBERS = Gen.NUMBERS + [42.0, 1.0, -0.0, 6.0, 1e16, 2 ** 53 + 2, -(2 ** 53 + 2), 2 ** 60]
    PHOTOS = ["a1.jpg", "caf\u00e9.jpg", "cafe\u0301.jpg", "K.jpg", "\u212a.jpg", "\uff2b.jpg"]
    WATCH_IDS = ["w1", "w2", "\u00e91", "e\u03011", "K", "\u212a", "\u00c5", "\u212b", "\ufb01", "fi"]
    CANDIDATE_IDS = ["c1", "c2", "\u00e7", "c\u0327", ";", "\u037e"]
    BRANDS = ["Omega", "Tudor", "\u00c9lan", "E\u0301lan", "\u00c5ngstr\u00f6m", "\u212bngstr\u00f6m"]
    BOX_IDS = ["black", "\u00e9", "e\u0301", "brown", "\u00c5", "\u212b", "b7", "b8", "b9", "b10", "b11"]
    SESSION_IDS = ["s1", "\u00e9", "e\u0301", "K", "\u212a"]
    STRINGS = ["Dive", "GMT", "Caf\u00e9", "Cafe\u0301", "\u00c5", "\u212b", ";", "\u037e", "\ud55c",
               "\u1112\u1161\u11ab", "\ufb01eld", "field"]
    SLOT_KEYS = Gen.SLOT_KEYS + ["\uff15"]


def look_alike_strings(*docs):
    """True when two string values anywhere in docs are canonically equivalent but spelled differently."""
    strings = set()

    def collect(value):
        if isinstance(value, str):
            strings.add(value)
        elif isinstance(value, dict):
            for child in value.values():
                collect(child)
        elif isinstance(value, list):
            for child in value:
                collect(child)
    for d in docs:
        collect(d)
    folded = {}
    for s in strings:
        folded.setdefault(unicodedata.normalize("NFC", s), set()).add(s)
    return any(len(spellings) > 1 for spellings in folded.values())


def random_case(rng, name, gen_class=Gen):
    """One random vector, or None when its inputs reach a known difference (swift_reads_alike)."""
    gen = gen_class(rng)
    seed_doc = gen.document()
    mode = rng.random()
    if mode < 0.12:
        base = None
    elif mode < 0.2:
        base = deepcopy(seed_doc)
        base.pop("boxes", None)
    else:
        base = deepcopy(seed_doc)
    local, remote = deepcopy(seed_doc), deepcopy(seed_doc)
    if rng.random() < 0.35:
        shared = rng.random()
        count = rng.randint(1, 3)
        gen_class(random.Random(shared)).mutate(local, count)
        gen_class(random.Random(shared)).mutate(remote, count)
    for _ in range(rng.choice([0, 0, 1, 1, 2, 3])):
        gen.contest(local, remote)
    gen.mutate(local, rng.randint(0, 4))
    gen.mutate(remote, rng.randint(0, 4))
    if rng.random() < 0.03:
        remote = gen.document()  # an unrelated document
    if not swift_reads_alike(base, local, remote):
        return None
    _, first = sync.merge(deepcopy(base), deepcopy(local), deepcopy(remote), {})
    resolve = []
    for conflict in first:
        roll = rng.random()
        if roll < 0.35:
            resolve.append((conflict["path"], "local"))
        elif roll < 0.65:
            resolve.append((conflict["path"], "remote"))
        elif roll < 0.7:
            resolve.append((conflict["path"], "both"))
    return vector(name, base, local, remote, resolve)


def family(seed, count, gen_class, prefix):
    """count random vectors named "<prefix> 000" on, and how many inputs sync.py raised on or were skipped."""
    rng = random.Random(seed)
    made, raised, skipped = [], 0, 0
    while len(made) < count:
        try:
            made_vector = random_case(rng, "%s %03d" % (prefix, len(made)), gen_class)
        except (KeyError, TypeError, AttributeError, IndexError):
            raised += 1  # sync.py itself raises on this input; not a vector
            continue
        if made_vector is None:
            skipped += 1
        else:
            made.append(made_vector)
    return made, raised, skipped


def main():
    vectors = hand_cases()
    hand = len(vectors)
    randoms, raised, skipped = family(SEED, RANDOM_COUNT, Gen, "random")
    assert skipped == 0, "the plain pools reached a known difference"
    twins, twins_raised, twins_skipped = family(TWIN_SEED, TWIN_COUNT, TwinGen, "twins")
    vectors += randoms + twins
    names = [v["name"] for v in vectors]
    assert len(names) == len(set(names)), "vector names must be unique"
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", encoding="utf-8") as handle:
        handle.write('{"seed": %d, "random": %d, "twinSeed": %d, "twins": %d, "vectors": [\n'
                     % (SEED, RANDOM_COUNT, TWIN_SEED, TWIN_COUNT))
        handle.write(",\n".join(json.dumps(v, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
                                for v in vectors))
        handle.write("\n]}\n")
    print("wrote %s" % OUT.relative_to(ROOT))
    print("vectors: %d (%d hand-written, %d of them refused by sync.py; %d random, %d inputs skipped because "
          "sync.py raised; %d twins, %d raised, %d skipped as known differences)"
          % (len(vectors), hand, sum("raises" in v for v in vectors[:hand]), len(randoms), raised, len(twins),
             twins_raised, twins_skipped))
    for label, made in (("random", randoms), ("twins", twins)):
        print("%s: %d with no base, %d with conflicts left, %d with resolutions, %d with boxes in the output, "
              "%d with look-alike strings, %d ids not comparable"
              % (label, sum(v["base"] is None for v in made), sum(bool(v["conflicts"]) for v in made),
                 sum(bool(v["resolveByPath"]) for v in made), sum("boxes" in v["output"] for v in made),
                 sum(look_alike_strings(v["base"], v["local"], v["remote"]) for v in made),
                 sum(not v["idsComparable"] for v in made)))


if __name__ == "__main__":
    main()
