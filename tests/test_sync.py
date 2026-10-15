"""Sync regressions against an isolated copy, never the personal collection."""
from copy import deepcopy
import base64
import json
from pathlib import Path
import tempfile
import threading
import unittest
from urllib.request import Request, urlopen
from urllib.error import HTTPError
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import server
from sync import merge


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


if __name__ == "__main__":
    unittest.main()
