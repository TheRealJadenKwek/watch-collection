#!/usr/bin/env python3
"""Local-only, stdlib-only watch collection server."""

from __future__ import annotations

import html
import json
import mimetypes
import os
import re
import shutil
import subprocess
import sys
import threading
import unicodedata
import uuid
from datetime import datetime
from email import policy
from email.parser import BytesParser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote_plus, unquote, urlencode, urlsplit
from urllib.request import Request, urlopen

from export_sheet import headline_stats, next_move_suggestions, score_wishlist


HOST = "0.0.0.0"  # gated by ALLOWED_CLIENT_NETS below — loopback + Tailscale only
PORT = 8931
ROOT = Path(__file__).resolve().parent
DATA_FILE = ROOT / "data" / "watches.json"
PHOTOS_DIR = ROOT / "data" / "photos"
EXPORT_SCRIPT = ROOT / "export_sheet.py"
DATA_LOCK = threading.RLock()
SAFE_COMPONENT = re.compile(r"^[a-z0-9_.-]+$")
PURCHASED = re.compile(r"^\d{4}-(0[1-9]|1[0-2])$")
ALLOWED_PHOTO_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".heic"}
AUTO_IMAGE_LIMIT = 5 * 1024 * 1024
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) WatchCollection/1.10"
STATUSES = {
    "owned", "given_away", "sold", "broken", "donated", "ousted",
    "want_to_buy_back", "giving_away",
}
WISHLIST_STATUSES = {"considering", "passed", "bought"}
WATCH_FIELDS = {
    "name", "story", "purchased", "purchasedText", "diameter", "lugToLug",
    "price", "original", "status", "statusNote", "category", "dialColor",
    "material", "brand",
}
WISHLIST_FIELDS = {
    "name", "brand", "category", "priceExpected", "priceNote", "notes",
    "status", "added", "dialColor", "diameter", "lugToLug", "material",
}
TAXONOMIES = {
    "categories": ("categories", "category"),
    "dialcolors": ("dialColors", "dialColor"),
    "materials": ("materials", "material"),
}
STATIC_FILES = {
    "/": ROOT / "index.html",
    "/index.html": ROOT / "index.html",
    "/styles.css": ROOT / "styles.css",
    "/app.js": ROOT / "app.js",
    "/icon.svg": ROOT / "icon.svg",
    "/static/manifest.webmanifest": ROOT / "static" / "manifest.webmanifest",
    "/static/apple-touch-icon.png": ROOT / "static" / "apple-touch-icon.png",
    "/static/icon-192.png": ROOT / "static" / "icon-192.png",
    "/static/icon-512.png": ROOT / "static" / "icon-512.png",
    "/static/favicon-32.png": ROOT / "static" / "favicon-32.png",
}
mimetypes.add_type("application/manifest+json", ".webmanifest")


class ApiError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


def read_data() -> dict:
    with DATA_FILE.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def read_data_with_stats() -> dict:
    with DATA_LOCK:
        data = read_data()
        watches = data.get("watches", [])
        data["headlineStats"] = {
            "owned": headline_stats([watch for watch in watches if watch.get("status") == "owned"]),
            "all": headline_stats(watches),
        }
        return data


def atomic_write_data(data: dict) -> None:
    """Durably write a complete JSON snapshot and atomically replace the old one."""
    DATA_FILE.parent.mkdir(parents=True, exist_ok=True)
    temporary = DATA_FILE.with_name(f".{DATA_FILE.name}.{uuid.uuid4().hex}.tmp")
    try:
        with temporary.open("x", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, DATA_FILE)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def is_safe_component(value: str) -> bool:
    return bool(value and ".." not in value and SAFE_COMPONENT.fullmatch(value))


def slugify(name: str) -> str:
    normalized = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode("ascii")
    return re.sub(r"[^a-z0-9]+", "-", normalized.lower()).strip("-") or "watch"


def unique_id(items: list[dict], name: str) -> str:
    existing = {str(item.get("id")) for item in items}
    base = slugify(name)
    result = base
    suffix = 2
    while result in existing:
        result = f"{base}-{suffix}"
        suffix += 1
    return result


def _number(value: object, field: str, *, nullable: bool, nonnegative: bool = False) -> None:
    if value is None and nullable:
        return
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ApiError(HTTPStatus.BAD_REQUEST, f"{field} must be a number" + (" or null" if nullable else ""))
    if (nonnegative and value < 0) or (not nonnegative and value <= 0):
        qualifier = "non-negative" if nonnegative else "greater than zero"
        raise ApiError(HTTPStatus.BAD_REQUEST, f"{field} must be {qualifier}")


