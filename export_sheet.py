#!/usr/bin/env python3
"""Export the watch collection and every v1.12 analysis section to CSV."""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import shutil
import subprocess
import sys
import uuid
from collections import Counter, defaultdict
from datetime import date
from pathlib import Path


ROOT = Path(__file__).resolve().parent
DATA_FILE = ROOT / "data" / "watches.json"
EXPORTS_DIR = ROOT / "exports"
RCLONE = Path("~/.local/bin/rclone").expanduser()
DEFAULT_REMOTE = "gdrive:WatchCollection/"
PERCENTILES = (10, 25, 50, 75, 80, 90, 95)
PRICE_TIERS = (
    ("<$50", 0, 50), ("$50–100", 50, 100), ("$100–200", 100, 200),
    ("$200–300", 200, 300), ("$300–500", 300, 500), ("$500–750", 500, 750),
    ("$750–1000", 750, 1000), ("$1000–2500", 1000, 2500),
    ("$2500+", 2500, math.inf),
)
DEFAULT_SUGGEST_EXCLUDE = (
    "Smartwatch", "Other", "Iced Out", "Novelty", "Fashion/Minimalist",
)
DIAL_PLAUSIBILITY = {
    "Pilot": ("Black", "White", "Blue", "Green"),
    "Dress": ("White", "Silver", "Cream", "Blue", "Green"),
    "Field": ("Green", "Cream", "Brown", "Black"),
    "GMT": ("Black", "Blue", "Green"),
    "Chronograph": ("White", "Black", "Blue"),
    "Integrated Bracelet": ("Blue", "Green", "Silver", "Grey"),
}
MATERIAL_PLAUSIBILITY = {
    "Pilot": ("Titanium", "Bronze", "Ceramic", "Stainless Steel", "Carbon"),
    "Dress": ("Titanium", "Bronze", "Ceramic", "Stainless Steel", "Gold-plated/PVD", "Two-tone"),
    "Field": ("Titanium", "Bronze", "Ceramic", "Stainless Steel", "Carbon"),
    "GMT": ("Titanium", "Bronze", "Ceramic", "Stainless Steel"),
    "Chronograph": ("Titanium", "Bronze", "Ceramic", "Stainless Steel", "Carbon"),
    "Integrated Bracelet": ("Titanium", "Bronze", "Ceramic", "Stainless Steel"),
    "G-Shock/Digital": ("Titanium", "Ceramic", "Stainless Steel", "Carbon", "Plastic/Resin"),
    "Casual": ("Titanium", "Bronze", "Ceramic", "Stainless Steel", "Aluminum", "Plastic/Resin"),
}
BRAND_RECOMMENDATION_POOL = {
    "Field": ("Hamilton", "Baltic", "Zelos", "Straum", "Marathon"),
    "Pilot": ("Laco", "Stowa", "Hamilton", "Sinn", "IWC"),
    "GMT": ("Baltic", "Formex", "Zelos", "Lorier", "Longines"),
    "Integrated Bracelet": ("Tissot", "Formex", "Christopher Ward", "D1 Milano", "Citizen"),
    "Dress": ("Nomos", "Baltic", "Henry Archer", "Orient", "Junghans"),
    "Chronograph": ("Furlan Marri", "Dan Henry", "Baltic", "Seiko", "Omega"),
    "Dive": ("Zelos", "Baltic", "Christopher Ward", "Seiko"),
    "Casual": ("Casio", "Timex", "Swatch"),
    "G-Shock/Digital": ("Casio",),
}
BRAND_STATUS_ORDER = {"radar": 0, "new": 1, "explored": 2, "current": 3}


def money(value: float) -> str:
    return f"{value:.2f}"


def number(value: float | int | None) -> str:
    if value is None:
        return ""
    value = float(value)
    if math.isclose(value, round(value), abs_tol=1e-12):
        return str(int(round(value)))
    return f"{value:.4f}".rstrip("0").rstrip(".")


def percentile(values: list[float], percent: int) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    position = (len(ordered) - 1) * percent / 100
    lower, upper = math.floor(position), math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def headline_stats(watches: list[dict]) -> dict[str, float]:
    prices = [float(watch["price"]) for watch in watches if isinstance(watch.get("price"), (int, float)) and not isinstance(watch.get("price"), bool)]
    if not prices:
        return {key: 0.0 for key in ("count", "total", "mean", "median", "iqr", "min", "max", "stdDev", "skewness")}
    total = sum(prices)
    n = len(prices)
    mean = total / n
    # Sample (n-1) std dev + Sheets/Excel SKEW, matching common spreadsheet formulas
    deviation = math.sqrt(sum((price - mean) ** 2 for price in prices) / (n - 1)) if n > 1 else 0.0
    skewness = (
        (n / ((n - 1) * (n - 2))) * sum(((price - mean) / deviation) ** 3 for price in prices)
        if n > 2 and deviation
        else 0.0
    )
    return {
        "count": float(len(prices)), "total": total, "mean": mean,
        "median": percentile(prices, 50), "iqr": percentile(prices, 75) - percentile(prices, 25),
        "min": min(prices), "max": max(prices),
        "stdDev": deviation, "skewness": skewness,
    }


