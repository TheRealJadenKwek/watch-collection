#!/usr/bin/env python3
"""Offline end-to-end verification for the v1.12 local app."""

from __future__ import annotations

import base64
import concurrent.futures
import csv
import http.client
import json
import shutil
import subprocess
import tempfile
import threading
import unittest
from collections import Counter
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[1]

import sys
sys.path.insert(0, str(ROOT))
import export_sheet
import server


SEED = json.loads((ROOT / "data" / "watches.json").read_text(encoding="utf-8"))
# Assertions pinned to the author's personal dataset only run when that dataset is present.
PERSONAL_DATASET = any(w["id"] == "stuhrling-regatta-elite-326b" for w in SEED["watches"])
personal_only = unittest.skipUnless(PERSONAL_DATASET, "requires the author's personal dataset")

PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")


class WatchAppTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="watch-app-test-")
        cls.root = Path(cls.temporary.name)
        cls.seed = json.loads((ROOT / "data" / "watches.json").read_text(encoding="utf-8"))
        cls.data_file = cls.root / "data" / "watches.json"
        cls.photos = cls.root / "data" / "photos"
        cls.data_file.parent.mkdir(parents=True)
        cls.photos.mkdir(parents=True)
        server.DATA_FILE = cls.data_file
        server.PHOTOS_DIR = cls.photos
        cls.httpd = server.WatchServer(("127.0.0.1", 0), server.WatchHandler)
        cls.port = cls.httpd.server_address[1]
        cls.thread = threading.Thread(target=cls.httpd.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()
        cls.thread.join(timeout=3)
        cls.temporary.cleanup()

    def setUp(self):
        self.data_file.write_text(json.dumps(self.seed, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        shutil.rmtree(self.photos, ignore_errors=True)
        self.photos.mkdir(parents=True)

    def request(self, method, path, payload=None):
        body = None if payload is None else json.dumps(payload).encode()
        request = Request(f"http://127.0.0.1:{self.port}{path}", data=body, method=method, headers={"Content-Type": "application/json"})
        try:
            with urlopen(request, timeout=5) as response:
                return response.status, json.load(response)
        except HTTPError as error:
            return error.code, json.load(error)

    def get_data(self):
        return self.request("GET", "/api/data")[1]

    def seed_watch_id(self):
        return next(w["id"] for w in SEED["watches"] if w["status"] == "owned")

    def test_01_seed_and_api_shape(self):
        status, data = self.request("GET", "/api/data")
        self.assertEqual(status, 200)
        seed = json.loads((ROOT / "data" / "watches.json").read_text(encoding="utf-8"))
        self.assertEqual(len(data["watches"]), len(seed["watches"]))
        self.assertGreaterEqual(len(data["watches"]), 1)
        self.assertTrue(all("category" in watch for watch in data["watches"]))
        self.assertEqual(len(data["wishlist"]), len(seed["wishlist"]))
        self.assertTrue(all(item["status"] in ("considering", "passed", "bought") for item in data["wishlist"]))
        self.assertEqual(len(data["brandWatchlist"]), len(seed["brandWatchlist"]))
        self.assertEqual(len(data["categories"]), len(seed["categories"]))
        self.assertIn("Pilot", data["categories"])
        self.assertIn("GMT", data["categories"])
        self.assertEqual(data["settings"]["wrist"]["lugMax"], seed["settings"]["wrist"]["lugMax"])
        self.assertTrue(data["settings"]["autoImage"])
        self.assertEqual(data["settings"]["suggestExclude"], seed["settings"]["suggestExclude"])

    @personal_only
    def test_02_categories_and_forbidden_old_name(self):
        data = self.get_data()
        owned = Counter(w["category"] for w in data["watches"] if w["status"] == "owned")
        all_time = Counter(w["category"] for w in data["watches"])
        self.assertEqual((owned["Dive"], all_time["Dive"]), (5, 14))
        self.assertEqual(owned["Dress"], 1)
        self.assertEqual(owned["Chronograph"], 2)
        forbidden = "Integrated" + " Sport"
        for path in ROOT.rglob("*"):
            if path.is_file() and ".git" not in path.parts and "__pycache__" not in path.parts:
                try:
                    self.assertNotIn(forbidden, path.read_text(encoding="utf-8"), str(path))
                except UnicodeDecodeError:
                    pass

    @personal_only
    def test_03_old_sheet_statistics(self):
        watches = self.get_data()["watches"]
        stats = export_sheet.headline_stats(watches)
        self.assertEqual(int(stats["count"]), len(watches))
        # The 62 sheet-era watches must forever reproduce the old Google Sheet's numbers
        # The original spreadsheet ended January 2026; everything after is app-era.
        sheet_era = [w for w in watches if (w.get("purchased") or "9999") <= "2026-01"]
        sheet_stats = export_sheet.headline_stats(sheet_era)
        self.assertEqual(int(sheet_stats["count"]), 62)
        self.assertAlmostEqual(sheet_stats["total"], 10356.63, delta=.01)
        self.assertEqual(round(sheet_stats["mean"], 2), 167.04)
        self.assertEqual(round(sheet_stats["skewness"], 3), 1.768)

    def test_04_atomic_merge_and_concurrent_writes(self):
        watch_id = self.seed_watch_id()
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda pair: self.request("PUT", f"/api/watches/{watch_id}", pair), [{"story": "concurrent story"}, {"statusNote": "concurrent note"}]))
        self.assertTrue(all(status == 200 for status, _ in results))
        saved = next(w for w in self.get_data()["watches"] if w["id"] == watch_id)
        self.assertEqual(saved["story"], "concurrent story")
        self.assertEqual(saved["statusNote"], "concurrent note")
        json.loads(self.data_file.read_text(encoding="utf-8"))
        self.assertFalse(list(self.data_file.parent.glob(".watches.json.*.tmp")))

    def test_05_photo_round_trip(self):
        boundary = "WatchBoundary123"
        body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"tiny.png\"\r\nContent-Type: image/png\r\n\r\n".encode() + PNG + f"\r\n--{boundary}--\r\n".encode())
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        target = self.seed_watch_id()
        connection.request("POST", f"/api/watches/{target}/photos", body=body, headers={"Content-Type": f"multipart/form-data; boundary={boundary}", "Content-Length": str(len(body))})
        response = connection.getresponse(); payload = json.loads(response.read()); connection.close()
        self.assertEqual(response.status, 201)
        filename = payload["filename"]
        disk_path = self.photos / target / filename
        self.assertEqual(disk_path.read_bytes(), PNG)
        with urlopen(f"http://127.0.0.1:{self.port}/photos/{target}/{filename}") as photo_response:
            self.assertEqual(photo_response.read(), PNG)
        self.assertEqual(self.request("POST", f"/api/watches/{target}/photos/{filename}/cover")[0], 200)
        self.assertEqual(self.request("DELETE", f"/api/watches/{target}/photos/{filename}")[0], 200)
        self.assertFalse(disk_path.exists())

    @personal_only
    def test_06_wishlist_scoring(self):
        data = self.get_data()
        scores = {item["id"]: export_sheet.score_wishlist(item, data) for item in data["wishlist"]}
        iwc = scores["iwc-mark-xx-blue"]
        # Category/brand/price are stable facts; size/dial/material shift as data gets filled in,
        # so assert internal consistency for those instead of pinned values.
        self.assertEqual(iwc["lenses"]["category"]["score"], 3)
        self.assertEqual(iwc["lenses"]["brand"]["score"], 2)
        self.assertEqual(iwc["lenses"]["price"]["score"], 2)
        self.assertEqual(iwc["total"], sum(iwc["lenses"][n]["score"] for n in iwc["lenses"]))
        self.assertEqual(scores["longines-hydroconquest-39"]["lenses"]["category"]["score"], 0)
        citizen = scores["citizen-zenshin-60"]
        # Integrated Bracelet: 8 owned all-time but every one was a rep — a real one is a gap
        self.assertEqual(citizen["lenses"]["category"]["score"], 3)
        self.assertEqual(citizen["lenses"]["material"]["score"], 2)
        self.assertEqual(citizen["max"], 14)

    @personal_only
    def test_07_wishlist_scores_endpoint(self):
        data = self.get_data()
        status, payload = self.request("GET", "/api/wishlist/scores")
        self.assertEqual(status, 200)
        expected_ids = {item["id"] for item in data["wishlist"]}
        self.assertEqual(set(payload["scores"]), expected_ids)
        for item in data["wishlist"]:
            expected = export_sheet.score_wishlist(item, data)
            self.assertEqual(payload["scores"][item["id"]]["total"], expected["total"])

    def test_07_next_move_suggestions(self):
        data = self.get_data()
        expected = export_sheet.next_move_suggestions(data)
        status, payload = self.request("GET", "/api/suggestions")
        self.assertEqual(status, 200)
        self.assertEqual(payload, expected)
        self.assertLessEqual(len(payload["suggestions"]), 5)
        from collections import Counter as _Counter
        owned_counts = _Counter(w["category"] for w in SEED["watches"] if w["status"] == "owned" and w.get("category"))
        expected_saturated = sorted(c for c, n in owned_counts.items() if n >= 3)
        self.assertEqual(sorted(payload["saturated"]["categories"]), expected_saturated)
        self.assertIn("Pilot", {suggestion["category"] for suggestion in payload["suggestions"]})
        self.assertEqual(
            [suggestion["score"] for suggestion in payload["suggestions"]],
            sorted((suggestion["score"] for suggestion in payload["suggestions"]), reverse=True),
        )

        owned = [watch for watch in data["watches"] if watch["status"] == "owned"]
        owned_categories = Counter(watch.get("category") for watch in owned)
        owned_dials = Counter(watch.get("dialColor") for watch in owned)
        owned_materials = Counter(watch.get("material") for watch in owned)
        excluded = set(data["settings"]["suggestExclude"])
        saturated_brands = set(payload["saturated"]["brands"])
        radar_brands = {item["brand"] for item in data["brandWatchlist"]}
        tier_midpoints = {
            label: (lower + 1 if upper == float("inf") else (lower + upper) / 2)
            for label, lower, upper in export_sheet.PRICE_TIERS
        }

        for suggestion in payload["suggestions"]:
            self.assertNotIn(suggestion["category"], excluded)
            self.assertLess(owned_categories[suggestion["category"]], 2)
            self.assertTrue(suggestion["reasons"])
            self.assertIn(suggestion["category"].casefold(), suggestion["reasons"][0].casefold())
            # A suggestion may have zero brand recs when its whole pool is saturated
            # (e.g. G-Shock when you already own three Casios).
            self.assertIsInstance(suggestion["brands"], list)
            self.assertLessEqual(len(suggestion["brands"]), 4)
            self.assertTrue(all(brand["name"] not in saturated_brands for brand in suggestion["brands"]))
            self.assertEqual(
                [export_sheet.BRAND_STATUS_ORDER[brand["status"]] for brand in suggestion["brands"]],
                sorted(export_sheet.BRAND_STATUS_ORDER[brand["status"]] for brand in suggestion["brands"]),
            )
            radar_in_suggestion = [brand["name"] for brand in suggestion["brands"] if brand["status"] == "radar"]
            self.assertTrue(all(name in radar_brands for name in radar_in_suggestion))
            if radar_in_suggestion:
                self.assertTrue(any("already on your radar" in reason for reason in suggestion["reasons"]))
            for dial in suggestion["dialColors"]:
                self.assertEqual(owned_dials[dial], 0)
                self.assertTrue(any(dial in reason and "not represented" in reason for reason in suggestion["reasons"]))
            if suggestion["material"]:
                self.assertEqual(owned_materials[suggestion["material"]], 0)
                self.assertTrue(any(suggestion["material"] in reason and "first" in reason for reason in suggestion["reasons"]))
            if suggestion["priceTier"]:
                tier = suggestion["priceTier"]
                originals = export_sheet.originals_only(owned)
                self.assertFalse(any(export_sheet.price_tier(watch.get("price")) == tier for watch in originals))
                self.assertTrue(any(tier in reason and "empty" in reason for reason in suggestion["reasons"]))

            pseudo_item = {
                "name": "Suggestion score check",
                "brand": "Generic",
                "category": suggestion["category"],
                "dialColor": suggestion["dialColors"][0] if suggestion["dialColors"] else None,
                "material": suggestion["material"],
                "priceExpected": tier_midpoints.get(suggestion["priceTier"]),
            }
            lenses = export_sheet.score_wishlist(pseudo_item, data)["lenses"]
            self.assertEqual(
                suggestion["score"],
                sum(lenses[name]["score"] for name in ("category", "dial", "material", "price")),
            )
            self.assertEqual(
                suggestion["wishlistMatches"],
                [item["id"] for item in data["wishlist"] if item["status"] == "considering" and item.get("category") == suggestion["category"]],
            )

        for category, pool in export_sheet.BRAND_RECOMMENDATION_POOL.items():
            for brand in pool:
                self.assertEqual(export_sheet.brand_for(brand), brand, f"{category}: {brand}")

    @personal_only
    def test_07_mark_bought_only_mutates_copy(self):
        status, payload = self.request("POST", "/api/wishlist/iwc-mark-xx-blue/bought", {"price": 5000, "purchased": "2026-07"})
        self.assertEqual(status, 201)
        self.assertTrue(payload["ok"])
        copied = self.get_data()
        seed = json.loads((ROOT / "data" / "watches.json").read_text(encoding="utf-8"))
        self.assertEqual(len(copied["watches"]), len(seed["watches"]) + 1)
        self.assertEqual(next(w for w in copied["wishlist"] if w["id"] == "iwc-mark-xx-blue")["status"], "bought")
        original = json.loads((ROOT / "data" / "watches.json").read_text(encoding="utf-8"))
        self.assertEqual(len(original["watches"]), len(seed["watches"]))
        self.assertEqual(len(original["wishlist"]), len(seed["wishlist"]))
        self.assertTrue(all(item["status"] == "considering" for item in original["wishlist"]))

    @personal_only
    def test_08_editable_taxonomy_semantics(self):
        cases = [
            ("categories", "Pilot", "Test Pilot", "category", "iwc-mark-xx-blue", "wishlist", "Dive"),
            ("dialcolors", "Black", "Test Black", "dialColor", "rolex-submariner-126610ln-rep", "watches", "Blue"),
            ("materials", "Titanium", "Test Titanium", "material", "citizen-zenshin-60", "wishlist", "Bioceramic"),
        ]
        for route, old, new, field, item_id, group, in_use in cases:
            self.assertEqual(self.request("PUT", f"/api/{route}", {"rename": {"from": old, "to": new}})[0], 200)
            item = next(item for item in self.get_data()[group] if item["id"] == item_id)
            self.assertEqual(item[field], new)
            self.assertEqual(self.request("PUT", f"/api/{route}", {"rename": {"from": new, "to": old}})[0], 200)
            self.assertEqual(self.request("PUT", f"/api/{route}", {"delete": in_use})[0], 409)
            scratch = f"Unused {route}"
            self.assertEqual(self.request("PUT", f"/api/{route}", {"add": scratch})[0], 200)
            self.assertEqual(self.request("PUT", f"/api/{route}", {"delete": scratch})[0], 200)

    def test_08_suggestion_exclusions_persist(self):
        proposed = ["Smartwatch", "Other"]
        status, settings = self.request("PUT", "/api/settings", {"suggestExclude": proposed})
        self.assertEqual(status, 200)
        self.assertEqual(settings["suggestExclude"], proposed)
        self.assertEqual(self.get_data()["settings"]["suggestExclude"], proposed)
        self.assertEqual(self.request("PUT", "/api/settings", {"suggestExclude": None})[0], 400)
        self.assertEqual(self.request("PUT", "/api/settings", {"suggestExclude": ["Not a real category"]})[0], 400)

    @personal_only
    def test_09_fit_chips_and_l2l_precedence(self):
        data = self.get_data(); wrist = data["settings"]["wrist"]
        watches = {watch["id"]: watch for watch in data["watches"]}
        self.assertTrue(export_sheet.fit_info(watches["timex-marlin"], wrist)["label"].startswith("sweet spot"))
        self.assertEqual(export_sheet.fit_info(watches["casio-g-steel-gsts300g"], wrist)["label"], "+10mm over")
        self.assertEqual(export_sheet.fit_info(watches["zenith-220s"], wrist)["label"], "−1mm under")
        self.assertEqual(self.request("PUT", "/api/watches/oris-aquis-date", {"lugToLug": 46})[0], 200)
        oris = next(w for w in self.get_data()["watches"] if w["id"] == "oris-aquis-date")
        fit = export_sheet.fit_info(oris, wrist)
        self.assertEqual((fit["key"], fit["basis"]), ("great", "L2L"))
        self.assertEqual(self.request("PUT", "/api/watches/oris-aquis-date", {"lugToLug": None})[0], 200)
        oris = next(w for w in self.get_data()["watches"] if w["id"] == "oris-aquis-date")
        self.assertEqual(export_sheet.fit_info(oris, wrist)["basis"], "diameter")

    def test_10_detailed_export(self):
        export_dir = self.root / "exports"
        old_data, old_exports = export_sheet.DATA_FILE, export_sheet.EXPORTS_DIR
        export_sheet.DATA_FILE, export_sheet.EXPORTS_DIR = self.data_file, export_dir
        try:
            csv_path, json_path, backed_up, _output = export_sheet.export_collection(allow_remote=False)
        finally:
            export_sheet.DATA_FILE, export_sheet.EXPORTS_DIR = old_data, old_exports
        self.assertFalse(backed_up)
        self.assertTrue(csv_path.is_file() and json_path.is_file())
        with csv_path.open(encoding="utf-8") as handle:
            rows = list(csv.reader(handle))
        flat = "\n".join(",".join(row) for row in rows)
        for label in ("HEADLINE STATISTICS", "PRICE PERCENTILES", "SIZE HISTOGRAM", "sweet spot", "LUG-TO-LUG", "SPEND BY PURCHASE YEAR", "BRANDS + BRAND BREADTH", "RADAR:", "CATEGORIES", "PRICE TIERS", "Originals-only", "DIAL COLOURS", "MATERIALS", "NEXT MOVE SUGGESTIONS", "WISHLIST", "categoryScore", "materialScore", "basis"):
            self.assertIn(label, flat)
        suggestions_header = next(row for row in rows if row and row[0] == "headline" and "matches" in row)
        self.assertIn("brands", suggestions_header)
        self.assertIn("[radar]", flat)
        watch_ids = {watch["id"] for watch in self.seed["watches"]}
        self.assertGreaterEqual(sum(bool(row and row[0] in watch_ids) for row in rows), len(SEED["watches"]))

    def test_11_frontend_and_offline_autoimage_logic(self):
        html = (ROOT / "index.html").read_text(encoding="utf-8")
        js = (ROOT / "app.js").read_text(encoding="utf-8")
        for panel in ("collection", "past", "stats", "wishlist"):
            self.assertIn(f'data-panel="{panel}"', html)
        for marker in ("searchInput", "categoryFilter", "completeDataNudge", "suggestionsPanel", "suggestExclude", 'addEventListener("paste"', "dragover", "data-manage", "categories", "dialcolors", "materials", "WISHLIST_WEIGHTS"):
            self.assertIn(marker, html + js)
        for normalized_brand in ("Christopher Ward", "D1 Milano", "Henry Archer", "Furlan Marri", "Dan Henry"):
            self.assertIn(normalized_brand, js)
        self.assertIn("suggestion-brand-chip", html + js)
        subprocess.run(["node", "--check", str(ROOT / "app.js")], check=True, capture_output=True, text=True)
        self.assertEqual(server.parse_ddg_vqd("<script>vqd='123-456'</script>"), "123-456")
        self.assertEqual(server.extract_ddg_image_urls({"results": [{"image": "https://example.test/a.jpg"}]}), ["https://example.test/a.jpg"])
        self.assertEqual(server.extract_bing_image_urls('<a m="{&quot;murl&quot;:&quot;https://example.test/a.png&quot;}">'), ["https://example.test/a.png"])
        self.assertEqual(server.image_extension(PNG), ".png")
        self.assertIsNone(server.image_extension(b"not an image"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