def validate_changes(changes: object, kind: str) -> dict:
    if not isinstance(changes, dict):
        raise ApiError(HTTPStatus.BAD_REQUEST, "JSON body must be an object")
    allowed = WATCH_FIELDS if kind == "watch" else WISHLIST_FIELDS
    unexpected = set(changes) - allowed
    if unexpected:
        raise ApiError(HTTPStatus.BAD_REQUEST, f"Unsupported field(s): {', '.join(sorted(unexpected))}")
    clean = dict(changes)
    string_fields = (
        ("name", "story", "purchasedText", "statusNote", "brand")
        if kind == "watch"
        else ("name", "brand", "priceNote", "notes")
    )
    for field in string_fields:
        if field in clean and not isinstance(clean[field], str):
            raise ApiError(HTTPStatus.BAD_REQUEST, f"{field} must be a string")
    if "name" in clean and not clean["name"].strip():
        raise ApiError(HTTPStatus.BAD_REQUEST, "name is required")
    for field in ("category", "dialColor", "material"):
        if field in clean and clean[field] is not None and not isinstance(clean[field], str):
            raise ApiError(HTTPStatus.BAD_REQUEST, f"{field} must be a string or null")
    for field in ("diameter", "lugToLug"):
        if field in clean:
            _number(clean[field], field, nullable=True)
    if kind == "watch":
        if "purchased" in clean:
            value = clean["purchased"]
            if value is not None and (not isinstance(value, str) or not PURCHASED.fullmatch(value)):
                raise ApiError(HTTPStatus.BAD_REQUEST, "purchased must be YYYY-MM or null")
        if "price" in clean:
            _number(clean["price"], "price", nullable=False, nonnegative=True)
        if "original" in clean and clean["original"] is not None and not isinstance(clean["original"], bool):
            raise ApiError(HTTPStatus.BAD_REQUEST, "original must be true, false, or null")
        if "status" in clean and clean["status"] not in STATUSES:
            raise ApiError(HTTPStatus.BAD_REQUEST, "invalid status")
    else:
        if "priceExpected" in clean:
            _number(clean["priceExpected"], "priceExpected", nullable=True, nonnegative=True)
        if "added" in clean:
            value = clean["added"]
            if not isinstance(value, str) or not PURCHASED.fullmatch(value):
                raise ApiError(HTTPStatus.BAD_REQUEST, "added must be YYYY-MM")
        if "status" in clean and clean["status"] not in WISHLIST_STATUSES:
            raise ApiError(HTTPStatus.BAD_REQUEST, "invalid wishlist status")
    return clean


def validate_taxonomy_values(data: dict, changes: dict) -> None:
    mapping = {"category": "categories", "dialColor": "dialColors", "material": "materials"}
    for field, top_level in mapping.items():
        value = changes.get(field)
        if value is not None and field in changes and value not in data.get(top_level, []):
            raise ApiError(HTTPStatus.BAD_REQUEST, f"Unknown {field}: {value}")


def photo_owner(data: dict, kind: str, item_id: str) -> tuple[dict | None, str]:
    if kind == "watch":
        return next((item for item in data.get("watches", []) if item.get("id") == item_id), None), item_id
    return next((item for item in data.get("wishlist", []) if item.get("id") == item_id), None), f"wl-{item_id}"


def parse_ddg_vqd(document: str) -> str | None:
    for pattern in (r'vqd=["\']?([\d-]+)', r'["\']vqd["\']\s*:\s*["\']([\d-]+)'):
        match = re.search(pattern, document)
        if match:
            return match.group(1)
    return None


def extract_ddg_image_urls(payload: object) -> list[str]:
    if not isinstance(payload, dict) or not isinstance(payload.get("results"), list):
        return []
    return [item["image"] for item in payload["results"] if isinstance(item, dict) and isinstance(item.get("image"), str)]


def extract_bing_image_urls(document: str) -> list[str]:
    decoded = html.unescape(document)
    results: list[str] = []
    for match in re.finditer(r'"murl"\s*:\s*"((?:\\.|[^"\\])*)"', decoded, re.IGNORECASE):
        try:
            value = json.loads(f'"{match.group(1)}"')
        except json.JSONDecodeError:
            continue
        if isinstance(value, str) and value.startswith(("http://", "https://")) and value not in results:
            results.append(value)
    return results


def image_extension(payload: bytes) -> str | None:
    if payload.startswith(b"\xff\xd8\xff"):
        return ".jpg"
    if payload.startswith(b"\x89PNG\r\n\x1a\n"):
        return ".png"
    if len(payload) >= 12 and payload[:4] == b"RIFF" and payload[8:12] == b"WEBP":
        return ".webp"
    return None


def _request(url: str, *, timeout: int = 10):
    return urlopen(Request(url, headers={"User-Agent": USER_AGENT, "Accept-Encoding": "identity"}), timeout=timeout)