def histogram(watches: list[dict], field: str, bucket_size: int = 2) -> dict[int, int]:
    buckets: Counter[int] = Counter()
    for watch in watches:
        value = watch.get(field)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            buckets[math.floor(float(value) / bucket_size) * bucket_size] += 1
    return dict(sorted(buckets.items()))


def spend_by_year(watches: list[dict]) -> dict[str, float]:
    totals: defaultdict[str, float] = defaultdict(float)
    for watch in watches:
        if isinstance(watch.get("purchased"), str) and isinstance(watch.get("price"), (int, float)):
            totals[watch["purchased"][:4]] += float(watch["price"])
    return dict(sorted(totals.items()))


def brand_for(name: str) -> str:
    special_cases = (
        ("Audemars Piguet", "Audemars Piguet"), ("Miss Fox", "Miss Fox"),
        ("U.S. Polo Assn.", "U.S. Polo Assn."), ("Omega Moonswatch", "Omega"),
        ("Moonswatch", "Omega"), ("Casio G-Shock", "Casio"), ("Casio G-Steel", "Casio"),
        ("Christopher Ward", "Christopher Ward"), ("D1 Milano", "D1 Milano"),
        ("Henry Archer", "Henry Archer"), ("Furlan Marri", "Furlan Marri"),
        ("Dan Henry", "Dan Henry"),
        ("Rolex", "Rolex"),
    )
    lowered = name.casefold()
    for prefix, brand in special_cases:
        if lowered.startswith(prefix.casefold()):
            return brand
    return name.split()[0] if name.split() else "Unknown"


def watch_brand(watch: dict) -> str:
    return str(watch.get("brand") or brand_for(str(watch.get("name", ""))))


def price_tier(value: float | int | None) -> str | None:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return None
    for label, lower, upper in PRICE_TIERS:
        if lower <= float(value) < upper:
            return label
    return None


def cost_histogram(watches: list[dict]) -> dict[str, int]:
    counts = {label: 0 for label, _lower, _upper in PRICE_TIERS}
    for watch in watches:
        value = watch.get("price")
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            tier = price_tier(value)
            if tier is not None:
                counts[tier] += 1
    return counts


def originals_only(watches: list[dict]) -> list[dict]:
    # Price-ladder "originals only": no reps, no smartwatches ("real watches")
    return [watch for watch in watches if watch.get("original") is not False and watch.get("category") != "Smartwatch"]


def brand_breadth_watches(watches: list[dict]) -> list[dict]:
    # Brand breadth: no reps, no unbranded generics; smartwatch brands DO count as repeats
    return [watch for watch in watches if watch.get("original") is not False and watch_brand(watch) != "Generic"]


def fit_info(item: dict, wrist: dict) -> dict:
    lug = item.get("lugToLug")
    if isinstance(lug, (int, float)) and not isinstance(lug, bool):
        lug_max = float(wrist.get("lugMax", 47))
        # A measurement at least 1 mm below the comfort ceiling is clearly inside it.
        if lug <= lug_max - 1:
            return {"key": "great", "label": f"great fit · {number(lug)} L2L", "basis": "L2L", "score": 3}
        if lug <= lug_max:
            return {"key": "limit", "label": f"at the limit · {number(lug)} L2L", "basis": "L2L", "score": 2}
        delta = float(lug) - lug_max
        return {"key": "over", "label": f"+{number(delta)}mm L2L over", "basis": "L2L", "score": 0}
    diameter = item.get("diameter")
    if not isinstance(diameter, (int, float)) or isinstance(diameter, bool):
        return {"key": "unknown", "label": "", "basis": "none", "score": 0}
    minimum = float(wrist.get("sweetSpotMin", 35))
    maximum = float(wrist.get("sweetSpotMax", 40))
    perfect = float(wrist.get("perfect", 38))
    if abs(float(diameter) - perfect) <= 1:
        return {"key": "perfect", "label": f"perfect · {number(diameter)}mm", "basis": "diameter", "score": 3}
    if minimum <= diameter <= maximum:
        return {"key": "sweet", "label": f"sweet spot · {number(diameter)}mm", "basis": "diameter", "score": 2}
    if minimum - 1 <= diameter < minimum:
        delta = minimum - float(diameter)
        return {"key": "under", "label": f"−{number(delta)}mm under", "basis": "diameter", "score": 1}
    if maximum < diameter <= maximum + 1:
        delta = float(diameter) - maximum
        return {"key": "over", "label": f"+{number(delta)}mm over", "basis": "diameter", "score": 1}
    if diameter < minimum:
        delta = minimum - float(diameter)
        return {"key": "under", "label": f"−{number(delta)}mm under", "basis": "diameter", "score": 0}
    delta = float(diameter) - maximum
    return {"key": "over", "label": f"+{number(delta)}mm over", "basis": "diameter", "score": 0}


