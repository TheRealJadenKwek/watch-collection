"use strict";

window.__consoleErrors = [];
window.addEventListener("error", event => window.__consoleErrors.push(event.message || "Unknown script error"));
window.addEventListener("unhandledrejection", event => window.__consoleErrors.push(String(event.reason || "Unhandled promise rejection")));

// One obvious tuning point. Six lenses can contribute at most 14 points.
const WISHLIST_WEIGHTS = Object.freeze({
  category: Object.freeze({ gap: 3, thin: 2, covered: 1, saturated: 0 }),
  brand: Object.freeze({ new: 2, past: 1, current: 0, repeated: -1 }),
  price: Object.freeze({ originalsGap: 2, allOwnedGap: 1, represented: 0 }),
  dial: Object.freeze({ absent: 2, one: 1, repeated: 0 }),
  size: Object.freeze({ ideal: 3, good: 2, edge: 1, miss: 0 }),
  material: Object.freeze({ absent: 2, one: 1, repeated: 0 }),
  max: 14,
});

const PRICE_TIERS = [
  { label: "<$50", min: 0, max: 50 }, { label: "$50–100", min: 50, max: 100 },
  { label: "$100–200", min: 100, max: 200 }, { label: "$200–300", min: 200, max: 300 },
  { label: "$300–500", min: 300, max: 500 }, { label: "$500–750", min: 500, max: 750 },
  { label: "$750–1000", min: 750, max: 1000 }, { label: "$1000–2500", min: 1000, max: 2500 },
  { label: "$2500+", min: 2500, max: Infinity },
];

const STATUS_LABELS = {
  owned: "Owned", given_away: "Given away", sold: "Sold", broken: "Broken",
  donated: "Donated", ousted: "Ousted", want_to_buy_back: "Want to buy back",
  giving_away: "Giving away",
};

const DIAL_SWATCHES = {
  Black: "#151515", White: "#e9e7df", Silver: "#aaa9a3", Blue: "#376c98",
  Green: "#48735c", Grey: "#777a7c", "Gold/Champagne": "#c4a35f", Cream: "#e4d8b7",
  Orange: "#d9803f", Red: "#9a413d", Brown: "#76503c", Skeleton: "#827a70",
  "Multi/Novelty": "linear-gradient(135deg,#c26969,#d5b763,#4b8692)", Screen: "#64788d", Other: "#71667d",
};

