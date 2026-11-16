"""Three-way collection sync. Missing baselines never imply deletions."""
from copy import deepcopy
import hashlib
import json
import re

MISSING = object()
COLLECTIONS = {"watches": "id", "wishlist": "id", "brandWatchlist": "brand",
               "wearSessions": "id", "serviceRecords": "id", "boxes": "id"}
SETTINGS = {"autoImage", "suggestExclude", "wrist"}
TOP = {"settings", "watches", "wishlist", "brandWatchlist", "categories", "dialColors", "materials",
       "boxes", "emptyBoxTiles"}
MAX_BOXES = 8
# Identity lists whose order means something (the boxes' order is the order of their tabs). Their
# merge keeps the client's order when only the client reordered; every other list keeps the hub's.
ORDERED = {"boxes"}
# A slot key is the compartment index written the one way Swift and Python both read it: "5", never "05" or "+5".
SLOT_KEY = re.compile(r"0|[1-9][0-9]*")


def clean_boxes(data):
    """The Python twin of BoxModel.sanitized in the app: the same four rules in the same order.

    1. Drop slot keys that are not a decimal integer in 0..<columns*rows.
    2. Drop slots whose watch id is not a watch with status owned.
    3. A watch id placed more than once keeps its first place (box order, then numeric slot order).
    4. Boxes beyond the eighth are dropped; duplicate box ids keep the first.
    Works in place and returns data.
    """
    boxes = data.get("boxes")
    if not isinstance(boxes, list):
        return data
    owned = {watch.get("id") for watch in data.get("watches", [])
             if isinstance(watch, dict) and watch.get("status") == "owned"}
    placed = set()
    for box in boxes:
        if not isinstance(box, dict) or not isinstance(box.get("slots"), dict):
            continue
        columns, rows = box.get("columns"), box.get("rows")
        sizes_ok = all(isinstance(v, int) and not isinstance(v, bool) for v in (columns, rows))
        capacity = max(0, columns) * max(0, rows) if sizes_ok else 0
        slots = box["slots"]
        candidates = sorted(
            (int(key), key) for key, value in slots.items()
            if isinstance(key, str) and SLOT_KEY.fullmatch(key) and int(key) < capacity
            and isinstance(value, str) and value in owned
        )
        kept = set()
        for _index, key in candidates:
            if slots[key] in placed:
                continue
            placed.add(slots[key])
            kept.add(key)
        box["slots"] = {key: value for key, value in slots.items() if key in kept}
    seen = set()
    survivors = []
    for box in boxes[:MAX_BOXES]:
        identity = box.get("id") if isinstance(box, dict) else None
        if isinstance(identity, str):
            if identity in seen:
                continue
            seen.add(identity)
        survivors.append(box)
    data["boxes"] = survivors
    return data


def normalize(data):
    result = {key: deepcopy(value) for key, value in data.items() if key in TOP}
    result["settings"] = {k: v for k, v in result.get("settings", {}).items() if k in SETTINGS}
    for kind in ("watches", "wishlist"):
        for item in result.get(kind, []):
            for key in list(item):
                if item[key] is None or (key in ("wearDates", "wearSessions", "serviceRecords") and not item[key]):
                    item.pop(key)
    return result


def reordered(old, new):
    """True when the ids the two lists share are in a different order in `new` than in `old`.

    Adding or removing an entry is not a reorder; only moving one past another is.
    """
    shared = set(old) & set(new)
    return [key for key in old if key in shared] != [key for key in new if key in shared]


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()).hexdigest()


def merge(base, local, remote, resolutions=None):
    """Return a proposal and conflicts; the caller commits only without conflicts.

    Resolution IDs include both values, so choices cannot overwrite a newer edit.
    Dictionary and identity-list recursion preserve independent changes. Concurrent
    delete/edit is a conflict. Lists of strings retain additions from either side.
    """
    conflicts = []
    resolutions = resolutions or {}
    if base is None or "boxes" not in base:
        # No common past for the boxes (a first join, a changed sync address, a device that set its
        # boxes up with sync off): a key-by-key merge would mix two arrangements and quietly undo
        # moves, so boxes the hub already has win whole and the client's are dropped.
        if isinstance(remote.get("boxes"), list) and remote["boxes"] and "boxes" in local:
            local = {key: value for key, value in local.items() if key != "boxes"}

    def conflict(path, left, right):
        values = {"path": path, "local": None if left is MISSING else left,
                  "remote": None if right is MISSING else right,
                  "localDeleted": left is MISSING, "remoteDeleted": right is MISSING}
        key = fingerprint(values)
        if resolutions.get(key) == "local":
            return left
        if resolutions.get(key) == "remote":
            return right
        conflicts.append({"id": key, **values})
        return right

    def walk(old, left, right, path):
        if left == right:
            return left
        if old is not MISSING:
            if left == old:
                return right
            if right == old:
                return left
            if left is MISSING or right is MISSING:
                return conflict(path, left, right)
        else:
            if left is MISSING:
                return right
            if right is MISSING:
                return left
        if isinstance(left, dict) and isinstance(right, dict):
            previous = old if isinstance(old, dict) else {}
            result = {}
            for key in sorted(previous.keys() | left.keys() | right.keys()):
                value = walk(previous.get(key, MISSING), left.get(key, MISSING), right.get(key, MISSING), path + [key])
                if value is not MISSING:
                    result[key] = value
            return result
        if isinstance(left, list) and isinstance(right, list):
            previous = old if isinstance(old, list) else []
            identity = COLLECTIONS.get(path[-1] if path else "")
            if identity:
                indexes = [{v[identity]: v for v in values} for values in (previous, left, right)]
                ids = [[v[identity] for v in values] for values in (previous, left, right)]
                keys = list(dict.fromkeys(ids[2] + ids[1] + ids[0]))
                if len(path) == 1 and path[0] in ORDERED and reordered(ids[0], ids[1]) \
                        and not reordered(ids[0], ids[2]):
                    # Only the client moved entries: its order stands, the hub's additions go after it.
                    keys = list(dict.fromkeys(ids[1] + ids[2] + ids[0]))
                result = []
                for key in keys:
                    value = walk(*(index.get(key, MISSING) for index in indexes), path + [key])
                    if value is not MISSING:
                        result.append(value)
                return result
            if all(isinstance(v, str) for v in previous + left + right):
                # Order follows the phone if it reordered the baseline (photo covers).
                order = left + right if left != previous else right + left
                return [v for v in dict.fromkeys(order) if v not in previous or (v in left and v in right)]
        return conflict(path, left, right)

    result = walk(normalize(base) if base is not None else MISSING, normalize(local), normalize(remote), [])
    # Device-specific backup preferences and unknown top-level metadata stay on the server.
    output = deepcopy(remote)
    output.update({k: v for k, v in result.items() if k != "settings"})
    output.setdefault("settings", {}).update(result.get("settings", {}))
    if "boxes" in output:
        clean_boxes(output)
    return output, conflicts