def brand_counts(watches: list[dict]) -> Counter:
    return Counter(watch_brand(watch) for watch in brand_breadth_watches(watches))


def recommended_brands(category: str, data: dict) -> list[dict[str, str]]:
    """Annotate the curated category pool using the collection's brand-breadth rules."""
    pool = BRAND_RECOMMENDATION_POOL.get(category, ())
    if not pool:
        return []

    watches = data.get("watches", [])
    current_counts = brand_counts([watch for watch in watches if watch.get("status") == "owned"])
    past_counts = brand_counts([watch for watch in watches if watch.get("status") != "owned"])
    radar = {
        str(item.get("brand", "")).casefold()
        for item in data.get("brandWatchlist", [])
        if item.get("brand")
    }

    def count_for(counts: Counter, brand: str) -> int:
        return sum(count for name, count in counts.items() if name.casefold() == brand.casefold())

    annotated = []
    for pool_index, brand in enumerate(pool):
        current_count = count_for(current_counts, brand)
        if current_count >= 2:
            continue
        if brand.casefold() in radar:
            status = "radar"
        elif current_count == 1:
            status = "current"
        elif count_for(past_counts, brand):
            status = "explored"
        else:
            status = "new"
        annotated.append((BRAND_STATUS_ORDER[status], pool_index, {"name": brand, "status": status}))

    annotated.sort(key=lambda row: (row[0], row[1]))
    return [row[2] for row in annotated[:4]]


def radar_reason(brands: list[dict[str, str]]) -> str | None:
    names = [brand["name"] for brand in brands if brand["status"] == "radar"]
    if not names:
        return None
    if len(names) == 1:
        return f"{names[0]} is already on your radar"
    if len(names) == 2:
        return f"{names[0]} and {names[1]} are already on your radar"
    return f"{', '.join(names[:-1])}, and {names[-1]} are already on your radar"


def score_wishlist(item: dict, data: dict) -> dict:
    owned = [watch for watch in data.get("watches", []) if watch.get("status") == "owned"]
    owned_originals = originals_only(owned)
    lenses: dict[str, dict] = {}

    category = item.get("category")
    if category is None:
        category_score, category_reason = 0, "category unset"
    else:
        count = sum(watch.get("category") == category for watch in owned)
        category_score = 3 if count == 0 else 2 if count == 1 else 1 if count == 2 else 0
        category_reason = f"{category} — " + ("you've never owned one" if count == 0 else f"{count} owned")
    lenses["category"] = {"score": category_score, "reason": category_reason}

    brand = str(item.get("brand") or brand_for(str(item.get("name", ""))))
    current_brands = brand_counts(owned)
    past_brands = brand_counts([watch for watch in data.get("watches", []) if watch.get("status") != "owned"])
    if current_brands[brand] >= 2:
        brand_score, brand_reason = -1, f"{brand} — {current_brands[brand]} currently owned"
    elif current_brands[brand] == 1:
        brand_score, brand_reason = 0, f"{brand} — currently owned"
    elif past_brands[brand]:
        brand_score, brand_reason = 1, f"{brand} — explored before, none kept"
    else:
        brand_score, brand_reason = 2, f"{brand} — new brand"
    lenses["brand"] = {"score": brand_score, "reason": brand_reason}

    tier = price_tier(item.get("priceExpected"))
    if tier is None:
        price_score, price_reason = 0, "price unset"
    else:
        all_count = sum(price_tier(watch.get("price")) == tier for watch in owned)
        originals_count = sum(price_tier(watch.get("price")) == tier for watch in owned_originals)
        if originals_count == 0:
            price_score, price_reason = 2, f"fills empty {tier} originals-only tier"
        elif all_count == 0:
            price_score, price_reason = 1, f"fills empty {tier} all-owned tier"
        else:
            price_score, price_reason = 0, f"{tier} tier already represented"
    lenses["price"] = {"score": price_score, "reason": price_reason}

    dial = item.get("dialColor")
    dial_count = sum(watch.get("dialColor") == dial for watch in owned) if dial is not None else 0
    dial_score = 0 if dial is None else 2 if dial_count == 0 else 1 if dial_count == 1 else 0
    dial_reason = "dial colour unset" if dial is None else f"{dial} dial — " + ("not represented" if dial_count == 0 else f"{dial_count} owned")
    lenses["dial"] = {"score": dial_score, "reason": dial_reason}

    fit = fit_info(item, data.get("settings", {}).get("wrist", {}))
    lenses["size"] = {"score": fit["score"], "reason": fit["label"] or "size unset"}

    material = item.get("material")
    material_count = sum(watch.get("material") == material for watch in owned) if material is not None else 0
    material_score = 0 if material is None else 2 if material_count == 0 else 1 if material_count == 1 else 0
    material_reason = "material unset" if material is None else f"{material} — " + ("not represented" if material_count == 0 else f"{material_count} owned")
    lenses["material"] = {"score": material_score, "reason": material_reason}

    return {"total": sum(lens["score"] for lens in lenses.values()), "max": 14, "lenses": lenses}