const state = {
  data: null,
  suggestions: null,
  tab: "collection",
  statsScope: "owned",
  originalsOnly: false,
  taxonomy: null,
  modal: null,
  pendingUploads: [],
  toastTimer: null,
};

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const esc = (value) => String(value ?? "").replace(/[&<>'"]/g, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" }[char]));
const money = value => value == null || value === "" ? "Price TBD" : new Intl.NumberFormat("en-CA", { style: "currency", currency: "CAD", maximumFractionDigits: 2 }).format(value);
const num = value => String(Math.round(Number(value) * 10) / 10);
const sum = values => values.reduce((total, value) => total + value, 0);

async function api(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    headers: options.body instanceof FormData ? options.headers : { "Content-Type": "application/json", ...(options.headers || {}) },
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload.error || payload.output || `${response.status} ${response.statusText}`);
  return payload;
}

async function refresh() {
  [state.data, state.suggestions] = await Promise.all([api("/api/data"), api("/api/suggestions")]);
  renderAll();
}

function toast(message, error = false) {
  const node = $("#toast");
  node.textContent = message;
  node.style.borderColor = error ? "rgba(201,121,114,.55)" : "";
  node.classList.add("show");
  clearTimeout(state.toastTimer);
  state.toastTimer = setTimeout(() => node.classList.remove("show"), 3200);
}

function brandForName(name) {
  const specials = [
    ["Audemars Piguet", "Audemars Piguet"], ["Miss Fox", "Miss Fox"],
    ["U.S. Polo Assn.", "U.S. Polo Assn."], ["Omega Moonswatch", "Omega"],
    ["Moonswatch", "Omega"], ["Casio G-Shock", "Casio"], ["Casio G-Steel", "Casio"],
    ["Christopher Ward", "Christopher Ward"], ["D1 Milano", "D1 Milano"],
    ["Henry Archer", "Henry Archer"], ["Furlan Marri", "Furlan Marri"],
    ["Dan Henry", "Dan Henry"],
    ["Rolex", "Rolex"],
  ];
  const match = specials.find(([prefix]) => String(name).toLowerCase().startsWith(prefix.toLowerCase()));
  return match ? match[1] : String(name || "Unknown").trim().split(/\s+/)[0] || "Unknown";
}

function watchBrand(watch) { return watch.brand || brandForName(watch.name); }
// Price-ladder "originals only": no reps, no smartwatches ("real watches")
function isOriginalBreadthWatch(watch) { return watch.original !== false && watch.category !== "Smartwatch"; }
// Brand breadth: no reps (a Rolex rep is not a Rolex), no unbranded generics; smartwatch brands DO count as repeats
function isBrandBreadthWatch(watch) { return watch.original !== false && watchBrand(watch) !== "Generic"; }
function priceTier(value) { return value == null ? null : PRICE_TIERS.find(tier => Number(value) >= tier.min && Number(value) < tier.max) || null; }

function fitInfo(item) {
  const wrist = state.data.settings.wrist;
  if (item.lugToLug != null) {
    const lug = Number(item.lugToLug);
    if (lug <= wrist.lugMax - 1) return { key: "great", label: `great fit · ${num(lug)} L2L`, basis: "L2L", score: WISHLIST_WEIGHTS.size.ideal };
    if (lug <= wrist.lugMax) return { key: "limit", label: `at the limit · ${num(lug)} L2L`, basis: "L2L", score: WISHLIST_WEIGHTS.size.good };
    return { key: "over", label: `+${num(lug - wrist.lugMax)}mm L2L over`, basis: "L2L", score: 0 };
  }
  if (item.diameter == null) return { key: "unknown", label: "", basis: "none", score: 0 };
  const diameter = Number(item.diameter);
  if (Math.abs(diameter - wrist.perfect) <= 1) return { key: "perfect", label: `perfect · ${num(diameter)}mm`, basis: "diameter", score: WISHLIST_WEIGHTS.size.ideal };
  if (diameter >= wrist.sweetSpotMin && diameter <= wrist.sweetSpotMax) return { key: "sweet", label: `sweet spot · ${num(diameter)}mm`, basis: "diameter", score: WISHLIST_WEIGHTS.size.good };
  if (diameter < wrist.sweetSpotMin) {
    const delta = wrist.sweetSpotMin - diameter;
    return { key: "under", label: `−${num(delta)}mm under`, basis: "diameter", score: delta <= 1 ? WISHLIST_WEIGHTS.size.edge : 0 };
  }
  const delta = diameter - wrist.sweetSpotMax;
  return { key: "over", label: `+${num(delta)}mm over`, basis: "diameter", score: delta <= 1 ? WISHLIST_WEIGHTS.size.edge : 0 };
}

function fitChip(item) {
  const fit = fitInfo(item);
  return fit.label ? `<span class="chip fit-${fit.key}" title="Fit based on ${fit.basis}">${esc(fit.label)}</span>` : "";
}

function dialChip(item) {
  if (!item.dialColor) return `<span class="chip unset">dial unset</span>`;
  return `<span class="chip"><span class="dot" style="--dot:${esc(DIAL_SWATCHES[item.dialColor] || "#777")}"></span>${esc(item.dialColor)}</span>`;
}

function placeholder() {
  return `<div class="placeholder"><svg viewBox="0 0 100 150" aria-label="No photo"><path d="M38 3h24l5 35c10 6 17 18 17 37s-7 31-17 37l-5 35H38l-5-35c-10-6-17-18-17-37s7-31 17-37z"></path><circle cx="50" cy="75" r="31"></circle><path d="M50 51v25l16 9M42 12h16M42 138h16"></path></svg></div>`;
}

function photoDirectory(kind, id) { return kind === "watch" ? id : `wl-${id}`; }
function imageMarkup(item, kind, className = "card-image") {
  const cover = item.photos?.[0];
  return `<div class="${className}">${cover ? `<img src="/photos/${encodeURIComponent(photoDirectory(kind, item.id))}/${encodeURIComponent(cover)}" alt="${esc(item.name)}">` : placeholder()}</div>`;
}

function cardMarkup(watch, past = false) {
  const note = past && watch.statusNote ? `${STATUS_LABELS[watch.status] || watch.status} ${watch.statusNote}` : watch.story || "No story added yet";
  return `<article class="watch-card">
    ${past ? `<span class="status-badge">${esc(STATUS_LABELS[watch.status] || watch.status)}</span>` : ""}
    <button class="card-hit" type="button" data-open-watch="${esc(watch.id)}">
      ${imageMarkup(watch, "watch")}
      <div class="card-body">
        <div class="card-title-row"><h3 class="card-title">${esc(watch.name)}</h3><span class="price">${money(watch.price)}</span></div>
        <p class="story">${esc(note)}</p>
        <div class="meta-line">
          <span class="chip">${esc(watch.category || "Uncategorised")}</span>
          ${watch.original === false ? `<span class="chip gold">Rep / homage</span>` : ""}
          ${watch.diameter != null ? `<span class="chip">${num(watch.diameter)}mm</span>` : ""}
          ${fitChip(watch)}
          ${watch.material ? `<span class="chip">${esc(watch.material)}</span>` : ""}
          ${watch.dialColor ? dialChip(watch) : ""}
        </div>
      </div>
    </button>
  </article>`;
}

function filteredWatches(owned) {
  const query = $("#searchInput").value.trim().toLowerCase();
  const category = $("#categoryFilter").value;
  const status = $("#statusFilter").value;
  return state.data.watches.filter(watch => {
    const scopeMatch = owned ? watch.status === "owned" : watch.status !== "owned";
    const queryMatch = !query || `${watch.name} ${watch.story} ${watch.statusNote}`.toLowerCase().includes(query);
    const categoryMatch = !category || watch.category === category;
    const statusMatch = owned || !status || watch.status === status;
    return scopeMatch && queryMatch && categoryMatch && statusMatch;
  }).sort((a, b) => owned ? b.price - a.price : String(b.purchased || "").localeCompare(String(a.purchased || "")));
}

function renderGrids() {
  const owned = filteredWatches(true);
  const past = filteredWatches(false);
  $("#collectionGrid").innerHTML = owned.length ? owned.map(watch => cardMarkup(watch)).join("") : `<div class="empty-state">No watches match this view.</div>`;
  $("#pastGrid").innerHTML = past.length ? past.map(watch => cardMarkup(watch, true)).join("") : `<div class="empty-state">No past watches match this view.</div>`;
  $("#collectionSummary").textContent = `${owned.length} shown · ${money(sum(owned.map(watch => watch.price)))}`;
}

function percentile(values, percent) {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const position = (sorted.length - 1) * percent / 100;
  const lower = Math.floor(position), upper = Math.ceil(position);
  return lower === upper ? sorted[lower] : sorted[lower] + (sorted[upper] - sorted[lower]) * (position - lower);
}

function counter(items, getter) {
  const counts = new Map();
  items.forEach(item => { const key = getter(item); counts.set(key, (counts.get(key) || 0) + 1); });
  return counts;
}

function barRows(entries, formatter = value => value) {
  const max = Math.max(1, ...entries.map(([, value]) => Number(value)));
  return `<div class="bar-list">${entries.map(([label, value, suffix = ""]) => `<div class="bar-row"><span>${esc(label)}</span><span class="bar-track"><span class="bar-fill" style="width:${Number(value) === 0 ? 0 : Math.max(1.5, Number(value) / max * 100)}%"></span></span><strong>${esc(formatter(value))}${esc(suffix)}</strong></div>`).join("")}</div>`;
}

function monotoneCubicPath(points) {
  if (!points.length) return "";
  if (points.length === 1) return `M ${points[0].x} ${points[0].y}`;
  const slopes = points.slice(1).map((point, index) => (point.y - points[index].y) / (point.x - points[index].x));
  const tangents = points.map((point, index) => {
    if (index === 0) return slopes[0];
    if (index === points.length - 1) return slopes[slopes.length - 1];
    const before = slopes[index - 1], after = slopes[index];
    return before * after <= 0 ? 0 : 2 * before * after / (before + after);
  });
  slopes.forEach((slope, index) => {
    if (slope === 0) {
      tangents[index] = 0;
      tangents[index + 1] = 0;
      return;
    }
    const before = tangents[index] / slope, after = tangents[index + 1] / slope;
    const magnitude = Math.hypot(before, after);
    if (magnitude > 3) {
      const scale = 3 / magnitude;
      tangents[index] = scale * before * slope;
      tangents[index + 1] = scale * after * slope;
    }
  });
  return points.slice(1).reduce((path, point, index) => {
    const previous = points[index], width = point.x - previous.x;
    return `${path} C ${previous.x + width / 3} ${previous.y + tangents[index] * width / 3}, ${point.x - width / 3} ${point.y - tangents[index + 1] * width / 3}, ${point.x} ${point.y}`;
  }, `M ${points[0].x} ${points[0].y}`);
}

function costReferenceX(value, headline, left, bucketWidth) {
  const tierIndex = Math.max(0, PRICE_TIERS.findIndex(tier => Number(value) >= tier.min && Number(value) < tier.max));
  const tier = PRICE_TIERS[tierIndex];
  const upper = Number.isFinite(tier.max) ? tier.max : Math.max(Number(headline.max) || tier.min + 1, tier.min + 1);
  const proportion = Math.min(.96, Math.max(.04, (Number(value) - tier.min) / (upper - tier.min)));
  return left + (tierIndex + proportion) * bucketWidth;
}

function skewShape(skew) {
  if (Number(skew) > .3) return "right-skewed";
  if (Number(skew) < -.3) return "left-skewed";
  return "roughly symmetric";
}

function costHistogramChart(entries, headline) {
  const width = 900, height = 286, left = 42, right = 12, top = 45, bottom = 222;
  const bucketWidth = (width - left - right) / entries.length;
  const maxCount = Math.max(1, ...entries.map(([, count]) => Number(count)));
  const chartHeight = bottom - top;
  const points = entries.map(([, count], index) => ({
    x: left + (index + .5) * bucketWidth,
    y: bottom - Number(count) / maxCount * chartHeight,
  }));
  const median = Number(headline.median ?? 0), mean = Number(headline.mean ?? 0), skew = Number(headline.skewness ?? 0);
  const medianX = costReferenceX(median, headline, left, bucketWidth);
  const meanX = costReferenceX(mean, headline, left, bucketWidth);
  const bars = entries.map(([label, count], index) => {
    const barWidth = bucketWidth * .68, x = left + index * bucketWidth + bucketWidth * .16;
    const y = bottom - Number(count) / maxCount * chartHeight;
    return `<g><rect class="cost-hist-bar" x="${x}" y="${y}" width="${barWidth}" height="${bottom - y}" rx="4"></rect><text class="cost-hist-count" x="${x + barWidth / 2}" y="${Math.max(top + 11, y - 7)}" text-anchor="middle">${Number(count)}</text><text class="cost-hist-label" x="${x + barWidth / 2}" y="247" text-anchor="middle">${esc(label)}</text></g>`;
  }).join("");
  const medianAnchor = medianX > width - 80 ? "end" : "start";
  const meanAnchor = meanX > width - 80 ? "end" : "start";
  return `<div class="cost-histogram">
    <div class="cost-chart-legend"><span></span>shape</div>
    <svg viewBox="0 0 ${width} ${height}" role="img" aria-label="Cost histogram with shape curve, median ${esc(money(median))}, and mean ${esc(money(mean))}">
      <line class="cost-hist-axis" x1="${left}" y1="${bottom}" x2="${width - right}" y2="${bottom}"></line>
      ${bars}
      <path class="cost-shape-curve" d="${monotoneCubicPath(points)}"></path>
      <line class="cost-reference median" x1="${medianX}" y1="${top}" x2="${medianX}" y2="${bottom}"></line>
      <text class="cost-reference-label median" x="${medianX + (medianAnchor === "end" ? -4 : 4)}" y="16" text-anchor="${medianAnchor}">median ${esc(money(median))}</text>
      <line class="cost-reference mean" x1="${meanX}" y1="${top}" x2="${meanX}" y2="${bottom}"></line>
      <text class="cost-reference-label mean" x="${meanX + (meanAnchor === "end" ? -4 : 4)}" y="34" text-anchor="${meanAnchor}">mean ${esc(money(mean))}</text>
    </svg>
    <p class="skew-sentence">Mean ${esc(money(mean))} vs median ${esc(money(median))} — ${skewShape(skew)} (skew ${skew.toFixed(3)})</p>
  </div>`;
}

function histogram(items, field) {
  const counts = new Map();
  items.forEach(item => {
    if (item[field] == null) return;
    const lower = Math.floor(Number(item[field]) / 2) * 2;
    counts.set(lower, (counts.get(lower) || 0) + 1);
  });
  return [...counts].sort((a, b) => a[0] - b[0]);
}

function categoryCoverage() {
  const owned = state.data.watches.filter(watch => watch.status === "owned");
  const ownedCounts = counter(owned, watch => watch.category);
  const allCounts = counter(state.data.watches, watch => watch.category);
  const rank = count => count === 0 ? 0 : count === 1 ? 1 : count === 2 ? 2 : 3;
  return [...state.data.categories].sort((a, b) => rank(ownedCounts.get(a) || 0) - rank(ownedCounts.get(b) || 0) || state.data.categories.indexOf(a) - state.data.categories.indexOf(b)).map(category => {
    const ownedCount = ownedCounts.get(category) || 0;
    const allCount = allCounts.get(category) || 0;
    const verdict = ownedCount === 0 ? "GAP" : ownedCount === 1 ? "thin" : ownedCount === 2 ? "covered" : "well covered";
    const detail = ownedCount === 0 ? "never owned one" : ownedCount >= 3 ? "probably don’t need another" : `${ownedCount} currently owned`;
    return `<div class="coverage-item"><strong>${esc(category)} <span class="chip ${ownedCount === 0 ? "gap" : ownedCount >= 3 ? "saturated" : ""}">${verdict}</span></strong><small>${detail} · ${allCount} all-time</small></div>`;
  }).join("");
}

function biggestGaps(watches) {
  const sorted = [...watches].sort((a, b) => a.price - b.price);
  return sorted.slice(1).map((watch, index) => ({ low: sorted[index], high: watch, gap: watch.price - sorted[index].price })).sort((a, b) => b.gap - a.gap).slice(0, 2);
}

function varietyPanel(title, field, canonical, manageRoute) {
  const owned = state.data.watches.filter(watch => watch.status === "owned");
  const counts = counter(owned.filter(watch => watch[field]), watch => watch[field]);
  return `<section class="panel"><div class="panel-heading"><div><p class="eyebrow">Variety</p><h3>${esc(title)}</h3></div><button class="text-button" data-manage="${manageRoute}" type="button">Manage</button></div>
    <div class="coverage-grid">${canonical.map(value => {
      const count = counts.get(value) || 0;
      const dot = field === "dialColor" ? `<span class="dot" style="--dot:${esc(DIAL_SWATCHES[value] || "#777")}"></span>` : "";
      return `<div class="coverage-item"><strong>${dot}${esc(value)}</strong><small>${count ? `${count} owned` : "not represented"} ${count >= 2 ? `<span class="chip saturated">saturated</span>` : ""}</small></div>`;
    }).join("")}</div>
  </section>`;
}

function renderStats() {
  const all = state.data.watches;
  const owned = all.filter(watch => watch.status === "owned");
  const scope = state.statsScope === "owned" ? owned : all;
  const hl = state.data.headlineStats?.[state.statsScope] ?? {};
  const iqrRange = `${money(hl.q1 ?? 0)} – ${money(hl.q3 ?? 0)}`;
  const wrist = state.data.settings.wrist;
  const measuredOwned = owned.filter(watch => watch.diameter != null);
  const sweetCount = measuredOwned.filter(watch => watch.diameter >= wrist.sweetSpotMin && watch.diameter <= wrist.sweetSpotMax).length;
  const sweetPercent = measuredOwned.length ? sweetCount / measuredOwned.length * 100 : 0;
  const pcts = [10, 25, 50, 75, 80, 90, 95];
  const diamHist = histogram(scope, "diameter");
  const lugHist = histogram(scope, "lugToLug");
  const costHist = PRICE_TIERS.map(tier => [tier.label, scope.filter(watch => priceTier(watch.price)?.label === tier.label).length]);
  const yearly = [...counter(scope.filter(w => w.purchased), watch => watch.purchased.slice(0, 4))];
  const yearSpend = [...new Set(scope.filter(w => w.purchased).map(w => w.purchased.slice(0, 4)))].sort().map(year => [year, sum(scope.filter(w => w.purchased?.startsWith(year)).map(w => w.price))]);
  const brandCounts = [...counter(scope, watchBrand)].sort((a, b) => b[1] - a[1]);
  const statusCounts = [...counter(all, watch => STATUS_LABELS[watch.status] || watch.status)].sort((a, b) => b[1] - a[1]);
  const designCounts = [...counter(scope, watch => watch.original === true ? "Original" : watch.original === false ? "Rep / homage" : "Unknown")];
  const originalScope = state.originalsOnly ? scope.filter(isOriginalBreadthWatch) : scope;
  const priceScopeOwned = state.originalsOnly ? owned.filter(isOriginalBreadthWatch) : owned;
  const gaps = biggestGaps(priceScopeOwned);
  const realOwnedBrands = counter(owned.filter(isBrandBreadthWatch), watchBrand);
  const realAllBrands = counter(all.filter(isBrandBreadthWatch), watchBrand);
  const pastRealBrands = counter(all.filter(w => w.status !== "owned" && isBrandBreadthWatch(w)), watchBrand);
  const exploredLetGo = [...pastRealBrands].filter(([brand]) => !realOwnedBrands.has(brand)).sort((a, b) => b[1] - a[1]);
  const firstBrandYears = new Map();
  all.filter(w => isBrandBreadthWatch(w) && w.purchased).sort((a, b) => a.purchased.localeCompare(b.purchased)).forEach(watch => {
    if (!firstBrandYears.has(watchBrand(watch))) firstBrandYears.set(watchBrand(watch), watch.purchased.slice(0, 4));
  });
  const exploration = [...counter([...firstBrandYears.values()], year => year)].sort((a, b) => a[0].localeCompare(b[0]));
  const repBrands = [...new Set(all.filter(w => w.original === false).map(watchBrand))].sort();
  const expensiveKept = [...owned].sort((a, b) => b.price - a.price)[0];
  const cheapestEver = [...all].sort((a, b) => a.price - b.price)[0];
  const avgDiameter = scope.filter(w => w.diameter != null).length ? sum(scope.filter(w => w.diameter != null).map(w => w.diameter)) / scope.filter(w => w.diameter != null).length : 0;
  const monthSpend = new Map();
  all.filter(w => w.purchased).forEach(w => monthSpend.set(w.purchased, (monthSpend.get(w.purchased) || 0) + w.price));
  const spree = [...monthSpend].sort((a, b) => b[1] - a[1])[0];
  const offender = [...owned].map(watch => ({ watch, fit: fitInfo({ ...watch, lugToLug: null }) })).filter(x => ["over", "under"].includes(x.fit.key)).sort((a, b) => Math.abs(Number(b.watch.diameter) - wrist.perfect) - Math.abs(Number(a.watch.diameter) - wrist.perfect))[0];

  $("#statsContent").innerHTML = `
    <div class="stat-grid">
      ${[
        ["Count", Number(hl.count ?? 0)], ["Total spent", money(hl.total ?? 0)], ["Mean", money(hl.mean ?? 0)], ["Median", money(hl.median ?? 0)],
        ["IQR (P25–P75)", iqrRange], ["Minimum", money(hl.min ?? 0)], ["Maximum", money(hl.max ?? 0)], ["Std dev (sample)", money(hl.stdDev ?? 0)], ["Skewness", Number(hl.skewness ?? 0).toFixed(3)],
        ["Owned in sweet spot", `${sweetPercent.toFixed(0)}%`],
      ].map(([label, value]) => `<div class="stat-tile"><span>${label}</span><strong>${value}</strong></div>`).join("")}
    </div>
    <div class="stats-layout">
      <section class="panel wide"><div class="panel-heading"><div><p class="eyebrow">Distribution</p><h3>Percentiles</h3></div><small>Linear interpolation</small></div><div class="chip-cloud">${pcts.map(percent => `<span class="chip">P${percent} <strong>${money(percentile(scope.map(w => w.price), percent))}</strong></span>`).join("")}</div></section>

      <section class="panel wide"><div class="panel-heading"><div><p class="eyebrow">Price tiers</p><h3>Cost histogram</h3></div><small>Every tier in this ${state.statsScope === "owned" ? "current" : "all-time"} scope</small></div>${costHistogramChart(costHist, hl)}</section>

      <section class="panel"><div class="panel-heading"><div><p class="eyebrow">Diameter</p><h3>Size distribution</h3></div><small>${wrist.sweetSpotMin}–${wrist.sweetSpotMax}mm sweet · ${wrist.perfect}mm perfect</small></div>
        ${diamHist.length ? barRows(diamHist.map(([lower, count]) => [`${lower}–${(lower + 1.9).toFixed(1)}mm`, count])) : `<p class="form-note">No diameter data.</p>`}
        <div class="callout">Shaded guidance: ${wrist.sweetSpotMin}–${wrist.sweetSpotMax}mm is your sweet spot; ${wrist.perfect}mm is the centre marker.</div>
      </section>
      <section class="panel"><div class="panel-heading"><div><p class="eyebrow">Wearability</p><h3>Lug-to-lug</h3></div><small>${wrist.lugMax}mm ceiling marker</small></div>${lugHist.length ? barRows(lugHist.map(([lower, count]) => [`${lower}–${(lower + 1.9).toFixed(1)}mm`, count])) : `<p class="form-note">No lug-to-lug measurements yet. Add them through Complete your data.</p>`}</section>

      <section class="panel"><div class="panel-heading"><div><p class="eyebrow">Timeline</p><h3>Spend by year</h3></div></div>${barRows(yearSpend, money)}</section>
      <section class="panel"><div class="panel-heading"><div><p class="eyebrow">Brands</p><h3>All-watch breakdown</h3></div></div>${barRows(brandCounts)}</section>
      <section class="panel"><div class="panel-heading"><div><p class="eyebrow">Design</p><h3>Original vs rep</h3></div></div>${barRows(designCounts)}</section>
      <section class="panel"><div class="panel-heading"><div><p class="eyebrow">Outcomes</p><h3>Status breakdown</h3></div></div>${barRows(statusCounts)}</section>

      <section class="panel wide"><div class="panel-heading"><div><p class="eyebrow">Buying guide</p><h3>Category coverage</h3></div><button class="text-button" data-manage="categories" type="button">Manage categories</button></div><div class="coverage-grid">${categoryCoverage()}</div></section>

      <section class="panel wide"><div class="panel-heading"><div><p class="eyebrow">Money-side buying guide</p><h3>Price ladder</h3></div><label class="toggle-row"><span>Originals only</span><input id="originalsToggle" type="checkbox" ${state.originalsOnly ? "checked" : ""}></label></div>
        <div class="tier-grid">${PRICE_TIERS.map(tier => {
          const matches = priceScopeOwned.filter(watch => priceTier(watch.price)?.label === tier.label);
          return `<div class="coverage-item"><strong>${tier.label} ${matches.length ? "" : `<span class="chip gap">GAP</span>`}</strong><small>${matches.length ? matches.map(w => esc(w.name)).join(", ") : "No owned watch"}</small></div>`;
        }).join("")}</div>
        ${gaps.length ? `<div class="callout">${gaps.map((gap, index) => `${index ? "Second hole" : "Biggest hole"}: nothing between ${money(gap.low.price)} and ${money(gap.high.price)}`).join(" · ")}</div>` : ""}
      </section>

      <section class="panel wide"><div class="panel-heading"><div><p class="eyebrow">Explore before repeating</p><h3>Brand breadth</h3></div><strong>${realOwnedBrands.size} unique / ${owned.length} owned · ${realAllBrands.size} explored all-time</strong></div>
        ${barRows([...realOwnedBrands].sort((a,b) => b[1]-a[1]).map(([brand,count]) => [brand, count, count >= 2 ? " · saturated" : ""]))}
        <p class="form-note"><strong>Explored & let go:</strong> ${exploredLetGo.length ? exploredLetGo.map(([brand,count]) => `${esc(brand)} (${count})`).join(" · ") : "none"}</p>
        <p class="form-note"><strong>Brands on radar:</strong> ${state.data.brandWatchlist.map(entry => {
          const status = realOwnedBrands.has(entry.brand) ? "owned" : realAllBrands.has(entry.brand) ? "explored" : "new";
          return `<span class="chip saturated">${esc(entry.brand)} · ${status}</span>`;
        }).join(" ")}</p>
        <p class="form-note"><strong>Rep brands worn (excluded from breadth):</strong> ${repBrands.map(esc).join(" · ")}</p>
        <div class="panel-heading"><div><p class="eyebrow">Discovery pace</p><h3>First-ever original brands by year</h3></div></div>${barRows(exploration)}
      </section>

      ${varietyPanel("Dial colours", "dialColor", state.data.dialColors, "dialcolors")}
      ${varietyPanel("Case materials", "material", state.data.materials, "materials")}

      <section class="panel wide"><div class="panel-heading"><div><p class="eyebrow">Collection notes</p><h3>Fun facts</h3></div></div><div class="chip-cloud">
        <span class="chip">Most expensive kept: ${esc(expensiveKept.name)} · ${money(expensiveKept.price)}</span>
        <span class="chip">Cheapest ever: ${esc(cheapestEver.name)} · ${money(cheapestEver.price)}</span>
        <span class="chip">Average diameter: ${avgDiameter.toFixed(1)}mm</span>
        <span class="chip">Reps all-time: ${(all.filter(w => w.original === false).length / all.length * 100).toFixed(0)}%</span>
        <span class="chip">Biggest spree: ${esc(spree[0])} · ${money(spree[1])}</span>
        ${offender ? `<span class="chip">Biggest wrist offender: ${esc(offender.watch.name)} · ${esc(offender.fit.label)}</span>` : ""}
      </div></section>
    </div>`;
  $("#originalsToggle")?.addEventListener("change", event => { state.originalsOnly = event.target.checked; renderStats(); });
}

function completeQueue() {
  return state.data.watches.filter(watch => watch.status === "owned" && (watch.dialColor == null || watch.material == null || watch.lugToLug == null)).map(watch => watch.id);
}

function renderNudge() {
  const owned = state.data.watches.filter(w => w.status === "owned");
  const dialMissing = owned.filter(w => w.dialColor == null).length;
  const materialMissing = owned.filter(w => w.material == null).length;
  const lugMissing = owned.filter(w => w.lugToLug == null).length;
  $("#completeDataNudge").innerHTML = dialMissing || materialMissing || lugMissing ? `<div class="nudge"><span><strong>Complete your data</strong> · ${dialMissing} dial colours, ${materialMissing} materials, ${lugMissing} lug-to-lug measurements missing.</span><button class="button small" data-action="complete-data" type="button">Fill in sequence</button></div>` : "";
}

function wishlistScore(item) {
  const owned = state.data.watches.filter(watch => watch.status === "owned");
  const currentOriginalBrands = counter(owned.filter(isBrandBreadthWatch), watchBrand);
  const pastOriginalBrands = counter(state.data.watches.filter(w => w.status !== "owned" && isBrandBreadthWatch(w)), watchBrand);
  const categoryCount = item.category == null ? null : owned.filter(w => w.category === item.category).length;
  const categoryScore = categoryCount == null ? 0 : categoryCount === 0 ? 3 : categoryCount === 1 ? 2 : categoryCount === 2 ? 1 : 0;
  const categoryReason = item.category == null ? "Category unset" : `${item.category} · ${categoryCount === 0 ? "never owned" : `${categoryCount} owned`}`;
  const brand = item.brand || brandForName(item.name);
  const currentBrandCount = currentOriginalBrands.get(brand) || 0;
  const pastBrandCount = pastOriginalBrands.get(brand) || 0;
  const brandScore = currentBrandCount >= 2 ? -1 : currentBrandCount === 1 ? 0 : pastBrandCount ? 1 : 2;
  const brandReason = `${brand} · ${currentBrandCount >= 2 ? `${currentBrandCount} currently owned` : currentBrandCount ? "currently owned" : pastBrandCount ? "explored before" : "new brand"}`;
  const tier = priceTier(item.priceExpected);
  const tierAllCount = tier ? owned.filter(w => priceTier(w.price)?.label === tier.label).length : 0;
  const tierOriginalCount = tier ? owned.filter(isOriginalBreadthWatch).filter(w => priceTier(w.price)?.label === tier.label).length : 0;
  const priceScore = !tier ? 0 : tierOriginalCount === 0 ? 2 : tierAllCount === 0 ? 1 : 0;
  const priceReason = !tier ? "Price unset" : `${tier.label} · ${priceScore === 2 ? "empty originals tier" : priceScore === 1 ? "empty all-owned tier" : "represented"}`;
  const dialCount = item.dialColor == null ? null : owned.filter(w => w.dialColor === item.dialColor).length;
  const dialScore = dialCount == null ? 0 : dialCount === 0 ? 2 : dialCount === 1 ? 1 : 0;
  const dialReason = item.dialColor == null ? "Dial unset" : `${item.dialColor} · ${dialCount === 0 ? "not represented" : `${dialCount} owned`}`;
  const fit = fitInfo(item);
  const materialCount = item.material == null ? null : owned.filter(w => w.material === item.material).length;
  const materialScore = materialCount == null ? 0 : materialCount === 0 ? 2 : materialCount === 1 ? 1 : 0;
  const materialReason = item.material == null ? "Material unset" : `${item.material} · ${materialCount === 0 ? "not represented" : `${materialCount} owned`}`;
  const lenses = [
    { name: "Category", score: categoryScore, reason: categoryReason },
    { name: "Brand", score: brandScore, reason: brandReason },
    { name: "Price", score: priceScore, reason: priceReason },
    { name: "Dial", score: dialScore, reason: dialReason },
    { name: "Size", score: fit.score, reason: fit.label || "Size unset" },
    { name: "Material", score: materialScore, reason: materialReason },
  ];
  return { total: sum(lenses.map(lens => lens.score)), max: WISHLIST_WEIGHTS.max, lenses };
}

function radarStatus(brand) {
  const originalAll = state.data.watches.filter(isBrandBreadthWatch);
  const current = originalAll.some(w => w.status === "owned" && watchBrand(w) === brand);
  const past = originalAll.some(w => watchBrand(w) === brand);
  return current ? "owned" : past ? "explored before" : "new brand";
}

function renderWishlist() {
  $("#radarChips").innerHTML = state.data.brandWatchlist.map(entry => `<span class="radar-chip"><strong>${esc(entry.brand)}</strong><span>${radarStatus(entry.brand)}</span><button type="button" data-radar-model="${esc(entry.brand)}">→ add model</button><button type="button" data-radar-delete="${esc(entry.brand)}" aria-label="Remove ${esc(entry.brand)}">×</button></span>`).join("");
  const items = state.data.wishlist.map(item => ({ item, scored: wishlistScore(item) })).sort((a, b) => {
    const statusRank = value => value === "considering" ? 0 : value === "passed" ? 1 : 2;
    return statusRank(a.item.status) - statusRank(b.item.status) || b.scored.total - a.scored.total || (a.item.priceExpected ?? Infinity) - (b.item.priceExpected ?? Infinity);
  });
  $("#wishlistList").innerHTML = items.map(({ item, scored }) => `<article class="wishlist-card ${esc(item.status)}" id="wishlist-${esc(item.id)}">
    <button class="card-hit" type="button" data-open-wishlist="${esc(item.id)}">${imageMarkup(item, "wishlist", "wishlist-image")}</button>
    <div class="wishlist-main"><h3>${esc(item.name)}</h3><p>${esc(item.priceNote || money(item.priceExpected))} · ${esc(item.category || "category unset")}</p><div class="chip-row">${fitChip(item)}${item.dialColor ? dialChip(item) : ""}${item.material ? `<span class="chip">${esc(item.material)}</span>` : ""}</div></div>
    <div class="lens-list">${scored.lenses.map(lens => `<span class="lens" title="${esc(lens.reason)}"><span>${esc(lens.reason)}</span><b>${lens.score >= 0 ? "+" : ""}${lens.score}</b></span>`).join("")}</div>
    <div><div class="score">${scored.total}<small>/ ${scored.max}</small></div><div class="wishlist-actions">
      <button class="button small" type="button" data-open-wishlist="${esc(item.id)}">Edit</button>
      ${item.status === "considering" ? `<button class="button small" type="button" data-wishlist-action="passed" data-id="${esc(item.id)}">Pass</button><button class="button small accent" type="button" data-wishlist-action="bought" data-id="${esc(item.id)}">Bought</button>` : ""}
      <button class="button small" type="button" data-wishlist-action="autoimage" data-id="${esc(item.id)}">Find image</button>
    </div></div>
  </article>`).join("");
}

function renderSuggestions() {
  const payload = state.suggestions || { saturated: { categories: [], dials: [], brands: [] }, suggestions: [] };
  const owned = state.data.watches.filter(watch => watch.status === "owned");
  const categoryCounts = counter(owned.filter(watch => watch.category), watch => watch.category);
  const dialCounts = counter(owned.filter(watch => watch.dialColor), watch => watch.dialColor);
  const brandCounts = counter(owned.filter(isBrandBreadthWatch), watchBrand);
  const saturated = [
    ...payload.saturated.categories.map(name => `${name} ×${categoryCounts.get(name) || 0}`),
    ...payload.saturated.dials.map(name => `${name} dials ×${dialCounts.get(name) || 0}`),
    ...payload.saturated.brands.map(name => `${name} brand ×${brandCounts.get(name) || 0}`),
  ];
  $("#saturationStrip").textContent = saturated.length ? `Well covered: ${saturated.join(" · ")}` : "No saturated areas yet — the collection is wide open.";
  const wishlistByID = new Map(state.data.wishlist.map(item => [item.id, item]));
  $("#suggestionCards").innerHTML = payload.suggestions.length ? payload.suggestions.map(suggestion => `
    <article class="suggestion-card">
      <div class="suggestion-title"><h4>${esc(suggestion.headline)}</h4><span class="suggestion-score">${suggestion.score}<small>/ 9</small></span></div>
      ${(suggestion.brands || []).length ? `<div class="suggestion-brands"><span class="suggestion-brands-label">Brands to explore</span><div class="chip-row">${suggestion.brands.map(brand => `<span class="chip suggestion-brand-chip ${brand.status === "radar" ? "radar" : ""}"><strong>${esc(brand.name)}</strong><small>${esc(brand.status)}</small></span>`).join("")}</div></div>` : ""}
      <div class="chip-row suggestion-reasons">${suggestion.reasons.map(reason => `<span class="chip">${esc(reason)}</span>`).join("")}</div>
      ${suggestion.wishlistMatches.length ? `<p class="suggestion-matches"><strong>Your candidates:</strong> ${suggestion.wishlistMatches.map(id => {
        const item = wishlistByID.get(id);
        return `<button class="text-button" type="button" data-suggestion-match="${esc(id)}">${esc(item?.name || id)}</button>`;
      }).join(" · ")}</p>` : ""}
    </article>`).join("") : `<div class="empty-state compact">No eligible category gaps. Adjust suggestion categories in Settings.</div>`;
}

function renderFilters() {
  const current = $("#categoryFilter").value;
  $("#categoryFilter").innerHTML = `<option value="">All categories</option>${state.data.categories.map(value => `<option value="${esc(value)}">${esc(value)}</option>`).join("")}`;
  $("#categoryFilter").value = state.data.categories.includes(current) ? current : "";
  const statuses = [...new Set(state.data.watches.filter(w => w.status !== "owned").map(w => w.status))];
  const statusCurrent = $("#statusFilter").value;
  $("#statusFilter").innerHTML = `<option value="">All outcomes</option>${statuses.map(value => `<option value="${esc(value)}">${esc(STATUS_LABELS[value] || value)}</option>`).join("")}`;
  $("#statusFilter").value = statuses.includes(statusCurrent) ? statusCurrent : "";
}

function renderCounts() {
  $("#collectionCount").textContent = state.data.watches.filter(w => w.status === "owned").length;
  $("#pastCount").textContent = state.data.watches.filter(w => w.status !== "owned").length;
  $("#wishlistCount").textContent = state.data.wishlist.filter(w => w.status === "considering").length;
}

function renderAll() {
  renderOwnerTitle(); renderFilters(); renderCounts(); renderGrids(); renderNudge(); renderStats(); renderSuggestions(); renderWishlist();
}

function renderOwnerTitle() {
  // Personalization lives in the (gitignored) data file, not the code.
  const owner = state.data.settings.ownerName;
  const title = owner ? `${owner}’s Watches` : "Watch Collection";
  $("#owner-title").textContent = title;
  document.title = owner ? `${owner}'s Watch Collection` : "Watch Collection";
}

