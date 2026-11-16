"""Sync regressions against an isolated copy, never the personal collection."""
from copy import deepcopy
import base64
import hashlib
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest import mock
from urllib.request import Request, urlopen
from urllib.error import HTTPError
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import server
from sync import clean_boxes, merge, normalize


def collection():
    return {"settings": {"autoBackup": True, "backupRemote": "local", "autoImage": True,
                          "wrist": {"inches": 6, "sweetSpotMin": 35, "sweetSpotMax": 40, "perfect": 38, "lugMax": 47},
                          "ownerName": "Test owner"},
            "watches": [{"id": "field", "name": "Field", "story": "Original", "purchased": None,
                         "purchasedText": "", "diameter": 38, "lugToLug": None, "price": 100,
                         "original": True, "status": "owned", "statusNote": "", "photos": [],
                         "category": "Field", "dialColor": "Black", "material": "Steel"}],
            "categories": ["Field"], "dialColors": ["Black"], "materials": ["Steel"],
            "wishlist": [], "brandWatchlist": []}


class MergeTests(unittest.TestCase):
    def test_first_join_keeps_both_devices_unique_records(self):
        local, remote = collection(), collection()
        remote["watches"].append({**deepcopy(remote["watches"][0]), "id": "hamilton", "name": "Hamilton"})
        local["watches"].append({**deepcopy(local["watches"][0]), "id": "phone-only"})
        result, conflicts = merge(None, local, remote)
        self.assertFalse(conflicts)
        self.assertEqual({w["id"] for w in result["watches"]}, {"field", "hamilton", "phone-only"})

    def test_independent_edits_and_wear_history_merge(self):
        base = collection()
        phone, mac = deepcopy(base), deepcopy(base)
        phone["watches"][0]["story"] = "Wore it hiking"
        phone["watches"][0]["wearSessions"] = [{"id": "phone", "date": "2026-09-20", "durationMinutes": 60}]
        mac["watches"][0]["price"] = 970
        mac["watches"][0]["wearSessions"] = [{"id": "mac", "date": "2026-09-19", "durationMinutes": 30}]
        merged, conflicts = merge(base, phone, mac)
        self.assertFalse(conflicts)
        self.assertEqual(merged["watches"][0]["story"], "Wore it hiking")
        self.assertEqual(merged["watches"][0]["price"], 970)
        self.assertEqual(len(merged["watches"][0]["wearSessions"]), 2)
        repeated, conflicts = merge(base, phone, merged)
        self.assertFalse(conflicts)
        self.assertEqual(repeated, merged)

    def test_deletion_only_after_known_baseline(self):
        base = collection()
        phone = deepcopy(base)
        phone["watches"] = []
        self.assertEqual(merge(base, phone, base)[0]["watches"], [])
        self.assertEqual(len(merge(None, phone, base)[0]["watches"]), 1)
        mac = deepcopy(base)
        mac["watches"][0]["story"] = "Edited on Mac"
        self.assertTrue(merge(base, phone, mac)[1])

    def test_conflict_choice_is_bound_to_exact_values(self):
        base = collection()
        phone, mac = deepcopy(base), deepcopy(base)
        phone["watches"][0]["story"] = "Phone"
        mac["watches"][0]["story"] = "Mac"
        _, conflicts = merge(base, phone, mac)
        choices = {conflicts[0]["id"]: "local"}
        merged, conflicts = merge(base, phone, mac, choices)
        self.assertFalse(conflicts)
        self.assertEqual(merged["watches"][0]["story"], "Phone")
        mac["watches"][0]["story"] = "Newer Mac edit"
        self.assertTrue(merge(base, phone, mac, choices)[1])

    def test_optional_nulls_and_device_preferences_do_not_conflict(self):
        phone, mac = collection(), collection()
        phone["watches"][0].pop("lugToLug")
        phone["watches"][0]["wearSessions"] = []
        phone["settings"]["autoBackup"] = False
        phone["settings"].pop("ownerName")
        merged, conflicts = merge(None, phone, mac)
        self.assertFalse(conflicts)
        self.assertTrue(merged["settings"]["autoBackup"])
        self.assertEqual(merged["settings"]["ownerName"], "Test owner")

    def test_photo_additions_and_deletions_merge(self):
        base = collection()
        base["watches"][0]["photos"] = ["old.jpg", "keep.jpg"]
        phone, mac = deepcopy(base), deepcopy(base)
        phone["watches"][0]["photos"] = ["phone.jpg", "keep.jpg"]
        mac["watches"][0]["photos"] = ["mac.jpg", "old.jpg", "keep.jpg"]
        merged, conflicts = merge(base, phone, mac)
        self.assertFalse(conflicts)
        self.assertEqual(merged["watches"][0]["photos"], ["phone.jpg", "keep.jpg", "mac.jpg"])


class SyncAPITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="watch-sync-test-")
        self.original_paths = server.DATA_FILE, server.PHOTOS_DIR
        server.DATA_FILE = Path(self.temp.name) / "watches.json"
        server.PHOTOS_DIR = Path(self.temp.name) / "photos"
        server.PHOTOS_DIR.mkdir()
        self.seed = collection()
        server.atomic_write_data(self.seed)
        self.httpd = server.WatchServer(("127.0.0.1", 0), server.WatchHandler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join()
        server.DATA_FILE, server.PHOTOS_DIR = self.original_paths
        self.temp.cleanup()

    def request(self, method, route, payload=None, headers=None):
        req = Request(f"http://127.0.0.1:{self.httpd.server_port}" + route, method=method,
                      data=json.dumps(payload).encode() if payload is not None else None,
                      headers={"Content-Type": "application/json", **(headers or {})})
        try:
            with urlopen(req, timeout=3) as response:
                return response.status, json.load(response)
        except HTTPError as response:
            return response.code, json.load(response)

    def test_exchange_and_lost_response_retry_are_idempotent(self):
        local = deepcopy(self.seed)
        local["watches"][0]["price"] = 970
        request = {"base": self.seed, "local": local}
        status, result = self.request("POST", "/api/sync", request)
        self.assertEqual(status, 200)
        self.assertFalse(result["conflicts"])
        self.assertEqual(result["data"]["watches"][0]["price"], 970)
        self.assertEqual(self.request("POST", "/api/sync", request)[1], result)
        self.assertEqual(len(list((server.DATA_FILE.parent / "sync-history").glob("*.json"))), 1)

    def test_conflict_does_not_write_either_version(self):
        local, mac = deepcopy(self.seed), deepcopy(self.seed)
        local["watches"][0]["price"] = 970
        mac["watches"][0]["price"] = 800
        server.atomic_write_data(mac)
        status, response = self.request("POST", "/api/sync", {"base": self.seed, "local": local})
        self.assertEqual(status, 200)
        self.assertEqual(len(response["conflicts"]), 1)
        self.assertEqual(server.read_data(), mac)

    def test_photo_upload_replay_collision_and_reference_commit(self):
        local = deepcopy(self.seed)
        local["watches"][0]["photos"] = ["phone.jpg"]
        self.assertEqual(self.request("POST", "/api/sync", {"base": self.seed, "local": local})[0], 409)
        payload = {"data": base64.b64encode(b"test-photo").decode()}
        self.assertEqual(self.request("POST", "/api/sync/photos/field/phone.jpg", payload)[0], 200)
        self.assertEqual(self.request("POST", "/api/sync/photos/field/phone.jpg", payload)[0], 200)
        self.assertEqual(self.request("POST", "/api/sync/photos/field/phone.jpg", {"data": "YWJj"})[0], 409)
        status, result = self.request("POST", "/api/sync", {"base": self.seed, "local": local})
        self.assertEqual(status, 200)
        self.assertEqual(result["photos"], ["field/phone.jpg"])

    def test_invalid_payloads_and_cross_origin_are_rejected(self):
        local = deepcopy(self.seed)
        local["watches"].append(deepcopy(local["watches"][0]))
        self.assertEqual(self.request("POST", "/api/sync", {"base": None, "local": local})[0], 400)
        self.assertEqual(self.request("POST", "/api/sync", {"local": self.seed}, {"Origin": "https://example.com"})[0], 403)
        self.assertEqual(self.request("POST", "/api/sync/photos/../bad.jpg", {"data": "YWJj"})[0], 400)
        self.assertEqual(server.read_data(), self.seed)

    def test_web_edit_preserves_new_phone_fields_and_rejects_conflicts(self):
        old = deepcopy(self.seed["watches"][0])
        current = deepcopy(self.seed)
        current["watches"][0]["story"] = "Phone edit"
        server.atomic_write_data(current)
        status, result = self.request("PUT", "/api/watches/field", {"base": old, "changes": {"story": old["story"], "price": 970}})
        self.assertEqual(status, 200)
        self.assertEqual(result["story"], "Phone edit")
        self.assertEqual(result["price"], 970)
        status, _ = self.request("PUT", "/api/watches/field", {"base": old, "changes": {"story": "Web edit"}})
        self.assertEqual(status, 409)
        self.assertEqual(server.read_data()["watches"][0]["story"], "Phone edit")


def watch(watch_id, status="owned"):
    return {"id": watch_id, "name": watch_id.title(), "story": "", "purchased": None, "purchasedText": "",
            "diameter": 40, "lugToLug": None, "price": 100, "original": True, "status": status,
            "statusNote": "", "photos": [], "category": "Field", "dialColor": "Black", "material": "Steel"}


def boxed():
    """The test collection with three more watches (one sold) and two 6 by 2 boxes."""
    data = collection()
    data["watches"] += [watch("diver"), watch("dress"), watch("sold-one", status="sold")]
    data["boxes"] = [
        {"id": "black", "name": "Black Box", "finish": "black", "columns": 6, "rows": 2, "slots": {"0": "field"}},
        {"id": "brown", "name": "Brown Box", "finish": "brown", "columns": 6, "rows": 2, "slots": {}},
    ]
    return data


def slots(data, box_id):
    return next(box for box in data["boxes"] if box["id"] == box_id)["slots"]


def jpeg(label):
    return b"\xff\xd8\xff\xe0" + label.encode() + b"\xff\xd9"


def tile_name(prefix, finish, payload):
    return f"{prefix}-{finish}-{hashlib.sha256(payload).hexdigest()[:8]}.jpg"


class BoxMergeTests(unittest.TestCase):
    def test_first_join_brings_the_phones_boxes(self):
        local, remote = boxed(), boxed()
        remote.pop("boxes")
        for base in (None, deepcopy(remote)):
            merged, conflicts = merge(base, local, remote)
            self.assertFalse(conflicts)
            self.assertEqual(merged["boxes"], local["boxes"])

    def test_independent_slot_edits_merge_without_conflict(self):
        base = boxed()
        phone, mac = deepcopy(base), deepcopy(base)
        slots(phone, "black")["1"] = "diver"
        slots(mac, "brown")["4"] = "dress"
        merged, conflicts = merge(base, phone, mac)
        self.assertFalse(conflicts)
        self.assertEqual(slots(merged, "black"), {"0": "field", "1": "diver"})
        self.assertEqual(slots(merged, "brown"), {"4": "dress"})

    def test_same_slot_different_watches_is_one_conflict(self):
        base = boxed()
        phone, mac = deepcopy(base), deepcopy(base)
        slots(phone, "black")["5"] = "diver"
        slots(mac, "black")["5"] = "dress"
        _, conflicts = merge(base, phone, mac)
        self.assertEqual([c["path"] for c in conflicts], [["boxes", "black", "slots", "5"]])
        self.assertEqual((conflicts[0]["local"], conflicts[0]["remote"]), ("diver", "dress"))

    def test_same_watch_moved_to_two_slots_keeps_the_lower_index(self):
        base = boxed()
        phone, mac = deepcopy(base), deepcopy(base)
        slots(phone, "black").pop("0")
        slots(phone, "black")["7"] = "field"
        slots(mac, "black").pop("0")
        slots(mac, "black")["3"] = "field"
        merged, conflicts = merge(base, phone, mac)
        self.assertFalse(conflicts)
        self.assertEqual(slots(merged, "black"), {"3": "field"})
        # Across boxes the earlier box wins.
        phone, mac = deepcopy(base), deepcopy(base)
        slots(phone, "black").pop("0")
        slots(phone, "brown")["0"] = "field"
        slots(mac, "black").pop("0")
        slots(mac, "black")["11"] = "field"
        merged, conflicts = merge(base, phone, mac)
        self.assertFalse(conflicts)
        self.assertEqual((slots(merged, "black"), slots(merged, "brown")), ({"11": "field"}, {}))

    def test_watch_deleted_on_one_side_and_placed_on_the_other(self):
        base = boxed()
        phone, mac = deepcopy(base), deepcopy(base)
        phone["watches"] = [w for w in phone["watches"] if w["id"] != "diver"]
        slots(mac, "brown")["2"] = "diver"
        merged, conflicts = merge(base, phone, mac)
        self.assertFalse(conflicts)
        self.assertNotIn("diver", slots(merged, "brown").values())
        # With an edit on the Mac it is the usual delete/edit conflict; either answer leaves no dangling slot.
        next(w for w in mac["watches"] if w["id"] == "diver")["story"] = "Placed and noted"
        _, conflicts = merge(base, phone, mac)
        self.assertEqual([c["path"] for c in conflicts], [["watches", "diver"]])
        for choice in ("local", "remote"):
            merged, left = merge(base, phone, mac, {conflicts[0]["id"]: choice})
            self.assertFalse(left)
            ids = {w["id"] for w in merged["watches"]}
            placed = [v for box in merged["boxes"] for v in box["slots"].values()]
            self.assertTrue(set(placed) <= ids)
            self.assertEqual("diver" in placed, choice == "remote")

    def test_old_client_without_boxes_leaves_them_as_they_are(self):
        server_copy = boxed()
        slots(server_copy, "black")["4"] = "diver"
        old_base = deepcopy(server_copy)
        old_base.pop("boxes")
        old_local = deepcopy(old_base)
        old_local["watches"][0]["story"] = "Edited on an old build"
        merged, conflicts = merge(old_base, old_local, server_copy)
        self.assertFalse(conflicts)
        self.assertEqual(merged["boxes"], server_copy["boxes"])
        self.assertEqual(merged["watches"][0]["story"], "Edited on an old build")

    def test_box_order_changed_on_the_phone_survives_the_merge(self):
        base = boxed()
        phone, mac = deepcopy(base), deepcopy(base)
        phone["boxes"].reverse()
        # The Mac moved a watch meanwhile, so the hub's boxes differ from the base too.
        slots(mac, "brown")["2"] = "dress"
        merged, conflicts = merge(base, phone, mac)
        self.assertFalse(conflicts)
        self.assertEqual([b["id"] for b in merged["boxes"]], ["brown", "black"])
        self.assertEqual(slots(merged, "brown"), {"2": "dress"})
        # The next exchange, with the merged copy as the phone's base and the hub's copy, keeps it.
        again, conflicts = merge(merged, deepcopy(merged), merged)
        self.assertFalse(conflicts)
        self.assertEqual(again, merged)

    def test_phone_order_holds_with_independent_hub_edits(self):
        base = boxed()
        phone, mac = deepcopy(base), deepcopy(base)
        phone["boxes"].reverse()
        slots(mac, "black")["3"] = "diver"
        mac["boxes"][1]["name"] = "Walnut"
        mac["boxes"].append({"id": "box-0000beef", "name": "Travel", "finish": "black", "columns": 3, "rows": 2, "slots": {}})
        merged, conflicts = merge(base, phone, mac)
        self.assertFalse(conflicts)
        # The phone's order, then what the hub added; the hub's edits inside the boxes kept.
        self.assertEqual([b["id"] for b in merged["boxes"]], ["brown", "black", "box-0000beef"])
        self.assertEqual(slots(merged, "black"), {"0": "field", "3": "diver"})
        self.assertEqual(merged["boxes"][0]["name"], "Walnut")

    def test_hub_order_wins_when_both_reordered(self):
        base = boxed()
        base["boxes"].append({"id": "box-0000beef", "name": "Travel", "finish": "black", "columns": 3, "rows": 2, "slots": {}})
        phone, mac = deepcopy(base), deepcopy(base)
        phone["boxes"] = [phone["boxes"][i] for i in (2, 0, 1)]
        mac["boxes"] = [mac["boxes"][i] for i in (1, 0, 2)]
        merged, conflicts = merge(base, phone, mac)
        self.assertFalse(conflicts)
        self.assertEqual([b["id"] for b in merged["boxes"]], ["brown", "black", "box-0000beef"])

    def test_hub_order_stands_when_only_the_hub_reordered_or_the_phone_only_added(self):
        base = boxed()
        phone, mac = deepcopy(base), deepcopy(base)
        mac["boxes"].reverse()
        merged, _ = merge(base, phone, mac)
        self.assertEqual([b["id"] for b in merged["boxes"]], ["brown", "black"])
        # An added or removed box is not a reorder: with the hub's boxes edited too, the hub's order,
        # the phone's new box after it.
        phone, mac = deepcopy(base), deepcopy(base)
        phone["boxes"].insert(0, {"id": "box-0000cafe", "name": "New", "finish": "brown", "columns": 4, "rows": 2, "slots": {}})
        slots(mac, "brown")["1"] = "dress"
        merged, conflicts = merge(base, phone, mac)
        self.assertFalse(conflicts)
        self.assertEqual([b["id"] for b in merged["boxes"]], ["black", "brown", "box-0000cafe"])
        # A first join (no base) has no order to keep: the hub's.
        phone = deepcopy(base)
        phone["boxes"].reverse()
        merged, _ = merge(None, phone, base)
        self.assertEqual([b["id"] for b in merged["boxes"]], ["black", "brown"])

    def test_other_lists_keep_the_hubs_order(self):
        base = boxed()
        phone, mac = deepcopy(base), deepcopy(base)
        phone["watches"].reverse()
        mac["watches"][1]["story"] = "Edited on the Mac"
        merged, conflicts = merge(base, phone, mac)
        self.assertFalse(conflicts)
        self.assertEqual([w["id"] for w in merged["watches"]], [w["id"] for w in base["watches"]])

    def test_empty_box_tiles_and_boxes_survive_normalize(self):
        data = boxed()
        data["emptyBoxTiles"] = {"black": "empty-black-0123abcd.jpg"}
        normal = normalize(data)
        self.assertEqual(normal["emptyBoxTiles"], data["emptyBoxTiles"])
        self.assertEqual(normal["boxes"], data["boxes"])
        self.assertNotIn("boxes", normalize(collection()))

    def test_clean_boxes_rule_1_drops_bad_slot_keys(self):
        data = boxed()
        data["boxes"][0]["slots"] = {"0": "field", "12": "diver", "-1": "dress", "05": "dress", "x": "dress", " 3": "dress"}
        data["boxes"][1]["slots"] = {"9": "dress"}
        data["boxes"][1]["columns"] = 4  # 4 by 2: 0...7
        clean_boxes(data)
        self.assertEqual(slots(data, "black"), {"0": "field"})
        self.assertEqual(slots(data, "brown"), {})

    def test_clean_boxes_rule_2_keeps_owned_watches_only(self):
        data = boxed()
        slots(data, "black").update({"1": "sold-one", "2": "no-such-watch", "3": "diver"})
        clean_boxes(data)
        self.assertEqual(slots(data, "black"), {"0": "field", "3": "diver"})

    def test_clean_boxes_rule_3_first_place_wins(self):
        data = boxed()
        slots(data, "black").update({"10": "diver", "2": "diver"})
        slots(data, "brown").update({"0": "field", "1": "dress"})
        clean_boxes(data)
        self.assertEqual(slots(data, "black"), {"0": "field", "2": "diver"})
        self.assertEqual(slots(data, "brown"), {"1": "dress"})

    def test_clean_boxes_rule_4_caps_and_dedupes_boxes(self):
        data = boxed()
        extra = [{"id": f"box-{n:08x}", "name": f"Box {n}", "finish": "black", "columns": 3, "rows": 2, "slots": {}}
                 for n in range(8)]
        data["boxes"] += [dict(data["boxes"][0], name="Copy", slots={})] + extra
        clean_boxes(data)
        self.assertEqual(len(data["boxes"]), 7)  # eight kept, then the copy of black dropped
        self.assertEqual([b["id"] for b in data["boxes"][:3]], ["black", "brown", "box-00000000"])
        self.assertEqual(data["boxes"][0]["name"], "Black Box")

    def test_clean_boxes_is_idempotent(self):
        data = boxed()
        slots(data, "black").update({"1": "sold-one", "3": "diver", "40": "dress"})
        slots(data, "brown").update({"0": "diver", "5": "dress"})
        once = clean_boxes(deepcopy(data))
        self.assertEqual(clean_boxes(deepcopy(once)), once)
        self.assertEqual(clean_boxes(collection()), collection())


class BoxSyncAPITests(unittest.TestCase):
    setUp = SyncAPITests.setUp
    tearDown = SyncAPITests.tearDown
    request = SyncAPITests.request

    def seed_boxes(self):
        self.seed = boxed()
        server.atomic_write_data(self.seed)
        return deepcopy(self.seed)

    def tile(self, method, folder, finish, payload=b"", headers=None):
        req = Request(f"http://127.0.0.1:{self.httpd.server_port}/api/boxtiles/{folder}/{finish}", method=method,
                      data=payload or None, headers={"Content-Type": "image/jpeg", **(headers or {})})
        try:
            with urlopen(req, timeout=3) as response:
                return response.status, json.load(response)
        except HTTPError as response:
            return response.code, json.load(response)

    def publish(self, folder, finish, label):
        payload = jpeg(label)
        status, result = self.tile("POST", folder, finish, payload)
        self.assertEqual(status, 200, result)
        return result["file"]

    def test_same_slot_conflict_writes_nothing(self):
        base = self.seed_boxes()
        phone, mac = deepcopy(base), deepcopy(base)
        slots(phone, "black")["5"] = "diver"
        slots(mac, "black")["5"] = "dress"
        server.atomic_write_data(mac)
        status, result = self.request("POST", "/api/sync", {"base": base, "local": phone})
        self.assertEqual(status, 200)
        self.assertEqual([c["path"] for c in result["conflicts"]], [["boxes", "black", "slots", "5"]])
        self.assertEqual(server.read_data(), mac)

    def test_box_order_from_the_phone_is_written(self):
        base = self.seed_boxes()
        local = deepcopy(base)
        local["boxes"].reverse()
        status, result = self.request("POST", "/api/sync", {"base": base, "local": local})
        self.assertEqual(status, 200)
        self.assertFalse(result["conflicts"])
        self.assertEqual([b["id"] for b in server.read_data()["boxes"]], ["brown", "black"])
        status, snapshot = self.request("GET", "/api/sync")
        self.assertEqual([b["id"] for b in snapshot["data"]["boxes"]], ["brown", "black"])

    def test_old_client_edit_leaves_server_boxes_unchanged(self):
        base = self.seed_boxes()
        old = deepcopy(base)
        old.pop("boxes")
        local = deepcopy(old)
        local["watches"][0]["price"] = 970
        status, result = self.request("POST", "/api/sync", {"base": old, "local": local})
        self.assertEqual(status, 200)
        self.assertFalse(result["conflicts"])
        self.assertEqual(server.read_data()["boxes"], base["boxes"])
        self.assertEqual(server.read_data()["watches"][0]["price"], 970)

    def test_box_cutout_survives_a_web_edit_and_a_sync(self):
        base = self.seed_boxes()
        cutout = {"photo": "74d7287181b5.jpeg", "x": 0.52, "y": 0.47, "r": 0.21, "turn": -4}
        local = deepcopy(base)
        local["watches"][0]["boxCutout"] = cutout
        self.assertEqual(self.request("POST", "/api/sync", {"base": base, "local": local})[0], 200)
        status, edited = self.request("PUT", "/api/watches/field", {"name": "Field Renamed"})
        self.assertEqual(status, 200)
        self.assertEqual(edited["boxCutout"], cutout)
        status, snapshot = self.request("GET", "/api/sync")
        again = deepcopy(snapshot["data"])
        again["watches"][1]["story"] = "Another edit"
        status, result = self.request("POST", "/api/sync", {"base": snapshot["data"], "local": again})
        self.assertEqual(status, 200)
        self.assertEqual(result["data"]["watches"][0]["boxCutout"], cutout)
        self.assertEqual(result["data"]["watches"][0]["name"], "Field Renamed")
        # boxCutout is not editable through the web PUT.
        self.assertEqual(self.request("PUT", "/api/watches/field", {"boxCutout": None})[0], 400)

    def test_invalid_boxes_are_rejected(self):
        base = self.seed_boxes()
        good = base["boxes"][0]
        shapes = [
            {"black": good},
            [good] * 9,
            [dict(good, id="Black")], [dict(good, id="")], [dict(good, id="a" * 41)], [dict(good, id=7)],
            [dict(good, name="")], [dict(good, name="   ")], [dict(good, name="n" * 41)],
            [dict(good, finish="white")], [dict(good, finish=None)],
            [dict(good, columns=0)], [dict(good, columns=9)], [dict(good, columns=True)], [dict(good, columns=6.0)],
            [dict(good, rows=0)], [dict(good, rows=5)],
            [dict(good, slots=["field"])], [dict(good, slots={"a": "field"})], [dict(good, slots={"1": None})],
            [dict(good, slots={"1": 3})], [{k: v for k, v in good.items() if k != "slots"}],
            None,
        ]
        for shape in shapes:
            local = deepcopy(base)
            local["boxes"] = shape
            status, _ = self.request("POST", "/api/sync", {"base": base, "local": local})
            self.assertEqual(status, 400, shape)
        self.assertEqual(server.read_data(), base)

    def test_deleting_a_watch_on_the_web_clears_its_slot(self):
        base = self.seed_boxes()
        base["boxes"][1]["slots"] = {"3": "diver", "4": "dress"}
        server.atomic_write_data(base)
        self.assertEqual(self.request("DELETE", "/api/watches/diver")[0], 200)
        stored = server.read_data()
        self.assertEqual(slots(stored, "brown"), {"4": "dress"})
        self.assertEqual(slots(stored, "black"), {"0": "field"})

    def test_publish_route_refuses_bad_requests(self):
        self.seed_boxes()
        with mock.patch.object(server, "loopback_client", return_value=False):
            self.assertEqual(self.tile("POST", "field", "black", jpeg("a"))[0], 403)
            self.assertEqual(self.tile("DELETE", "field", "black")[0], 403)
        self.assertEqual(self.tile("POST", "field", "black", jpeg("a"), {"Origin": "http://example.com"})[0], 403)
        self.assertEqual(self.tile("POST", "nobody", "black", jpeg("a"))[0], 404)
        self.assertEqual(self.tile("POST", "wl-nobody", "black", jpeg("a"))[0], 404)
        self.assertEqual(self.tile("POST", "field", "white", jpeg("a"))[0], 400)
        self.assertEqual(self.tile("POST", "field", "black", b"\x89PNG\r\n\x1a\nnot a jpeg")[0], 400)
        self.assertEqual(self.tile("POST", "field", "black", jpeg("a"), {"Content-Type": "text/plain"})[0], 400)
        with mock.patch.object(server, "BOX_TILE_LIMIT", 16):
            self.assertEqual(self.tile("POST", "field", "black", jpeg("seventeen bytes"))[0], 413)
        self.assertEqual(server.read_data(), self.seed)
        self.assertFalse((server.PHOTOS_DIR / "field").exists())

    def test_loopback_client(self):
        for host, expected in (("127.0.0.1", True), ("::1", True), ("::ffff:127.0.0.1", True),
                               ("100.101.102.103", False), ("192.168.1.20", False), ("not an address", False)):
            self.assertEqual(server.loopback_client(host), expected, host)

    def test_publish_replaces_the_older_tile_and_delete_clears_it(self):
        self.seed_boxes()
        first = self.publish("field", "black", "first")
        self.assertEqual(first, tile_name("box", "black", jpeg("first")))
        self.assertEqual(server.read_data()["watches"][0]["boxTiles"], {"black": first})
        second = self.publish("field", "black", "second")
        brown = self.publish("field", "brown", "brown")
        self.assertFalse((server.PHOTOS_DIR / "field" / first).exists())
        self.assertTrue((server.PHOTOS_DIR / "field" / second).is_file())
        self.assertEqual(server.read_data()["watches"][0]["boxTiles"], {"black": second, "brown": brown})
        empty = self.publish("_box", "black", "empty")
        self.assertEqual(empty, tile_name("empty", "black", jpeg("empty")))
        self.assertEqual(server.read_data()["emptyBoxTiles"], {"black": empty})
        self.assertEqual(self.tile("DELETE", "field", "black")[0], 200)
        self.assertFalse((server.PHOTOS_DIR / "field" / second).exists())
        self.assertEqual(server.read_data()["watches"][0]["boxTiles"], {"brown": brown})
        self.assertEqual(self.tile("DELETE", "field", "black")[0], 404)
        self.assertEqual(self.tile("DELETE", "field", "brown")[0], 200)
        self.assertNotIn("boxTiles", server.read_data()["watches"][0])
        self.assertEqual(self.tile("DELETE", "_box", "black")[0], 200)
        self.assertNotIn("emptyBoxTiles", server.read_data())

    def test_tile_names_are_referenced_files_and_never_photos(self):
        self.seed_boxes()
        black = self.publish("field", "black", "black")
        empty = self.publish("_box", "brown", "empty")
        status, snapshot = self.request("GET", "/api/sync")
        self.assertEqual(status, 200)
        self.assertEqual(sorted(snapshot["photos"]), sorted([f"field/{black}", f"_box/{empty}"]))
        self.assertEqual(snapshot["data"]["watches"][0]["photos"], [])
        self.assertEqual(server.WatchHandler.sync_photo_paths(snapshot["data"]), [f"field/{black}", f"_box/{empty}"])
        # A sync round trip keeps them out of photos too.
        local = deepcopy(snapshot["data"])
        local["watches"][0]["story"] = "Synced"
        status, result = self.request("POST", "/api/sync", {"base": snapshot["data"], "local": local})
        self.assertEqual(status, 200)
        self.assertEqual(result["data"]["watches"][0]["photos"], [])
        self.assertEqual(result["data"]["watches"][0]["boxTiles"], {"black": black})

    def test_client_cannot_remove_or_change_tiles(self):
        self.seed_boxes()
        black = self.publish("field", "black", "black")
        empty = self.publish("_box", "black", "empty")
        hub = server.read_data()
        # An old build drops both keys when it decodes; its sync must not delete them.
        stripped = deepcopy(hub)
        stripped["watches"][0].pop("boxTiles")
        stripped.pop("emptyBoxTiles")
        edited = deepcopy(stripped)
        edited["watches"][0]["story"] = "Old build"
        status, result = self.request("POST", "/api/sync", {"base": stripped, "local": edited})
        self.assertEqual(status, 200)
        self.assertFalse(result["conflicts"])
        self.assertEqual(result["data"]["watches"][0]["boxTiles"], {"black": black})
        self.assertEqual(result["data"]["emptyBoxTiles"], {"black": empty})
        self.assertEqual(result["data"]["watches"][0]["story"], "Old build")
        # A different value is ignored, with a baseline and on a first join alike.
        hub = server.read_data()
        changed = deepcopy(hub)
        changed["watches"][0]["boxTiles"] = {"black": "box-black-00000000.jpg", "brown": "box-brown-00000000.jpg"}
        changed["emptyBoxTiles"] = {"brown": "empty-brown-00000000.jpg"}
        for base in (hub, None):
            status, result = self.request("POST", "/api/sync", {"base": base, "local": changed})
            self.assertEqual(status, 200)
            self.assertFalse(result["conflicts"])
            self.assertEqual(server.read_data(), hub)

    def test_lost_tile_file_does_not_block_sync(self):
        self.seed_boxes()
        black = self.publish("field", "black", "black")
        (server.PHOTOS_DIR / "field" / black).unlink()
        hub = server.read_data()
        local = deepcopy(hub)
        local["watches"][0]["story"] = "Still syncs"
        status, result = self.request("POST", "/api/sync", {"base": hub, "local": local})
        self.assertEqual(status, 200)
        self.assertNotIn("boxTiles", result["data"]["watches"][0])

    def test_bought_wishlist_watch_keeps_its_tiles(self):
        base = self.seed_boxes()
        base["wishlist"] = [{"id": "nomos", "name": "Nomos", "brand": "Nomos", "category": "Field", "priceExpected": 2000,
                             "priceNote": "", "notes": "", "status": "considering", "added": "2026-11",
                             "dialColor": "Black", "diameter": 38, "lugToLug": None, "material": "Steel", "photos": []}]
        server.atomic_write_data(base)
        black = self.publish("wl-nomos", "black", "nomos black")
        brown = self.publish("wl-nomos", "brown", "nomos brown")
        hub = server.read_data()
        # The phone marks it bought: a new watch, the tiles copied into its own folder.
        local = deepcopy(hub)
        local["wishlist"][0]["status"] = "bought"
        bought = dict(watch("nomos-watch"), boxTiles={"black": black, "brown": brown})
        local["watches"].append(bought)
        payload = {"data": base64.b64encode(jpeg("nomos black")).decode()}
        self.assertEqual(self.request("POST", f"/api/sync/photos/nomos-watch/{black}", payload)[0], 200)
        # Only the black tile made it across; the brown name is dropped instead of blocking the sync.
        status, result = self.request("POST", "/api/sync", {"base": hub, "local": local})
        self.assertEqual(status, 200)
        self.assertFalse(result["conflicts"])
        stored = server.read_data()
        new = next(w for w in stored["watches"] if w["id"] == "nomos-watch")
        self.assertEqual(new["boxTiles"], {"black": black})
        self.assertEqual(stored["wishlist"][0]["boxTiles"], {"black": black, "brown": brown})
        self.assertEqual(stored["wishlist"][0]["status"], "bought")
        self.assertIn(f"nomos-watch/{black}", result["photos"])
        # From then on the hub owns them: a later client edit to the names is ignored.
        later = deepcopy(stored)
        next(w for w in later["watches"] if w["id"] == "nomos-watch")["boxTiles"] = {}
        status, result = self.request("POST", "/api/sync", {"base": stored, "local": later})
        self.assertEqual(status, 200)
        self.assertEqual(server.read_data(), stored)

    def test_sync_snapshots_say_the_hub_keeps_boxes(self):
        base = self.seed_boxes()
        status, snapshot = self.request("GET", "/api/sync")
        self.assertEqual((status, snapshot["features"]), (200, ["boxes"]))
        local = deepcopy(base)
        local["watches"][0]["story"] = "Synced"
        status, result = self.request("POST", "/api/sync", {"base": base, "local": local})
        self.assertEqual((status, result["features"]), (200, ["boxes"]))
        # A conflict answer is a snapshot too.
        hub = deepcopy(server.read_data())
        hub["watches"][0]["story"] = "Edited on the Mac"
        server.atomic_write_data(hub)
        local["watches"][0]["story"] = "Edited on the phone"
        status, result = self.request("POST", "/api/sync", {"base": base, "local": local})
        self.assertEqual(status, 200)
        self.assertTrue(result["conflicts"])
        self.assertEqual(result["features"], ["boxes"])


if __name__ == "__main__":
    unittest.main()