def next_move_suggestions(data: dict) -> dict:
    """Return deterministic collection-gap suggestions shared by API, CSV, web, and iOS."""
    owned = [watch for watch in data.get("watches", []) if watch.get("status") == "owned"]
    categories = list(data.get("categories", []))
    dial_colors = list(data.get("dialColors", []))
    materials = list(data.get("materials", []))
    category_counts = Counter(watch.get("category") for watch in owned if watch.get("category"))
    dial_counts = Counter(watch.get("dialColor") for watch in owned if watch.get("dialColor"))
    current_brand_counts = brand_counts(owned)

    saturated = {
        "categories": sorted(
            (name for name, count in category_counts.items() if count >= 3),
            key=lambda name: (-category_counts[name], categories.index(name) if name in categories else len(categories), name),
        ),
        "dials": sorted(
            (name for name, count in dial_counts.items() if count >= 2),
            key=lambda name: (-dial_counts[name], dial_colors.index(name) if name in dial_colors else len(dial_colors), name),
        ),
        "brands": sorted(
            (name for name, count in current_brand_counts.items() if count >= 2),
            key=lambda name: (-current_brand_counts[name], name),
        ),
    }

    excluded = set(data.get("settings", {}).get("suggestExclude", DEFAULT_SUGGEST_EXCLUDE))
    owned_dials = set(dial_counts)
    owned_materials = {watch.get("material") for watch in owned if watch.get("material")}
    owned_originals = originals_only(owned)
    empty_tiers = [
        (label, lower, upper)
        for label, lower, upper in PRICE_TIERS
        if not any(price_tier(watch.get("price")) == label for watch in owned_originals)
    ]
    price_gap = next((tier for tier in empty_tiers if tier[1] >= 200), empty_tiers[0] if empty_tiers else None)
    wrist = data.get("settings", {}).get("wrist", {})
    size_guidance = (
        f"{number(wrist.get('sweetSpotMin'))}–{number(wrist.get('sweetSpotMax'))}mm, "
        f"lug-to-lug ≤{number(wrist.get('lugMax'))}mm"
    )
    all_time_category_counts = Counter(
        watch.get("category") for watch in data.get("watches", []) if watch.get("category")
    )

    results = []
    used_materials: set[str] = set()
    for category_index, category in enumerate(categories):
        current_count = category_counts[category]
        if category in excluded or current_count >= 2:
            continue

        plausible_dials = DIAL_PLAUSIBILITY.get(category, tuple(dial_colors))
        picked_dials = [
            dial for dial in plausible_dials
            if dial in dial_colors and dial not in owned_dials
        ][:2]
        plausible_materials = MATERIAL_PLAUSIBILITY.get(
            category,
            tuple(dict.fromkeys(("Titanium", "Bronze", "Ceramic", "Stainless Steel", *materials))),
        )
        # Prefer a material no earlier suggestion already used, so the set reads
        # "titanium pilot, bronze field, ceramic GMT" rather than titanium five times.
        fresh = [name for name in plausible_materials if name in materials and name not in owned_materials]
        material = next((name for name in fresh if name not in used_materials), fresh[0] if fresh else None)
        if material:
            used_materials.add(material)
        tier_label = price_gap[0] if price_gap else None

        category_score = 3 if current_count == 0 else 2
        dial_score = 2 if picked_dials else 0
        material_score = 2 if material else 0
        price_score = 2 if tier_label else 0
        reasons: list[str] = []
        all_time_count = all_time_category_counts[category]
        category_noun = category if category.isupper() else category.casefold()
        if current_count == 0 and all_time_count == 0:
            reasons.append(f"You've never owned a {category_noun} watch")
        elif current_count == 0:
            reasons.append(f"No {category_noun} watch is currently owned; {all_time_count} explored before")
        else:
            reasons.append(f"Only {current_count} {category_noun} watch is currently owned")
        reasons.extend(f"{dial} dial — not represented among current watches" for dial in picked_dials)
        if material:
            reasons.append(f"{material} would be a first material in the current collection")
        if tier_label:
            reasons.append(f"{tier_label} originals-only tier is empty")
        brands = recommended_brands(category, data)
        if reason := radar_reason(brands):
            reasons.append(reason)

        dial_phrase = " or ".join(dial.casefold() for dial in picked_dials)
        headline_parts = [part for part in (
            f"{material} {category_noun}" if material else category_noun,
            f"{dial_phrase} dial" if dial_phrase else None,
            size_guidance,
        ) if part]
        matches = [
            item.get("id") for item in data.get("wishlist", [])
            if item.get("status") == "considering" and item.get("category") == category and item.get("id")
        ]
        results.append((
            -(category_score + dial_score + material_score + price_score),
            category_index,
            {
                "headline": ", ".join(headline_parts),
                "category": category,
                "dialColors": picked_dials,
                "material": material,
                "sizeGuidance": size_guidance,
                "priceTier": tier_label,
                "score": category_score + dial_score + material_score + price_score,
                "reasons": reasons,
                "wishlistMatches": matches,
                "brands": brands,
            },
        ))

    results.sort(key=lambda row: (row[0], row[1]))
    return {"saturated": saturated, "suggestions": [row[2] for row in results[:5]]}