function taxonomyOptions(values, selected, route, label) {
  return `<option value="">Unset</option>${values.map(value => `<option value="${esc(value)}" ${value === selected ? "selected" : ""}>${esc(value)}</option>`).join("")}<option value="__new_${route}">+ new ${label}…</option>`;
}

function formValue(value) { return value == null ? "" : esc(value); }

function renderGallery(item, kind, isNew) {
  const photos = item?.photos || [];
  const index = Math.min(state.modal?.galleryIndex || 0, Math.max(0, photos.length - 1));
  if (state.modal) state.modal.galleryIndex = index;
  const active = photos[index];
  const main = active ? `<img src="/photos/${encodeURIComponent(photoDirectory(kind, item.id))}/${encodeURIComponent(active)}" alt="${esc(item.name)}">` : placeholder();
  return `<div class="gallery-side">
    <div class="gallery-main">${main}</div>
    <div class="gallery-thumbs">${photos.map((photo, photoIndex) => `<button class="thumb ${photoIndex === index ? "active" : ""}" data-gallery-index="${photoIndex}" type="button"><img src="/photos/${encodeURIComponent(photoDirectory(kind, item.id))}/${encodeURIComponent(photo)}" alt="Photo ${photoIndex + 1}">${photo.startsWith("auto-") ? `<span class="auto-label">auto</span>` : ""}</button>`).join("")}</div>
    <div class="gallery-actions">
      <label class="button small">Upload<input id="photoInput" type="file" accept="image/jpeg,image/png,image/webp,image/heic" multiple hidden></label>
      ${active && !isNew ? `<button class="button small" type="button" data-photo-action="cover" data-filename="${esc(active)}">Set cover</button><button class="button small danger" type="button" data-photo-action="delete" data-filename="${esc(active)}">Delete photo</button>` : ""}
      ${kind === "wishlist" && !isNew ? `<button class="button small" type="button" data-photo-action="autoimage">Find image</button>` : ""}
    </div>
    <div class="drop-zone" id="dropZone">Drop or paste an image anywhere in this window${isNew ? " · it will upload after save" : ""}${state.pendingUploads.length ? ` · ${state.pendingUploads.length} queued` : ""}</div>
    <p class="form-note" id="imageSearchFallback"></p>
  </div>`;
}

