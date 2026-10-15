"""Three-way collection sync. Missing baselines never imply deletions."""
from copy import deepcopy
import hashlib
import json

MISSING = object()
COLLECTIONS = {"watches": "id", "wishlist": "id", "brandWatchlist": "brand",
               "wearSessions": "id", "serviceRecords": "id"}
SETTINGS = {"autoImage", "suggestExclude", "wrist"}
TOP = {"settings", "watches", "wishlist", "brandWatchlist", "categories", "dialColors", "materials"}


def normalize(data):
    result = {key: deepcopy(value) for key, value in data.items() if key in TOP}
    result["settings"] = {k: v for k, v in result.get("settings", {}).items() if k in SETTINGS}
    for kind in ("watches", "wishlist"):
        for item in result.get(kind, []):
            for key in list(item):
                if item[key] is None or (key in ("wearDates", "wearSessions", "serviceRecords") and not item[key]):
                    item.pop(key)
    return result


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
                keys = list(dict.fromkeys([v[identity] for v in right + left + previous]))
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
    return output, conflicts