def totals_by_field(watches: list[dict], field: str) -> dict[str, tuple[int, float]]:
    totals: defaultdict[str, list[float]] = defaultdict(lambda: [0, 0.0])
    for watch in watches:
        label = str(watch.get(field) or "Unset")
        totals[label][0] += 1
        if isinstance(watch.get("price"), (int, float)):
            totals[label][1] += float(watch["price"])
    return {label: (int(values[0]), values[1]) for label, values in totals.items()}


def atomic_copy(source: Path, destination: Path) -> None:
    temporary = destination.with_name(f".{destination.name}.{uuid.uuid4().hex}.tmp")
    try:
        with source.open("rb") as source_handle, temporary.open("xb") as destination_handle:
            shutil.copyfileobj(source_handle, destination_handle)
            destination_handle.flush()
            os.fsync(destination_handle.fileno())
        os.replace(temporary, destination)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def section(writer: csv.writer, title: str, header: list[str] | None = None) -> None:
    writer.writerow([])
    writer.writerow([title])
    if header:
        writer.writerow(header)


def write_scope_sections(writer: csv.writer, scopes: dict[str, list[dict]], wrist: dict) -> None:
    stats = {label: headline_stats(watches) for label, watches in scopes.items()}
    section(writer, "HEADLINE STATISTICS", ["Metric", *scopes.keys()])
    labels = {
        "count": "Count", "total": "Total spent (CAD)", "mean": "Mean price (CAD)",
        "median": "Median price (CAD)", "iqr": "Interquartile range (CAD)", "min": "Minimum price (CAD)",
        "max": "Maximum price (CAD)", "stdDev": "Standard deviation (sample)",
        "skewness": "Skewness (sample)",
    }
    for key, label in labels.items():
        row = [label]
        for scope in scopes:
            raw = stats[scope][key]
            row.append(str(int(raw)) if key == "count" else number(raw) if key == "skewness" else money(raw))
        writer.writerow(row)
    owned = scopes["Current collection"]
    diameters = [watch["diameter"] for watch in owned if isinstance(watch.get("diameter"), (int, float))]
    sweet = [value for value in diameters if wrist["sweetSpotMin"] <= value <= wrist["sweetSpotMax"]]
    writer.writerow(["Owned watches in sweet spot (%)", money(100 * len(sweet) / len(diameters) if diameters else 0), ""])

    section(writer, "PRICE PERCENTILES (LINEAR INTERPOLATION)", ["Percentile", *scopes.keys()])
    for percent in PERCENTILES:
        row = [f"P{percent}"]
        for watches in scopes.values():
            row.append(money(percentile([float(watch["price"]) for watch in watches], percent)))
        writer.writerow(row)

    section(writer, "COST HISTOGRAM (PRICE TIERS)", ["Scope", "Tier", "Count"])
    for scope, watches in scopes.items():
        for tier, count in cost_histogram(watches).items():
            writer.writerow([scope, tier, count])

    section(writer, "SIZE HISTOGRAM (2 MM BUCKETS)", ["Scope", "Diameter range (mm)", "Count", "Wrist guidance"])
    for scope, watches in scopes.items():
        for lower, count in histogram(watches, "diameter").items():
            guidance = f"sweet spot {number(wrist['sweetSpotMin'])}–{number(wrist['sweetSpotMax'])}; perfect {number(wrist['perfect'])}"
            writer.writerow([scope, f"{lower}–{lower + 1.9:.1f}", count, guidance])
    section(writer, "LUG-TO-LUG HISTOGRAM (2 MM BUCKETS)", ["Scope", "L2L range (mm)", "Count", "lugMax marker"])
    for scope, watches in scopes.items():
        for lower, count in histogram(watches, "lugToLug").items():
            writer.writerow([scope, f"{lower}–{lower + 1.9:.1f}", count, number(wrist["lugMax"])])

    section(writer, "SPEND BY PURCHASE YEAR", ["Year", *scopes.keys()])
    yearly = {scope: spend_by_year(watches) for scope, watches in scopes.items()}
    for year in sorted({year for totals in yearly.values() for year in totals}):
        writer.writerow([year, *(money(yearly[scope].get(year, 0)) for scope in scopes)])