def find_image_candidates(query: str) -> list[str]:
    candidates: list[str] = []
    try:
        with _request("https://duckduckgo.com/?" + urlencode({"q": query, "iax": "images", "ia": "images"})) as response:
            landing = response.read(1_000_000).decode("utf-8", "replace")
        vqd = parse_ddg_vqd(landing)
        if vqd:
            endpoint = "https://duckduckgo.com/i.js?" + urlencode({"q": query, "o": "json", "vqd": vqd, "f": ",,,", "p": "1"})
            with _request(endpoint) as response:
                payload = json.loads(response.read(2_000_000).decode("utf-8", "replace"))
            candidates.extend(extract_ddg_image_urls(payload))
    except (OSError, HTTPError, URLError, ValueError, json.JSONDecodeError):
        pass
    if candidates:
        return candidates
    try:
        url = "https://www.bing.com/images/search?" + urlencode({"q": query, "form": "HDRSC3"})
        with _request(url) as response:
            document = response.read(2_000_000).decode("utf-8", "replace")
        candidates.extend(extract_bing_image_urls(document))
    except (OSError, HTTPError, URLError):
        pass
    return candidates


def download_image(url: str) -> tuple[str, bytes] | None:
    try:
        with _request(url) as response:
            length = response.headers.get("Content-Length")
            if length and int(length) > AUTO_IMAGE_LIMIT:
                return None
            payload = response.read(AUTO_IMAGE_LIMIT + 1)
    except (OSError, HTTPError, URLError, ValueError):
        return None
    if not payload or len(payload) > AUTO_IMAGE_LIMIT:
        return None
    extension = image_extension(payload)
    return (extension, payload) if extension else None


def google_image_search_url(name: str) -> str:
    return f"https://www.google.com/search?tbm=isch&q={quote_plus(name + ' watch')}"


def auto_image_for_wishlist(item_id: str) -> dict:
    with DATA_LOCK:
        data = read_data()
        item, directory_name = photo_owner(data, "wishlist", item_id)
        if item is None:
            raise ApiError(HTTPStatus.NOT_FOUND, "Wishlist entry not found")
        name = str(item.get("name", ""))
    search_url = google_image_search_url(name)
    found: tuple[str, bytes] | None = None
    for candidate in find_image_candidates(f"{name} watch")[:12]:
        found = download_image(candidate)
        if found:
            break
    if not found:
        return {"ok": False, "searchUrl": search_url}
    extension, payload = found
    destination_dir = PHOTOS_DIR / directory_name
    destination_dir.mkdir(parents=True, exist_ok=True)
    filename = f"auto-{uuid.uuid4().hex}{extension}"
    destination = destination_dir / filename
    with destination.open("xb") as handle:
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())
    old_auto: list[str] = []
    try:
        with DATA_LOCK:
            data = read_data()
            item, _directory_name = photo_owner(data, "wishlist", item_id)
            if item is None:
                raise ApiError(HTTPStatus.NOT_FOUND, "Wishlist entry not found")
            old_auto = [photo for photo in item.get("photos", []) if str(photo).startswith("auto-")]
            user_photos = [photo for photo in item.get("photos", []) if not str(photo).startswith("auto-")]
            item["photos"] = user_photos + [filename]
            atomic_write_data(data)
            photos = list(item["photos"])
    except Exception:
        destination.unlink(missing_ok=True)
        raise
    for old in old_auto:
        try:
            (destination_dir / old).unlink()
        except FileNotFoundError:
            pass
    return {"ok": True, "photos": photos, "filename": filename}