function itemForm(item, kind, isNew) {
  const wishlist = kind === "wishlist";
  const title = isNew ? (wishlist ? "Add candidate" : "Add watch") : item.name;
  const statusOptions = wishlist ? ["considering", "passed", "bought"] : Object.keys(STATUS_LABELS);
  return `<div class="item-layout">
    ${renderGallery(item, kind, isNew)}
    <div class="form-side"><div class="modal-title"><p class="eyebrow">${wishlist ? "Purchase candidate" : "Collection record"}</p><h2>${esc(title)}</h2></div>
      <form id="itemForm" class="form-grid" data-kind="${kind}" data-id="${esc(item?.id || "")}" data-new="${isNew}">
        <label class="wide">Name<input name="name" value="${formValue(item?.name)}" required></label>
        ${wishlist ? `<label>Brand<input name="brand" value="${formValue(item?.brand)}" required></label>` : ""}
        <label>Category<select name="category">${taxonomyOptions(state.data.categories, item?.category, "categories", "category")}</select></label>
        <label>Dial colour<select name="dialColor">${taxonomyOptions(state.data.dialColors, item?.dialColor, "dialcolors", "colour")}</select></label>
        <label>Case material<select name="material">${taxonomyOptions(state.data.materials, item?.material, "materials", "material")}</select></label>
        <label>Diameter (mm)<input name="diameter" type="number" min="1" step="0.1" value="${formValue(item?.diameter)}"></label>
        <label>Lug-to-lug (mm)<input name="lugToLug" type="number" min="1" step="0.1" value="${formValue(item?.lugToLug)}"></label>
        ${wishlist ? `
          <label>Expected price (CAD)<input name="priceExpected" type="number" min="0" step="0.01" value="${formValue(item?.priceExpected)}"></label>
          <label>Quote text<input name="priceNote" value="${formValue(item?.priceNote)}"></label>
          <label>Added<input name="added" type="month" value="${formValue(item?.added || new Date().toISOString().slice(0,7))}" required></label>
          <label>Status<select name="status">${statusOptions.map(value => `<option value="${value}" ${item?.status === value ? "selected" : ""}>${value}</option>`).join("")}</select></label>
          <label class="wide">Notes<textarea name="notes">${esc(item?.notes || "")}</textarea></label>
        ` : `
          <label>Price paid (CAD)<input name="price" type="number" min="0" step="0.01" value="${formValue(item?.price ?? 0)}" required></label>
          <label>Purchase month<input name="purchased" type="month" value="${formValue(item?.purchased)}"></label>
          <label class="wide">Purchase date as written<input name="purchasedText" value="${formValue(item?.purchasedText)}"></label>
          <label>Original design?<select name="original"><option value="" ${item?.original == null ? "selected" : ""}>Unknown</option><option value="true" ${item?.original === true ? "selected" : ""}>Original</option><option value="false" ${item?.original === false ? "selected" : ""}>Rep / homage</option></select></label>
          <label>Status<select name="status">${statusOptions.map(value => `<option value="${value}" ${item?.status === value ? "selected" : ""}>${STATUS_LABELS[value]}</option>`).join("")}</select></label>
          <label class="wide">Story<textarea name="story">${esc(item?.story || "")}</textarea></label>
          <label class="wide">Status note<input name="statusNote" value="${formValue(item?.statusNote)}"></label>
        `}
        <div class="form-actions wide"><div>${!isNew ? `<button class="button small danger" type="button" data-delete-item>Delete</button>` : ""}</div><button class="button accent" type="submit">${isNew ? "Create" : "Save changes"}</button></div>
      </form>
    </div>
  </div>`;
}