def write_breakdowns(writer: csv.writer, data: dict, all_watches: list[dict], current: list[dict]) -> None:
    section(writer, "BRANDS + BRAND BREADTH", ["Brand", "All-time count", "All-time spend", "Current count", "Current spend", "Originals current", "Originals all-time", "First purchased"])
    all_totals: defaultdict[str, list[float]] = defaultdict(lambda: [0, 0.0])
    current_totals: defaultdict[str, list[float]] = defaultdict(lambda: [0, 0.0])
    for watch in all_watches:
        brand = watch_brand(watch); all_totals[brand][0] += 1; all_totals[brand][1] += float(watch["price"])
    for watch in current:
        brand = watch_brand(watch); current_totals[brand][0] += 1; current_totals[brand][1] += float(watch["price"])
    all_original_counts = brand_counts(all_watches)
    current_original_counts = brand_counts(current)
    for brand in sorted(set(all_totals) | set(current_totals)):
        dates = [watch.get("purchased") for watch in originals_only(all_watches) if watch_brand(watch) == brand and watch.get("purchased")]
        writer.writerow([brand, int(all_totals[brand][0]), money(all_totals[brand][1]), int(current_totals[brand][0]), money(current_totals[brand][1]), current_original_counts[brand], all_original_counts[brand], min(dates) if dates else ""])
    writer.writerow(["Unique original brands owned / owned watches", len(current_original_counts), len(current)])
    writer.writerow(["Unique original brands ever explored", len(all_original_counts)])
    writer.writerow(["Rep brands worn", "; ".join(sorted({watch_brand(watch) for watch in all_watches if watch.get("original") is False}))])
    for radar in data.get("brandWatchlist", []):
        brand = radar.get("brand", "")
        status = "owned" if current_original_counts[brand] else "explored before" if all_original_counts[brand] else "new brand"
        writer.writerow([f"RADAR: {brand}", "", "", "", "", "", "", radar.get("added", ""), status, radar.get("notes", "")])

    first_years: Counter = Counter()
    for brand in all_original_counts:
        dates = sorted(watch.get("purchased") for watch in originals_only(all_watches) if watch_brand(watch) == brand and watch.get("purchased"))
        if dates:
            first_years[dates[0][:4]] += 1
    writer.writerow([]); writer.writerow(["NEW ORIGINAL BRANDS FIRST EXPLORED BY YEAR"])
    for year, count in sorted(first_years.items()):
        writer.writerow([year, count])

    section(writer, "CATEGORIES", ["Category", "Current count", "Current spend", "All-time count", "All-time spend", "Coverage verdict"])
    all_values, current_values = totals_by_field(all_watches, "category"), totals_by_field(current, "category")
    for category in data.get("categories", []):
        owned_count, owned_spend = current_values.get(category, (0, 0))
        all_count, all_spend = all_values.get(category, (0, 0))
        verdict = "GAP" if owned_count == 0 else "thin" if owned_count == 1 else "covered" if owned_count == 2 else "well covered"
        writer.writerow([category, owned_count, money(owned_spend), all_count, money(all_spend), verdict])

    section(writer, "PRICE TIERS — BOTH SCOPES + ORIGINALS-ONLY", ["Filter", "Tier", "Current count", "Current total", "All-time count", "All-time total"])
    for filter_name, current_scope, all_scope in (("All watches", current, all_watches), ("Originals-only (reps + Smartwatch excluded)", originals_only(current), originals_only(all_watches))):
        for tier, _lower, _upper in PRICE_TIERS:
            current_matches = [watch for watch in current_scope if price_tier(watch.get("price")) == tier]
            all_matches = [watch for watch in all_scope if price_tier(watch.get("price")) == tier]
            writer.writerow([filter_name, tier, len(current_matches), money(sum(float(w["price"]) for w in current_matches)), len(all_matches), money(sum(float(w["price"]) for w in all_matches))])

    for field, title, canonical in (("dialColor", "DIAL COLOURS", data.get("dialColors", [])), ("material", "MATERIALS", data.get("materials", []))):
        section(writer, title, [title[:-1] if title.endswith("S") else title, "Current count", "All-time count", "Status"])
        current_counts = Counter(watch.get(field) for watch in current)
        all_counts = Counter(watch.get(field) for watch in all_watches)
        for value in canonical:
            status = "not represented" if current_counts[value] == 0 else "saturated" if current_counts[value] >= 2 else "represented"
            writer.writerow([value, current_counts[value], all_counts[value], status])
        writer.writerow(["Unset", current_counts[None], all_counts[None], "complete your data"])

    for field, title in (("status", "STATUS BREAKDOWN"), ("original", "DESIGN TYPE BREAKDOWN")):
        section(writer, title, [field.title(), "Count", "Spend"])
        values = totals_by_field(all_watches, field)
        for label, (count, spend) in sorted(values.items()):
            writer.writerow([label, count, money(spend)])