class WatchHandler(BaseHTTPRequestHandler):
    server_version = "WatchCollection/1.12"

    def log_message(self, format_string: str, *args: object) -> None:
        sys.stderr.write(f"{self.log_date_time_string()} {self.client_address[0]} {format_string % args}\n")

    def _path_parts(self) -> tuple[str, list[str]]:
        path = unquote(urlsplit(self.path).path)
        return path, [part for part in path.split("/") if part]

    def _send_headers(self, status: int, content_type: str, length: int) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()

    def send_json(self, status: int, payload: object) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self._send_headers(status, "application/json; charset=utf-8", len(body))
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_error_json(self, status: int, message: str) -> None:
        self.send_json(status, {"ok": False, "error": message})

    def send_file(self, path: Path, content_type: str | None = None) -> None:
        try:
            size = path.stat().st_size
            guessed = content_type or mimetypes.guess_type(path.name)[0] or "application/octet-stream"
            self._send_headers(HTTPStatus.OK, guessed, size)
            if self.command != "HEAD":
                with path.open("rb") as handle:
                    shutil.copyfileobj(handle, self.wfile)
        except FileNotFoundError:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Not found")

    def read_json_body(self, maximum: int = 1_000_000) -> object:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as exc:
            raise ApiError(HTTPStatus.BAD_REQUEST, "Invalid Content-Length") from exc
        if length <= 0:
            raise ApiError(HTTPStatus.BAD_REQUEST, "Request body is required")
        if length > maximum:
            raise ApiError(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "Request body is too large")
        try:
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ApiError(HTTPStatus.BAD_REQUEST, "Invalid JSON") from exc

    def read_photo_upload(self) -> tuple[str, bytes]:
        content_type = self.headers.get("Content-Type", "")
        if not content_type.lower().startswith("multipart/form-data"):
            raise ApiError(HTTPStatus.BAD_REQUEST, "Content-Type must be multipart/form-data")
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as exc:
            raise ApiError(HTTPStatus.BAD_REQUEST, "Invalid Content-Length") from exc
        if length <= 0 or length > 25 * 1024 * 1024:
            raise ApiError(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "Photo must be between 1 byte and 25 MB")
        body = self.rfile.read(length)
        message = BytesParser(policy=policy.default).parsebytes(
            b"Content-Type: " + content_type.encode("latin-1") + b"\r\nMIME-Version: 1.0\r\n\r\n" + body
        )
        if not message.is_multipart():
            raise ApiError(HTTPStatus.BAD_REQUEST, "Malformed multipart upload")
        for part in message.iter_parts():
            original_name = part.get_filename()
            if not original_name:
                continue
            extension = Path(original_name).suffix.lower()
            if extension not in ALLOWED_PHOTO_EXTENSIONS:
                raise ApiError(HTTPStatus.BAD_REQUEST, "Photo type must be jpg, png, webp, or heic")
            payload = part.get_payload(decode=True)
            if not payload:
                raise ApiError(HTTPStatus.BAD_REQUEST, "Uploaded photo is empty")
            return extension, payload
        raise ApiError(HTTPStatus.BAD_REQUEST, "No photo file found in upload")

    def _dispatch_errors(self, callback) -> None:
        try:
            callback()
        except ApiError as exc:
            self.send_error_json(exc.status, exc.message)
        except subprocess.TimeoutExpired:
            self.send_error_json(HTTPStatus.GATEWAY_TIMEOUT, "Backup timed out")
        except (OSError, json.JSONDecodeError) as exc:
            self.send_error_json(HTTPStatus.INTERNAL_SERVER_ERROR, f"Operation failed: {exc}")

    def do_HEAD(self) -> None:
        self.do_GET()

    def do_GET(self) -> None:
        path, parts = self._path_parts()
        if path == "/api/data":
            self._dispatch_errors(lambda: self.send_json(HTTPStatus.OK, read_data_with_stats()))
            return
        if path == "/api/wishlist/scores":
            def send_scores() -> None:
                with DATA_LOCK:
                    data = read_data()
                    scores = {
                        item["id"]: score_wishlist(item, data)
                        for item in data.get("wishlist", [])
                    }
                self.send_json(HTTPStatus.OK, {"scores": scores})

            self._dispatch_errors(send_scores)
            return
        if path == "/api/suggestions":
            def send_suggestions() -> None:
                with DATA_LOCK:
                    payload = next_move_suggestions(read_data())
                self.send_json(HTTPStatus.OK, payload)

            self._dispatch_errors(send_suggestions)
            return
        if len(parts) == 3 and parts[0] == "photos":
            item_id, filename = parts[1], parts[2]
            if not is_safe_component(item_id) or not is_safe_component(filename):
                self.send_error_json(HTTPStatus.BAD_REQUEST, "Unsafe photo path")
                return
            photo = PHOTOS_DIR / item_id / filename
            if not photo.is_file():
                self.send_error_json(HTTPStatus.NOT_FOUND, "Photo not found")
            else:
                self.send_file(photo)
            return
        if path == "/favicon.ico":
            self._send_headers(HTTPStatus.NO_CONTENT, "image/x-icon", 0)
            return
        static = STATIC_FILES.get(path)
        if static is not None:
            self.send_file(static)
        else:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Not found")

    def do_PUT(self) -> None:
        def dispatch():
            _path, parts = self._path_parts()
            body = self.read_json_body()
            if len(parts) == 3 and parts[:2] == ["api", "watches"]:
                self.update_entity("watch", parts[2], body)
            elif len(parts) == 3 and parts[:2] == ["api", "wishlist"]:
                self.update_entity("wishlist", parts[2], body)
            elif parts == ["api", "settings"]:
                self.update_settings(body)
            elif len(parts) == 2 and parts[0] == "api" and parts[1] in TAXONOMIES:
                self.update_taxonomy(parts[1], body)
            else:
                raise ApiError(HTTPStatus.NOT_FOUND, "Not found")
        self._dispatch_errors(dispatch)

    def do_POST(self) -> None:
        def dispatch():
            _path, parts = self._path_parts()
            if parts == ["api", "watches"]:
                self.create_entity("watch", self.read_json_body())
            elif parts == ["api", "wishlist"]:
                self.create_entity("wishlist", self.read_json_body())
            elif parts == ["api", "brandwatchlist"]:
                self.create_radar_brand(self.read_json_body())
            elif parts == ["api", "backup"]:
                self.run_backup()
            elif len(parts) == 4 and parts[0] == "api" and parts[1] in ("watches", "wishlist") and parts[3] == "photos":
                self.upload_photo("watch" if parts[1] == "watches" else "wishlist", parts[2])
            elif len(parts) == 6 and parts[0] == "api" and parts[1] in ("watches", "wishlist") and parts[3] == "photos" and parts[5] == "cover":
                self.set_cover("watch" if parts[1] == "watches" else "wishlist", parts[2], parts[4])
            elif len(parts) == 4 and parts[:2] == ["api", "wishlist"] and parts[3] == "autoimage":
                self.send_json(HTTPStatus.OK, auto_image_for_wishlist(parts[2]))
            elif len(parts) == 4 and parts[:2] == ["api", "wishlist"] and parts[3] == "bought":
                self.mark_bought(parts[2], self.read_json_body())
            else:
                raise ApiError(HTTPStatus.NOT_FOUND, "Not found")
        self._dispatch_errors(dispatch)

    def do_DELETE(self) -> None:
        def dispatch():
            _path, parts = self._path_parts()
            if len(parts) == 3 and parts[:2] == ["api", "watches"]:
                self.delete_entity("watch", parts[2])
            elif len(parts) == 3 and parts[:2] == ["api", "wishlist"]:
                self.delete_entity("wishlist", parts[2])
            elif len(parts) == 3 and parts[:2] == ["api", "brandwatchlist"]:
                self.delete_radar_brand(parts[2])
            elif len(parts) == 5 and parts[0] == "api" and parts[1] in ("watches", "wishlist") and parts[3] == "photos":
                self.delete_photo("watch" if parts[1] == "watches" else "wishlist", parts[2], parts[4])
            else:
                raise ApiError(HTTPStatus.NOT_FOUND, "Not found")
        self._dispatch_errors(dispatch)

    def update_entity(self, kind: str, item_id: str, body: object) -> None:
        if not is_safe_component(item_id):
            raise ApiError(HTTPStatus.BAD_REQUEST, "Unsafe id")
        changes = validate_changes(body, kind)
        key = "watches" if kind == "watch" else "wishlist"
        with DATA_LOCK:
            data = read_data()  # re-read inside the write lock before every merge
            validate_taxonomy_values(data, changes)
            item = next((value for value in data.get(key, []) if value.get("id") == item_id), None)
            if item is None:
                raise ApiError(HTTPStatus.NOT_FOUND, f"{kind.title()} not found")
            item.update(changes)
            atomic_write_data(data)
            result = dict(item)
        self.send_json(HTTPStatus.OK, result)

    def create_entity(self, kind: str, body: object) -> None:
        changes = validate_changes(body, kind)
        name = str(changes.get("name", "")).strip()
        if not name:
            raise ApiError(HTTPStatus.BAD_REQUEST, "name is required")
        key = "watches" if kind == "watch" else "wishlist"
        with DATA_LOCK:
            data = read_data()
            validate_taxonomy_values(data, changes)
            item_id = unique_id(data.get(key, []), name)
            if kind == "watch":
                item = {
                    "id": item_id, "name": name, "story": "", "purchased": None,
                    "purchasedText": "", "diameter": None, "lugToLug": None,
                    "price": 0, "original": None, "status": "owned", "statusNote": "",
                    "photos": [], "category": None, "dialColor": None, "material": None,
                }
            else:
                item = {
                    "id": item_id, "name": name, "brand": "", "category": None,
                    "priceExpected": None, "priceNote": "", "notes": "",
                    "status": "considering", "added": datetime.now().strftime("%Y-%m"),
                    "dialColor": None, "diameter": None, "lugToLug": None,
                    "material": None, "photos": [],
                }
            item.update(changes)
            item["name"] = name
            data.setdefault(key, []).append(item)
            auto_image = kind == "wishlist" and bool(data.get("settings", {}).get("autoImage", True))
            atomic_write_data(data)
        auto_result = None
        if auto_image:
            try:
                auto_result = auto_image_for_wishlist(item_id)
                with DATA_LOCK:
                    refreshed = read_data()
                    item = next(value for value in refreshed["wishlist"] if value["id"] == item_id)
            except (ApiError, OSError, ValueError, json.JSONDecodeError):
                auto_result = {"ok": False, "searchUrl": google_image_search_url(name)}
        response = dict(item)
        if auto_result is not None:
            response["autoImageResult"] = auto_result
        self.send_json(HTTPStatus.CREATED, response)

    def delete_entity(self, kind: str, item_id: str) -> None:
        if not is_safe_component(item_id):
            raise ApiError(HTTPStatus.BAD_REQUEST, "Unsafe id")
        key = "watches" if kind == "watch" else "wishlist"
        directory = item_id if kind == "watch" else f"wl-{item_id}"
        with DATA_LOCK:
            data = read_data()
            position = next((index for index, item in enumerate(data.get(key, [])) if item.get("id") == item_id), None)
            if position is None:
                raise ApiError(HTTPStatus.NOT_FOUND, f"{kind.title()} not found")
            removed = data[key].pop(position)
            atomic_write_data(data)
            shutil.rmtree(PHOTOS_DIR / directory, ignore_errors=True)
        self.send_json(HTTPStatus.OK, {"ok": True, kind: removed})

    def upload_photo(self, kind: str, item_id: str) -> None:
        if not is_safe_component(item_id):
            raise ApiError(HTTPStatus.BAD_REQUEST, "Unsafe id")
        extension, payload = self.read_photo_upload()
        with DATA_LOCK:
            data = read_data()
            item, directory_name = photo_owner(data, kind, item_id)
            if item is None:
                raise ApiError(HTTPStatus.NOT_FOUND, f"{kind.title()} not found")
            destination_dir = PHOTOS_DIR / directory_name
            destination_dir.mkdir(parents=True, exist_ok=True)
            filename = f"{uuid.uuid4().hex}{extension}"
            destination = destination_dir / filename
            try:
                with destination.open("xb") as handle:
                    handle.write(payload)
                    handle.flush()
                    os.fsync(handle.fileno())
                photos = item.setdefault("photos", [])
                # Manual uploads always become cover and therefore outrank auto images.
                photos.insert(0, filename)
                atomic_write_data(data)
            except Exception:
                destination.unlink(missing_ok=True)
                raise
            photos = list(item["photos"])
        self.send_json(HTTPStatus.CREATED, {"ok": True, "photos": photos, "filename": filename})

    def delete_photo(self, kind: str, item_id: str, filename: str) -> None:
        if not is_safe_component(item_id) or not is_safe_component(filename):
            raise ApiError(HTTPStatus.BAD_REQUEST, "Unsafe photo path")
        with DATA_LOCK:
            data = read_data()
            item, directory_name = photo_owner(data, kind, item_id)
            if item is None:
                raise ApiError(HTTPStatus.NOT_FOUND, f"{kind.title()} not found")
            if filename not in item.get("photos", []):
                raise ApiError(HTTPStatus.NOT_FOUND, "Photo not found")
            item["photos"].remove(filename)
            atomic_write_data(data)
            try:
                (PHOTOS_DIR / directory_name / filename).unlink()
            except FileNotFoundError:
                pass
            try:
                (PHOTOS_DIR / directory_name).rmdir()
            except OSError:
                pass
            photos = list(item["photos"])
        self.send_json(HTTPStatus.OK, {"ok": True, "photos": photos})

    def set_cover(self, kind: str, item_id: str, filename: str) -> None:
        if not is_safe_component(item_id) or not is_safe_component(filename):
            raise ApiError(HTTPStatus.BAD_REQUEST, "Unsafe photo path")
        with DATA_LOCK:
            data = read_data()
            item, _directory_name = photo_owner(data, kind, item_id)
            if item is None:
                raise ApiError(HTTPStatus.NOT_FOUND, f"{kind.title()} not found")
            if filename not in item.get("photos", []):
                raise ApiError(HTTPStatus.NOT_FOUND, "Photo not found")
            item["photos"].remove(filename)
            item["photos"].insert(0, filename)
            atomic_write_data(data)
            photos = list(item["photos"])
        self.send_json(HTTPStatus.OK, {"ok": True, "photos": photos})

    def update_settings(self, body: object) -> None:
        if not isinstance(body, dict):
            raise ApiError(HTTPStatus.BAD_REQUEST, "JSON body must be an object")
        allowed = {"autoBackup", "autoImage", "backupRemote", "suggestExclude", "wrist", "ownerName"}
        unexpected = set(body) - allowed
        if unexpected:
            raise ApiError(HTTPStatus.BAD_REQUEST, f"Unsupported setting(s): {', '.join(sorted(unexpected))}")
        for key in ("autoBackup", "autoImage"):
            if key in body and not isinstance(body[key], bool):
                raise ApiError(HTTPStatus.BAD_REQUEST, f"{key} must be true or false")
        if "backupRemote" in body and not isinstance(body["backupRemote"], str):
            raise ApiError(HTTPStatus.BAD_REQUEST, "backupRemote must be a string")
        if "ownerName" in body and body["ownerName"] is not None and not isinstance(body["ownerName"], str):
            raise ApiError(HTTPStatus.BAD_REQUEST, "ownerName must be a string or null")
        suggest_exclude = body.get("suggestExclude")
        if "suggestExclude" in body and (
            not isinstance(suggest_exclude, list)
            or any(not isinstance(value, str) or not value.strip() for value in suggest_exclude)
            or len(set(suggest_exclude)) != len(suggest_exclude)
        ):
            raise ApiError(HTTPStatus.BAD_REQUEST, "suggestExclude must be an array of unique category names")
        wrist_changes = body.get("wrist")
        if wrist_changes is not None:
            if not isinstance(wrist_changes, dict) or set(wrist_changes) - {"inches", "sweetSpotMin", "sweetSpotMax", "perfect", "lugMax"}:
                raise ApiError(HTTPStatus.BAD_REQUEST, "Invalid wrist profile")
            for field, value in wrist_changes.items():
                _number(value, f"wrist.{field}", nullable=False)
        with DATA_LOCK:
            data = read_data()
            if "suggestExclude" in body:
                unknown = set(suggest_exclude) - set(data.get("categories", []))
                if unknown:
                    raise ApiError(HTTPStatus.BAD_REQUEST, f"Unknown suggestion category: {', '.join(sorted(unknown))}")
            plain = {key: value for key, value in body.items() if key != "wrist"}
            data.setdefault("settings", {}).update(plain)
            if wrist_changes is not None:
                wrist = data["settings"].setdefault("wrist", {})
                wrist.update(wrist_changes)
                if wrist.get("sweetSpotMin", 0) > wrist.get("sweetSpotMax", 0):
                    raise ApiError(HTTPStatus.BAD_REQUEST, "sweetSpotMin cannot exceed sweetSpotMax")
            atomic_write_data(data)
            result = dict(data["settings"])
        self.send_json(HTTPStatus.OK, result)

    def update_taxonomy(self, route: str, body: object) -> None:
        if not isinstance(body, dict) or len(body) != 1:
            raise ApiError(HTTPStatus.BAD_REQUEST, "Supply exactly one taxonomy operation")
        top_level, field = TAXONOMIES[route]
        operation, value = next(iter(body.items()))
        with DATA_LOCK:
            data = read_data()
            values = data.get(top_level, [])
            if operation == "add":
                if not isinstance(value, str) or not value.strip():
                    raise ApiError(HTTPStatus.BAD_REQUEST, "Name is required")
                name = value.strip()
                if name in values:
                    raise ApiError(HTTPStatus.CONFLICT, "Name already exists")
                values.append(name)
            elif operation == "rename":
                if not isinstance(value, dict) or set(value) != {"from", "to"}:
                    raise ApiError(HTTPStatus.BAD_REQUEST, "rename requires from and to")
                old, new = value["from"], value["to"]
                if not isinstance(old, str) or not isinstance(new, str) or not new.strip():
                    raise ApiError(HTTPStatus.BAD_REQUEST, "Invalid rename")
                new = new.strip()
                if old not in values:
                    raise ApiError(HTTPStatus.NOT_FOUND, "Name not found")
                if new != old and new in values:
                    raise ApiError(HTTPStatus.CONFLICT, "Name already exists")
                values[values.index(old)] = new
                for item in data.get("watches", []) + data.get("wishlist", []):
                    if item.get(field) == old:
                        item[field] = new
                if top_level == "categories":
                    excluded = data.get("settings", {}).get("suggestExclude", [])
                    data.setdefault("settings", {})["suggestExclude"] = [new if name == old else name for name in excluded]
            elif operation == "delete":
                if not isinstance(value, str) or value not in values:
                    raise ApiError(HTTPStatus.NOT_FOUND, "Name not found")
                uses = sum(item.get(field) == value for item in data.get("watches", []) + data.get("wishlist", []))
                if uses:
                    raise ApiError(HTTPStatus.CONFLICT, f"Cannot delete: used by {uses} item(s); reassign them first")
                values.remove(value)
                if top_level == "categories":
                    excluded = data.get("settings", {}).get("suggestExclude", [])
                    data.setdefault("settings", {})["suggestExclude"] = [name for name in excluded if name != value]
            elif operation == "reorder":
                if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
                    raise ApiError(HTTPStatus.BAD_REQUEST, "reorder must be an array of names")
                if len(value) != len(values) or set(value) != set(values):
                    raise ApiError(HTTPStatus.BAD_REQUEST, "reorder must contain every name exactly once")
                data[top_level] = list(value)
                values = data[top_level]
            else:
                raise ApiError(HTTPStatus.BAD_REQUEST, "Unknown taxonomy operation")
            atomic_write_data(data)
            result = list(values)
        self.send_json(HTTPStatus.OK, {top_level: result})

    def create_radar_brand(self, body: object) -> None:
        if not isinstance(body, dict) or set(body) - {"brand", "notes", "added"}:
            raise ApiError(HTTPStatus.BAD_REQUEST, "Invalid radar brand")
        brand = body.get("brand")
        if not isinstance(brand, str) or not brand.strip():
            raise ApiError(HTTPStatus.BAD_REQUEST, "brand is required")
        item = {"brand": brand.strip(), "notes": str(body.get("notes", "")), "added": body.get("added") or datetime.now().strftime("%Y-%m")}
        if not PURCHASED.fullmatch(str(item["added"])):
            raise ApiError(HTTPStatus.BAD_REQUEST, "added must be YYYY-MM")
        with DATA_LOCK:
            data = read_data()
            if any(entry.get("brand", "").casefold() == item["brand"].casefold() for entry in data.get("brandWatchlist", [])):
                raise ApiError(HTTPStatus.CONFLICT, "Brand already on radar")
            data.setdefault("brandWatchlist", []).append(item)
            atomic_write_data(data)
        self.send_json(HTTPStatus.CREATED, item)

    def delete_radar_brand(self, brand: str) -> None:
        with DATA_LOCK:
            data = read_data()
            position = next((index for index, item in enumerate(data.get("brandWatchlist", [])) if item.get("brand") == brand), None)
            if position is None:
                raise ApiError(HTTPStatus.NOT_FOUND, "Radar brand not found")
            removed = data["brandWatchlist"].pop(position)
            atomic_write_data(data)
        self.send_json(HTTPStatus.OK, {"ok": True, "brand": removed})

    def mark_bought(self, item_id: str, body: object) -> None:
        if not is_safe_component(item_id) or not isinstance(body, dict):
            raise ApiError(HTTPStatus.BAD_REQUEST, "Invalid request")
        if set(body) != {"price", "purchased"}:
            raise ApiError(HTTPStatus.BAD_REQUEST, "price and purchased are required")
        _number(body["price"], "price", nullable=False, nonnegative=True)
        if not isinstance(body["purchased"], str) or not PURCHASED.fullmatch(body["purchased"]):
            raise ApiError(HTTPStatus.BAD_REQUEST, "purchased must be YYYY-MM")
        with DATA_LOCK:
            data = read_data()
            item = next((entry for entry in data.get("wishlist", []) if entry.get("id") == item_id), None)
            if item is None:
                raise ApiError(HTTPStatus.NOT_FOUND, "Wishlist entry not found")
            if item.get("status") == "bought":
                raise ApiError(HTTPStatus.CONFLICT, "Candidate is already marked bought")
            watch_id = unique_id(data.get("watches", []), str(item.get("name", "watch")))
            watch = {
                "id": watch_id, "name": item.get("name", ""), "brand": item.get("brand", ""),
                "story": item.get("notes", ""), "purchased": body["purchased"],
                "purchasedText": body["purchased"], "diameter": item.get("diameter"),
                "lugToLug": item.get("lugToLug"), "price": body["price"], "original": True,
                "status": "owned", "statusNote": "", "photos": [],
                "category": item.get("category"), "dialColor": item.get("dialColor"),
                "material": item.get("material"),
            }
            data["watches"].append(watch)
            item["status"] = "bought"
            atomic_write_data(data)
        self.send_json(HTTPStatus.CREATED, {"ok": True, "watch": watch, "wishlist": item})

    def run_backup(self) -> None:
        process = subprocess.run(
            [sys.executable, str(EXPORT_SCRIPT), "--force"], cwd=ROOT,
            capture_output=True, text=True, timeout=300, check=False,
        )
        output = "\n".join(part.strip() for part in (process.stdout, process.stderr) if part.strip())
        if process.returncode != 0:
            self.send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"ok": False, "output": output or "Backup failed", "returncode": process.returncode})
            return
        timestamp = datetime.now().astimezone().isoformat(timespec="seconds")
        with DATA_LOCK:
            data = read_data()
            data.setdefault("settings", {})["lastBackup"] = timestamp
            atomic_write_data(data)
        self.send_json(HTTPStatus.OK, {"ok": True, "output": output, "lastBackup": timestamp})


import ipaddress

# Loopback + Tailscale CGNAT range only. The app must never be reachable from the open
# internet or even plain LAN — remote access is expected to come in over Tailscale.
ALLOWED_CLIENT_NETS = [
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("::1/128"),
    ipaddress.ip_network("100.64.0.0/10"),
]


class WatchServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def verify_request(self, request, client_address) -> bool:
        try:
            client = ipaddress.ip_address(client_address[0].split("%")[0])
        except ValueError:
            return False
        if isinstance(client, ipaddress.IPv6Address) and client.ipv4_mapped:
            client = client.ipv4_mapped
        return any(client in net for net in ALLOWED_CLIENT_NETS)


def main() -> None:
    if not DATA_FILE.is_file():
        raise SystemExit(f"Missing data file: {DATA_FILE}")
    PHOTOS_DIR.mkdir(parents=True, exist_ok=True)
    server = WatchServer((HOST, PORT), WatchHandler)
    print(f"Watch Collection running at http://{HOST}:{PORT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