function openItem(kind, item = null, options = {}) {
  const isNew = !item;
  const blank = kind === "watch" ? { name: "", photos: [], status: "owned" } : { name: "", brand: options.brand || "", photos: [], status: "considering", added: new Date().toISOString().slice(0, 7) };
  state.pendingUploads = [];
  state.modal = { kind, id: item?.id || null, isNew, galleryIndex: 0, completeQueue: options.completeQueue || null };
  $("#itemDialogContent").innerHTML = itemForm(item || blank, kind, isNew);
  $("#itemDialog").showModal();
  $("#itemForm [name='name']").focus();
}

function currentModalItem() {
  if (!state.modal || state.modal.isNew) return null;
  const list = state.modal.kind === "watch" ? state.data.watches : state.data.wishlist;
  return list.find(item => item.id === state.modal.id);
}

function rerenderModal() {
  const item = currentModalItem();
  if (!state.modal || (!item && !state.modal.isNew)) return;
  const form = $("#itemForm");
  const values = form ? Object.fromEntries(new FormData(form)) : {};
  const originalForm = state.modal.isNew ? null : item;
  $("#itemDialogContent").innerHTML = itemForm(originalForm || { ...values, photos: [] }, state.modal.kind, state.modal.isNew);
}

function serializeItemForm(form) {
  const values = Object.fromEntries(new FormData(form));
  const kind = form.dataset.kind;
  for (const field of ["diameter", "lugToLug", ...(kind === "watch" ? ["price"] : ["priceExpected"])]) values[field] = values[field] === "" ? null : Number(values[field]);
  for (const field of ["category", "dialColor", "material"]) values[field] = values[field] || null;
  if (kind === "watch") {
    values.purchased = values.purchased || null;
    values.original = values.original === "" ? null : values.original === "true";
  }
  return values;
}