def write_wishlist(writer: csv.writer, data: dict) -> None:
    section(writer, "WISHLIST — SIX-LENS PURCHASE DECISION ENGINE (MAX 14)", [
        "id", "name", "brand", "category", "priceExpected", "priceNote", "notes", "status", "added",
        "dialColor", "diameter", "lugToLug", "material", "fit", "photos", "score", "maxScore",
        "categoryScore", "categoryReason", "brandScore", "brandReason", "priceScore", "priceReason",
        "dialScore", "dialReason", "sizeScore", "sizeReason", "materialScore", "materialReason",
    ])
    wrist = data.get("settings", {}).get("wrist", {})
    for item in data.get("wishlist", []):
        scored = score_wishlist(item, data); lenses = scored["lenses"]
        row = [
            item.get("id", ""), item.get("name", ""), item.get("brand", ""), item.get("category") or "",
            "" if item.get("priceExpected") is None else money(float(item["priceExpected"])), item.get("priceNote", ""),
            item.get("notes", ""), item.get("status", ""), item.get("added", ""), item.get("dialColor") or "",
            number(item.get("diameter")), number(item.get("lugToLug")), item.get("material") or "",
            f"{fit_info(item, wrist)['label']} ({fit_info(item, wrist)['basis']} basis)" if fit_info(item, wrist)["label"] else "",
            "; ".join(item.get("photos", [])), scored["total"], scored["max"],
        ]
        for name in ("category", "brand", "price", "dial", "size", "material"):
            row.extend([lenses[name]["score"], lenses[name]["reason"]])
        writer.writerow(row)


def write_suggestions(writer: csv.writer, data: dict) -> None:
    section(writer, "NEXT MOVE SUGGESTIONS (MAX 9)", [
        "headline", "category", "dialColors", "material", "sizeGuidance",
        "priceTier", "score", "brands", "reasons", "matches",
    ])
    payload = next_move_suggestions(data)
    for suggestion in payload["suggestions"]:
        match_names = {
            item.get("id"): item.get("name", item.get("id", ""))
            for item in data.get("wishlist", [])
        }
        writer.writerow([
            suggestion["headline"], suggestion["category"],
            "; ".join(suggestion["dialColors"]), suggestion["material"] or "",
            suggestion["sizeGuidance"], suggestion["priceTier"] or "", suggestion["score"],
            "; ".join(f"{brand['name']} [{brand['status']}]" for brand in suggestion["brands"]),
            "; ".join(suggestion["reasons"]),
            "; ".join(match_names.get(item_id, item_id) for item_id in suggestion["wishlistMatches"]),
        ])


def export_collection(force: bool = False, allow_remote: bool = True) -> tuple[Path, Path, bool, str]:
    with DATA_FILE.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    watches = data["watches"]
    current = [watch for watch in watches if watch.get("status") == "owned"]
    wrist = data.get("settings", {}).get("wrist", {})
    scopes = {"Current collection": current, "All-time": watches}

    EXPORTS_DIR.mkdir(parents=True, exist_ok=True)
    csv_path = EXPORTS_DIR / f"watch-collection-{date.today().isoformat()}.csv"
    temporary = csv_path.with_name(f".{csv_path.name}.{uuid.uuid4().hex}.tmp")
    try:
        with temporary.open("x", encoding="utf-8", newline="") as handle:
            writer = csv.writer(handle)
            writer.writerow(["WATCH COLLECTION EXPORT", date.today().isoformat()])
            writer.writerow(["WRIST PROFILE", f"{number(wrist.get('inches'))} inches", f"sweet spot {number(wrist.get('sweetSpotMin'))}–{number(wrist.get('sweetSpotMax'))}mm", f"perfect {number(wrist.get('perfect'))}mm", f"lugMax {number(wrist.get('lugMax'))}mm"])
            writer.writerow([])
            writer.writerow(["WATCHES"])
            writer.writerow(["id", "name", "brand", "story", "purchased", "purchasedText", "category", "dialColor", "material", "diameter", "lugToLug", "fit", "price", "original", "status", "statusNote", "photos", "photoCount"])
            for watch in watches:
                fit = fit_info(watch, wrist)
                writer.writerow([
                    watch.get("id", ""), watch.get("name", ""), watch_brand(watch), watch.get("story", ""),
                    watch.get("purchased") or "", watch.get("purchasedText", ""), watch.get("category") or "",
                    watch.get("dialColor") or "", watch.get("material") or "", number(watch.get("diameter")),
                    number(watch.get("lugToLug")), f"{fit['label']} ({fit['basis']} basis)" if fit["label"] else "",
                    money(float(watch.get("price", 0))), "" if watch.get("original") is None else str(watch["original"]).lower(),
                    watch.get("status", ""), watch.get("statusNote", ""), "; ".join(watch.get("photos", [])), len(watch.get("photos", [])),
                ])
            writer.writerow([]); writer.writerow(["STATS"])
            write_scope_sections(writer, scopes, wrist)
            write_breakdowns(writer, data, watches, current)
            write_suggestions(writer, data)
            write_wishlist(writer, data)
            handle.flush(); os.fsync(handle.fileno())
        os.replace(temporary, csv_path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass

    json_path = EXPORTS_DIR / "watches.json"
    atomic_copy(DATA_FILE, json_path)
    should_backup = allow_remote and (force or bool(data.get("settings", {}).get("autoBackup")))
    output = "Remote backup skipped (autoBackup is off)." if allow_remote else "Remote backup skipped (allow_remote=False)."
    if should_backup:
        remote = str(data.get("settings", {}).get("backupRemote") or DEFAULT_REMOTE).rstrip("/") + "/"
        if not RCLONE.is_file():
            raise RuntimeError(f"rclone not found at {RCLONE}")
        messages = []
        for exported_file in (csv_path, json_path):
            process = subprocess.run([str(RCLONE), "copy", str(exported_file), remote], capture_output=True, text=True, check=False)
            details = "\n".join(part.strip() for part in (process.stdout, process.stderr) if part.strip())
            if process.returncode != 0:
                raise RuntimeError(f"rclone failed for {exported_file.name} with exit code {process.returncode}" + (f": {details}" if details else ""))
            messages.append(f"Copied {exported_file.name} to {remote}" + (f" ({details})" if details else ""))
        output = "\n".join(messages)
    return csv_path, json_path, should_backup, output


def main() -> int:
    parser = argparse.ArgumentParser(description="Export the local watch collection to CSV")
    parser.add_argument("--force", action="store_true", help="copy exports with rclone even when autoBackup is off")
    args = parser.parse_args()
    try:
        csv_path, json_path, _backed_up, output = export_collection(force=args.force)
        with DATA_FILE.open("r", encoding="utf-8") as handle:
            row_count = len(json.load(handle)["watches"])
        print(f"CSV: {csv_path}")
        print(f"JSON: {json_path}")
        print(f"Rows: {row_count}")
        print(output)
        return 0
    except (OSError, ValueError, json.JSONDecodeError, RuntimeError) as exc:
        print(f"Export failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