async function uploadFiles(kind, id, files) {
  for (const file of files) {
    const form = new FormData(); form.append("photo", file, file.name || `pasted-${Date.now()}.png`);
    await api(`/api/${kind === "watch" ? "watches" : "wishlist"}/${encodeURIComponent(id)}/photos`, { method: "POST", body: form });
  }
}

async function handleItemSubmit(event) {
  event.preventDefault();
  const form = event.currentTarget;
  const kind = form.dataset.kind;
  const plural = kind === "watch" ? "watches" : "wishlist";
  const payload = serializeItemForm(form);
  try {
    const result = await api(form.dataset.new === "true" ? `/api/${plural}` : `/api/${plural}/${encodeURIComponent(form.dataset.id)}`, { method: form.dataset.new === "true" ? "POST" : "PUT", body: JSON.stringify(payload) });
    if (state.pendingUploads.length) await uploadFiles(kind, result.id, state.pendingUploads);
    const queue = state.modal?.completeQueue ? [...state.modal.completeQueue].filter(id => id !== result.id) : null;
    $("#itemDialog").close(); state.modal = null; state.pendingUploads = [];
    await refresh();
    toast(form.dataset.new === "true" ? "Added." : "Saved.");
    if (queue?.length) {
      const next = state.data.watches.find(watch => watch.id === queue[0]);
      if (next) openItem("watch", next, { completeQueue: queue });
    }
  } catch (error) { toast(error.message, true); }
}

async function handlePhotoFiles(files) {
  const images = [...files].filter(file => file.type.startsWith("image/") || /\.(jpe?g|png|webp|heic)$/i.test(file.name));
  if (!images.length || !state.modal) return;
  if (state.modal.isNew) {
    state.pendingUploads.push(...images);
    $("#dropZone").textContent = `${state.pendingUploads.length} image${state.pendingUploads.length === 1 ? "" : "s"} queued for upload after save`;
    toast("Image queued. Save the record to upload it.");
    return;
  }
  try {
    await uploadFiles(state.modal.kind, state.modal.id, images);
    await refresh(); rerenderModal(); toast("Photo uploaded.");
  } catch (error) { toast(error.message, true); }
}

async function photoAction(action, filename) {
  const item = currentModalItem(); if (!item) return;
  const plural = state.modal.kind === "watch" ? "watches" : "wishlist";
  let fallback = null;
  try {
    if (action === "cover") await api(`/api/${plural}/${item.id}/photos/${encodeURIComponent(filename)}/cover`, { method: "POST" });
    if (action === "delete") await api(`/api/${plural}/${item.id}/photos/${encodeURIComponent(filename)}`, { method: "DELETE" });
    if (action === "autoimage") {
      const result = await api(`/api/wishlist/${item.id}/autoimage`, { method: "POST" });
      if (!result.ok) fallback = result.searchUrl;
    }
    await refresh(); state.modal.galleryIndex = 0; rerenderModal();
    if (fallback) $("#imageSearchFallback").innerHTML = `No image found. <a href="${esc(fallback)}" target="_blank" rel="noopener">Open image search</a>, copy an image, then paste it here.`;
    else toast(action === "delete" ? "Photo deleted." : action === "cover" ? "Cover updated." : "Image updated.");
  } catch (error) { toast(error.message, true); }
}

async function deleteCurrentItem() {
  const item = currentModalItem(); if (!item) return;
  if (!confirm(`Delete ${item.name}? This cannot be undone.`)) return;
  const plural = state.modal.kind === "watch" ? "watches" : "wishlist";
  try {
    await api(`/api/${plural}/${encodeURIComponent(item.id)}`, { method: "DELETE" });
    $("#itemDialog").close(); state.modal = null; await refresh(); toast("Deleted.");
  } catch (error) { toast(error.message, true); }
}

function openTaxonomy(route) {
  const config = {
    categories: ["Categories", "category", state.data.categories],
    dialcolors: ["Dial colours", "colour", state.data.dialColors],
    materials: ["Case materials", "material", state.data.materials],
  }[route];
  state.taxonomy = route;
  $("#taxonomyTitle").textContent = `Manage ${config[0].toLowerCase()}`;
  $("#taxonomyAddInput").placeholder = `New ${config[1]}`;
  $("#taxonomyList").innerHTML = config[2].map((value, index, values) => `<div class="taxonomy-row" data-value="${esc(value)}"><button type="button" data-tax-action="up" ${index === 0 ? "disabled" : ""}>↑</button><button type="button" data-tax-action="down" ${index === values.length - 1 ? "disabled" : ""}>↓</button><input value="${esc(value)}" aria-label="Rename ${esc(value)}"><button type="button" data-tax-action="rename">✓</button><button type="button" data-tax-action="delete">×</button></div>`).join("");
  if (!$("#taxonomyDialog").open) $("#taxonomyDialog").showModal();
}

function taxonomyArray() {
  return state.taxonomy === "categories" ? state.data.categories : state.taxonomy === "dialcolors" ? state.data.dialColors : state.data.materials;
}

async function taxonomyOperation(body) {
  try {
    await api(`/api/${state.taxonomy}`, { method: "PUT", body: JSON.stringify(body) });
    await refresh(); openTaxonomy(state.taxonomy); toast("List updated.");
  } catch (error) { toast(error.message, true); }
}

function openSettings() {
  const settings = state.data.settings, wrist = settings.wrist;
  const form = $("#settingsForm");
  form.elements.autoBackup.checked = Boolean(settings.autoBackup);
  form.elements.autoImage.checked = Boolean(settings.autoImage);
  const excluded = new Set(settings.suggestExclude || []);
  $("#suggestCategoryChips").innerHTML = state.data.categories.map(category => {
    const allowed = !excluded.has(category);
    return `<button class="suggest-chip ${allowed ? "active" : ""}" type="button" data-suggest-category="${esc(category)}" aria-pressed="${allowed}">${esc(category)}</button>`;
  }).join("");
  ["inches", "sweetSpotMin", "sweetSpotMax", "perfect", "lugMax"].forEach(field => { form.elements[field].value = wrist[field]; });
  $("#backupStatus").textContent = `Destination: ${settings.backupRemote || "gdrive:WatchCollection/"}${settings.lastBackup ? ` · last backup ${new Date(settings.lastBackup).toLocaleString()}` : " · never backed up"}`;
  $("#settingsDialog").showModal();
}

async function saveSettings(event) {
  event.preventDefault(); const form = event.currentTarget;
  const wrist = Object.fromEntries(["inches", "sweetSpotMin", "sweetSpotMax", "perfect", "lugMax"].map(field => [field, Number(form.elements[field].value)]));
  const suggestExclude = $$('[data-suggest-category]', form).filter(button => button.getAttribute("aria-pressed") !== "true").map(button => button.dataset.suggestCategory);
  try {
    await api("/api/settings", { method: "PUT", body: JSON.stringify({ autoBackup: form.elements.autoBackup.checked, autoImage: form.elements.autoImage.checked, suggestExclude, wrist }) });
    await refresh(); $("#settingsDialog").close(); toast("Settings saved.");
  } catch (error) { toast(error.message, true); }
}

async function backupNow() {
  const button = $("#backupNowButton"); button.disabled = true; button.textContent = "Backing up…";
  try {
    const result = await api("/api/backup", { method: "POST" });
    $("#backupStatus").textContent = result.output; await refresh(); toast("Backup complete.");
  } catch (error) { $("#backupStatus").textContent = error.message; toast(error.message, true); }
  finally { button.disabled = false; button.textContent = "Back up now"; }
}

function setTab(tab) {
  state.tab = tab;
  $$(".tab").forEach(button => button.classList.toggle("active", button.dataset.tab === tab));
  $$(".tab-panel").forEach(panel => panel.classList.toggle("active", panel.dataset.panel === tab));
  $("#collectionToolbar").classList.toggle("hidden", !["collection", "past"].includes(tab));
}

function wireEvents() {
  $$(".tab").forEach(button => button.addEventListener("click", () => setTab(button.dataset.tab)));
  $("#searchInput").addEventListener("input", renderGrids);
  $("#categoryFilter").addEventListener("change", renderGrids);
  $("#statusFilter").addEventListener("change", renderGrids);
  $("#addWatchButton").addEventListener("click", () => openItem("watch"));
  $("#addCandidateButton").addEventListener("click", () => openItem("wishlist"));
  $("#settingsButton").addEventListener("click", openSettings);
  $("#settingsForm").addEventListener("submit", saveSettings);
  $("#backupNowButton").addEventListener("click", backupNow);
  $("#boughtForm").addEventListener("submit", async event => {
    event.preventDefault(); const values = Object.fromEntries(new FormData(event.currentTarget));
    try { await api(`/api/wishlist/${values.id}/bought`, { method: "POST", body: JSON.stringify({ price: Number(values.price), purchased: values.purchased }) }); $("#boughtDialog").close(); await refresh(); toast("Moved into the collection."); }
    catch (error) { toast(error.message, true); }
  });
  $("#taxonomyAddForm").addEventListener("submit", event => { event.preventDefault(); const input = $("#taxonomyAddInput"); taxonomyOperation({ add: input.value }); input.value = ""; });
  $("#radarForm").addEventListener("submit", async event => {
    event.preventDefault(); const brand = new FormData(event.currentTarget).get("brand");
    try { await api("/api/brandwatchlist", { method: "POST", body: JSON.stringify({ brand }) }); event.currentTarget.reset(); await refresh(); toast("Brand added to radar."); }
    catch (error) { toast(error.message, true); }
  });
  $("#scopeToggle").addEventListener("click", event => {
    const button = event.target.closest("[data-scope]"); if (!button) return;
    state.statsScope = button.dataset.scope; $$("button", event.currentTarget).forEach(node => node.classList.toggle("active", node === button)); renderStats();
  });

  document.addEventListener("click", async event => {
    const close = event.target.closest("[data-close]"); if (close) $("#" + close.dataset.close).close();
    const watchButton = event.target.closest("[data-open-watch]");
    if (watchButton) openItem("watch", state.data.watches.find(w => w.id === watchButton.dataset.openWatch));
    const wishlistButton = event.target.closest("[data-open-wishlist]");
    if (wishlistButton) openItem("wishlist", state.data.wishlist.find(w => w.id === wishlistButton.dataset.openWishlist));
    const suggestionMatch = event.target.closest("[data-suggestion-match]");
    if (suggestionMatch) document.getElementById(`wishlist-${suggestionMatch.dataset.suggestionMatch}`)?.scrollIntoView({ behavior: "smooth", block: "center" });
    const suggestionCategory = event.target.closest("[data-suggest-category]");
    if (suggestionCategory) {
      const active = suggestionCategory.getAttribute("aria-pressed") !== "true";
      suggestionCategory.setAttribute("aria-pressed", String(active));
      suggestionCategory.classList.toggle("active", active);
    }
    const manage = event.target.closest("[data-manage]"); if (manage) openTaxonomy(manage.dataset.manage);
    if (event.target.closest("[data-action='complete-data']")) { const queue = completeQueue(); if (queue.length) openItem("watch", state.data.watches.find(w => w.id === queue[0]), { completeQueue: queue }); }
    const gallery = event.target.closest("[data-gallery-index]"); if (gallery && state.modal) { state.modal.galleryIndex = Number(gallery.dataset.galleryIndex); rerenderModal(); }
    const photo = event.target.closest("[data-photo-action]"); if (photo) photoAction(photo.dataset.photoAction, photo.dataset.filename);
    if (event.target.closest("[data-delete-item]")) deleteCurrentItem();
    const wishlistAction = event.target.closest("[data-wishlist-action]");
    if (wishlistAction) {
      const { id, wishlistAction: action } = wishlistAction.dataset;
      if (action === "passed") { try { await api(`/api/wishlist/${id}`, { method: "PUT", body: JSON.stringify({ status: "passed" }) }); await refresh(); toast("Marked passed."); } catch (error) { toast(error.message, true); } }
      if (action === "bought") { const form = $("#boughtForm"); form.elements.id.value = id; form.elements.purchased.value = new Date().toISOString().slice(0,7); $("#boughtDialog").showModal(); }
      if (action === "autoimage") { try { const result = await api(`/api/wishlist/${id}/autoimage`, { method: "POST" }); await refresh(); if (!result.ok) window.open(result.searchUrl, "_blank", "noopener"); else toast("Image found."); } catch (error) { toast(error.message, true); } }
    }
    const model = event.target.closest("[data-radar-model]"); if (model) openItem("wishlist", null, { brand: model.dataset.radarModel });
    const radarDelete = event.target.closest("[data-radar-delete]");
    if (radarDelete) { try { await api(`/api/brandwatchlist/${encodeURIComponent(radarDelete.dataset.radarDelete)}`, { method: "DELETE" }); await refresh(); } catch (error) { toast(error.message, true); } }
    const taxButton = event.target.closest("[data-tax-action]");
    if (taxButton) {
      const row = taxButton.closest(".taxonomy-row"), old = row.dataset.value, action = taxButton.dataset.taxAction;
      if (action === "rename") taxonomyOperation({ rename: { from: old, to: $("input", row).value } });
      if (action === "delete") taxonomyOperation({ delete: old });
      if (["up", "down"].includes(action)) { const values = [...taxonomyArray()], index = values.indexOf(old), next = action === "up" ? index - 1 : index + 1; [values[index], values[next]] = [values[next], values[index]]; taxonomyOperation({ reorder: values }); }
    }
  });

  $("#itemDialog").addEventListener("submit", event => { if (event.target.id === "itemForm") handleItemSubmit(event); });
  $("#itemDialog").addEventListener("change", event => {
    if (event.target.id === "photoInput") handlePhotoFiles(event.target.files);
    if (event.target.matches("select") && event.target.value.startsWith("__new_")) { const route = event.target.value.replace("__new_", ""); event.target.value = ""; openTaxonomy(route); }
  });
  $("#itemDialog").addEventListener("dragover", event => { event.preventDefault(); $("#dropZone")?.classList.add("dragging"); });
  $("#itemDialog").addEventListener("dragleave", event => { if (!event.currentTarget.contains(event.relatedTarget)) $("#dropZone")?.classList.remove("dragging"); });
  $("#itemDialog").addEventListener("drop", event => { event.preventDefault(); $("#dropZone")?.classList.remove("dragging"); handlePhotoFiles(event.dataTransfer.files); });

  // Guaranteed manual image path: paste clipboard image data while either item form is open.
  document.addEventListener("paste", event => {
    if (!$("#itemDialog").open) return;
    const files = [...event.clipboardData.items].filter(item => item.kind === "file" && item.type.startsWith("image/")).map(item => item.getAsFile()).filter(Boolean);
    if (files.length) { event.preventDefault(); handlePhotoFiles(files); }
  });

  document.addEventListener("keydown", event => {
    if (event.key === "/" && !["INPUT", "TEXTAREA", "SELECT"].includes(document.activeElement.tagName)) { event.preventDefault(); $("#searchInput").focus(); }
    if ($("#itemDialog").open && ["ArrowLeft", "ArrowRight"].includes(event.key)) {
      const item = currentModalItem(); if (!item?.photos?.length) return;
      const delta = event.key === "ArrowLeft" ? -1 : 1;
      state.modal.galleryIndex = (state.modal.galleryIndex + delta + item.photos.length) % item.photos.length; rerenderModal();
    }
  });
}

async function init() {
  wireEvents();
  try { await refresh(); setTab("collection"); }
  catch (error) { document.querySelector("main").innerHTML = `<div class="empty-state">Could not load the collection: ${esc(error.message)}</div>`; }
}

document.addEventListener("DOMContentLoaded", init);
