// ICICLE Insights dashboard. Client-rendered from the JSON API (/accounts /resources
// /metrics /releases). One filter bar (snapshot · platform · resource) scopes everything below
// it into three views: All platforms → Platform → Resource. Accounts are an implementation
// detail here — they all carry the same handle — so the account dimension is surfaced as the
// platform it lives on. Chart form is chosen by the data's job; series colors follow the
// resource entity from the validated CVD-safe palette.

const CATEGORICAL = {
  // Catppuccin Latte and Mocha accents, ordered to separate neighboring hues.
  light: ["#1e66f5", "#fe640b", "#40a02b", "#8839ef", "#df8e1d", "#ea76cb", "#179299", "#d20f39"],
  dark: ["#89b4fa", "#fab387", "#a6e3a1", "#cba6f7", "#f9e2af", "#f5c2e7", "#94e2d5", "#f38ba8"],
};
const PLATFORM_LABEL = { github: "GitHub", ghcr: "GHCR", huggingface: "Hugging Face", npm: "npm", pypi: "PyPI" };
const PLATFORM_ORDER = ["github", "ghcr", "huggingface", "npm", "pypi"];
const RESOURCE_ORDER = ["container", "dataset", "image", "model", "package", "repository", "service"];

const compact = new Intl.NumberFormat("en", { notation: "compact", maximumFractionDigits: 1 });
const whole = new Intl.NumberFormat("en");
const dateFmt = new Intl.DateTimeFormat("en", { year: "numeric", month: "short", day: "numeric" });

const state = {
  accounts: [], resources: [], metrics: [], releases: [],
  platformFilter: "all", resourceFilter: "all",
};
let charts = [];

// ---- theme ---------------------------------------------------------------

const isDark = () => document.documentElement.getAttribute("data-theme") === "dark";
const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
const ramp = () => (isDark() ? CATEGORICAL.dark : CATEGORICAL.light);
const paletteFor = (i) => (i < ramp().length ? ramp()[i] : (isDark() ? "#6c7086" : "#9ca0b0"));

// No label is drawn on top of a fill anywhere in this dashboard. Both palettes have accents
// that only one ink can sit on — Mocha's pastels swallow white (1.3:1), Latte's yellow and
// green swallow Base (2.3:1) — and picking ink per slice leaves one donut wearing two label
// colors. Donut values ride in the legend instead; bar values ride past the end of the bar.

// ---- helpers -------------------------------------------------------------

const titleCase = (s) => s.charAt(0).toUpperCase() + s.slice(1);
const platformLabel = (p) => PLATFORM_LABEL[p] ?? p;

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function currentScope() {
  if (state.resourceFilter !== "all") return "resource";
  if (state.platformFilter !== "all") return "platform";
  return "all";
}

function setSection(name, visible) {
  const s = document.querySelector(`[data-section="${name}"]`);
  if (s) s.hidden = !visible;
}

function scopedMetrics() {
  return state.metrics.filter((m) => {
    if (state.resourceFilter !== "all") return m.resourceID === state.resourceFilter;
    if (state.platformFilter !== "all") return state.resourcePlatform.get(m.resourceID) === state.platformFilter;
    return true;
  });
}

function metricsByType(metrics) {
  const map = new Map();
  for (const m of metrics) {
    if (!map.has(m.type)) map.set(m.type, []);
    map.get(m.type).push(m);
  }
  return map;
}

// Portfolio total over time: at each reading's timestamp, sum every resource's most recent
// reading at or before that moment. Summing per timestamp instead would undercount whenever
// resources are written at slightly different times — a bulk import spreads one sweep across
// many timestamps, leaving the final one holding only the few resources that landed in it.
function totalSeries(metrics) {
  const ordered = [...metrics].sort((a, b) => new Date(a.recordedAt) - new Date(b.recordedAt));
  const current = new Map();
  const points = new Map();
  for (const m of ordered) {
    current.set(m.resourceID, m.reading);
    let sum = 0;
    for (const v of current.values()) sum += v;
    points.set(new Date(m.recordedAt).getTime(), sum);
  }
  return [...points.entries()].sort((a, b) => a[0] - b[0]);
}
const totalLatest = (metrics) => { const s = totalSeries(metrics); return s.length ? s[s.length - 1][1] : 0; };

function latestByResource(metrics) {
  const best = new Map();
  for (const m of metrics) {
    const t = new Date(m.recordedAt).getTime();
    const cur = best.get(m.resourceID);
    if (!cur || t > cur.t) best.set(m.resourceID, { t, v: m.reading });
  }
  return best;
}

// ---- ApexCharts option builders -----------------------------------------

function donutOptions(labels, values, colors) {
  const total = values.reduce((a, b) => a + b, 0);
  return {
    chart: { type: "donut", height: 250, fontFamily: "inherit", foreColor: css("--chart-text"), background: "transparent" },
    labels, series: values, colors,
    stroke: { width: 2, colors: [css("--chart-surface")] },
    dataLabels: { enabled: false },
    plotOptions: { pie: { donut: { size: "64%", labels: { show: true, total: { show: true, label: "Total", color: css("--chart-muted"), formatter: () => whole.format(total) } } } } },
    legend: {
      position: "bottom", labels: { colors: css("--chart-text") }, markers: { width: 10, height: 10, radius: 6 },
      formatter: (label, o) => `${label} · ${whole.format(o.w.globals.series[o.seriesIndex])}`,
    },
    tooltip: { theme: isDark() ? "dark" : "light", y: { formatter: (v) => whole.format(v) } },
  };
}

// Round a raw axis ceiling up to the next readable step so ticks land on whole numbers instead
// of whatever the headroom multiplier happens to produce (1180 → 1200, not 1180).
function niceCeil(n) {
  if (!(n > 0)) return 1;
  const magnitude = 10 ** Math.floor(Math.log10(n));
  const step = [1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10].find((s) => n <= s * magnitude) ?? 10;
  return step * magnitude;
}

// Axis ticks come out of Apex's arithmetic, so the first one can be negative zero or a hair
// below it; Intl renders that as "-0". Collapsing to +0 is enough (-0 === 0 in JS).
const axisValue = (v) => compact.format(v === 0 ? 0 : v);

function barOptions(categories, values, colors) {
  // Labels ride just past the end of each bar rather than on the fill: readable at any bar
  // length in either theme, where an on-fill label fails on long pastel bars and a short bar
  // pushes its label onto the panel anyway. The axis carries headroom so the longest one fits.
  const peak = Math.max(...values, 0);
  return {
    chart: { type: "bar", height: Math.max(190, categories.length * 32 + 60), fontFamily: "inherit", foreColor: css("--chart-text"), background: "transparent", toolbar: { show: false } },
    series: [{ name: "Current reading", data: values }], colors: colors ?? [css("--accent")],
    plotOptions: { bar: { horizontal: true, distributed: Boolean(colors), borderRadius: 4, borderRadiusApplication: "end", barHeight: "62%", dataLabels: { position: "top" } } },
    dataLabels: { enabled: true, formatter: (v) => compact.format(v), textAnchor: "start", offsetX: 12, style: { colors: [css("--chart-text")], fontWeight: 500 } },
    // min is pinned because setting max alone lets Apex derive min from the data, which floats
    // the baseline off zero and makes bar length stop encoding the value.
    xaxis: { categories, min: 0, max: peak > 0 ? niceCeil(peak * 1.28) : undefined, labels: { style: { colors: css("--chart-muted") }, formatter: axisValue }, axisBorder: { show: false }, axisTicks: { show: false } },
    // Names sit off the bar starts by the same gap the values keep off the bar ends; the grid
    // padding gives that shift somewhere to go so the longest name isn't clipped at the edge.
    yaxis: { labels: { offsetX: -8, style: { colors: css("--chart-text") } } },
    grid: { borderColor: css("--chart-grid"), padding: { left: 8 }, xaxis: { lines: { show: true } }, yaxis: { lines: { show: false } } },
    legend: { show: false },
    tooltip: { theme: isDark() ? "dark" : "light", y: { formatter: (v) => whole.format(v) } },
  };
}

function mount(host, options) {
  const chart = new ApexCharts(host, options);
  chart.render();
  charts.push(chart);
}

// ---- panels --------------------------------------------------------------

function panel(titleText, subText) {
  const p = el("div", "panel");
  if (titleText) p.append(el("h3", null, titleText));
  if (subText) p.append(el("p", "psub", subText));
  return p;
}

function chip(text, accent) { return el("span", accent ? "chip accent" : "chip", text); }

// ---- renderers -----------------------------------------------------------

function renderContext(scope) {
  const host = document.querySelector("[data-profile]");
  setSection("profile", scope !== "all");
  if (scope === "all") return;
  host.replaceChildren();

  const meta = el("div", "p-meta");
  const chips = el("div", "chips");

  if (scope === "platform") {
    const platform = state.platformFilter;
    const resources = state.resources.filter((r) => state.resourcePlatform.get(r.id) === platform);
    const rids = new Set(resources.map((r) => r.id));
    const releases = state.releases.filter((r) => rids.has(r.resourceID)).length;
    // One handle per platform today, but sum anyway so a second account doesn't silently vanish.
    const followers = state.accounts.filter((a) => a.platform === platform).reduce((sum, a) => sum + (a.followers ?? 0), 0);
    host.append(el("div", "p-title", platformLabel(platform)));
    chips.append(chip(`${whole.format(followers)} followers`, true), chip(`${resources.length} resources`), chip(`${releases} releases`));
  } else {
    const resource = state.resources.find((r) => r.id === state.resourceFilter);
    const releases = state.releases.filter((r) => r.resourceID === resource?.id).length;
    host.append(el("div", "p-title", resource?.name ?? "Resource"));
    chips.append(chip(titleCase(resource?.type ?? ""), true), chip(platformLabel(state.resourcePlatform.get(resource?.id) ?? "")), chip(`${releases} releases`));
  }
  meta.append(chips);
  host.append(meta);
}

function renderKPIs(byType, showAll) {
  const host = document.querySelector("[data-kpis]");
  host.replaceChildren();

  let entries = [...byType.entries()]
    .map(([type, metrics]) => ({ type, latest: latestByResource(metrics) }))
    .filter((x) => x.latest.size);
  entries.sort((a, b) =>
    [...b.latest.values()].reduce((sum, x) => sum + x.v, 0) -
    [...a.latest.values()].reduce((sum, x) => sum + x.v, 0));
  if (!showAll) entries = entries.slice(0, 4);

  for (const { type, latest } of entries) {
    const total = [...latest.values()].reduce((sum, x) => sum + x.v, 0);
    const resourceLabel = latest.size === 1 ? "resource" : "resources";
    const card = el("div", "panel kpi");
    card.append(
      el("div", "k-label", titleCase(type)),
      el("div", "k-value", compact.format(total)),
      el("div", "k-context", `Current total across ${latest.size} ${resourceLabel}`),
    );
    host.append(card);
  }
}

function renderDistributions(scope) {
  const host = document.querySelector("[data-distributions]");
  setSection("distributions", scope !== "resource");
  if (scope === "resource") return;
  host.replaceChildren();

  // Resources by type (scoped).
  const resources = scope === "platform"
    ? state.resources.filter((r) => state.resourcePlatform.get(r.id) === state.platformFilter)
    : state.resources;
  const typeCounts = RESOURCE_ORDER.map((t) => resources.filter((r) => r.type === t).length);
  const typeLabels = RESOURCE_ORDER.filter((_, i) => typeCounts[i] > 0).map(titleCase);
  const typeValues = typeCounts.filter((c) => c > 0);
  const typeColors = RESOURCE_ORDER.map((_, i) => paletteFor(i)).filter((_, i) => typeCounts[i] > 0);
  const typePanel = panel("Resources by type");
  const typeMount = el("div", "chart");
  typePanel.append(typeMount); host.append(typePanel);
  mount(typeMount, donutOptions(typeLabels, typeValues, typeColors));

  // Resources by platform (only meaningful across all platforms). Counting accounts here would
  // just show a flat 1-per-platform, so this counts what actually differs: the resources.
  if (scope === "all") {
    const counts = PLATFORM_ORDER.map((p) => state.resources.filter((r) => state.resourcePlatform.get(r.id) === p).length);
    const labels = PLATFORM_ORDER.filter((_, i) => counts[i] > 0).map(platformLabel);
    const values = counts.filter((c) => c > 0);
    const colors = PLATFORM_ORDER.map((_, i) => paletteFor(i)).filter((_, i) => counts[i] > 0);
    const p = panel("Resources by platform");
    const m = el("div", "chart");
    p.append(m); host.append(p);
    mount(m, donutOptions(labels, values, colors));
  }
}

function renderCurrentReach(byType, scope) {
  const host = document.querySelector("[data-charts]");
  host.replaceChildren();
  document.querySelector("[data-charts-title]").textContent =
    scope === "resource" ? "Current metrics" : scope === "platform" ? "Current reach · this platform" : "Current reach · all resources";

  if (byType.size === 0) {
    host.append(el("div", "empty", "No metrics are available for this selection."));
    return;
  }

  const ordered = [...byType.entries()].sort((a, b) => totalLatest(b[1]) - totalLatest(a[1]));

  for (const [type, metrics] of ordered) {
    const latest = latestByResource(metrics);
    const rows = [...latest.entries()]
      .map(([rid, x]) => ({ rid, name: state.resourceNames.get(rid) ?? "?", value: x.v }))
      .sort((a, b) => a.value - b.value)
      .slice(-8);
    const total = [...latest.values()].reduce((sum, x) => sum + x.v, 0);
    const coverage = latest.size === 1 ? "1 resource" : `${latest.size} resources`;
    const shown = latest.size > rows.length ? ` · top ${rows.length} shown` : "";
    const p = panel(titleCase(type), `${whole.format(total)} total · ${coverage}${shown}`);
    const m = el("div", "chart");
    p.append(m); host.append(p);
    mount(m, barOptions(
      rows.map((r) => r.name),
      rows.map((r) => r.value),
      // Rank colors within each metric so every visible leader gets a distinct hue.
      // Rows are ascending for horizontal bars, so the largest receives palette color 0.
      rows.map((_, i) => paletteFor(rows.length - 1 - i)),
    ));
  }
}

function renderReleases(scope) {
  const host = document.querySelector("[data-releases]");
  setSection("releases", scope !== "all");
  if (scope === "all") return;
  host.replaceChildren();

  let list;
  if (scope === "resource") {
    list = state.releases.filter((r) => r.resourceID === state.resourceFilter);
  } else {
    const rids = new Set(state.resources.filter((r) => state.resourcePlatform.get(r.id) === state.platformFilter).map((r) => r.id));
    list = state.releases.filter((r) => rids.has(r.resourceID));
  }
  list = list.filter((r) => r.releasedAt).sort((a, b) => new Date(b.releasedAt) - new Date(a.releasedAt));

  if (!list.length) { host.append(el("div", "empty", "No releases.")); return; }

  for (const r of list) {
    const row = el("div", "release-row");
    const left = el("div");
    left.append(el("span", "rv", r.version));
    if (scope === "platform") left.append(el("span", "rd", `  ·  ${state.resourceNames.get(r.resourceID) ?? ""}`));
    row.append(left, el("span", "rd", dateFmt.format(new Date(r.releasedAt))));
    host.append(row);
  }
}

function render() {
  charts.forEach((c) => c.destroy());
  charts = [];
  const scope = currentScope();
  const byType = metricsByType(scopedMetrics());

  renderContext(scope);
  renderKPIs(byType, scope === "resource");
  renderDistributions(scope);
  renderCurrentReach(byType, scope);
  renderReleases(scope);

  // Belt-and-suspenders: nudge ApexCharts to remeasure once layout settles.
  requestAnimationFrame(() => window.dispatchEvent(new Event("resize")));
}

// ---- bootstrap -----------------------------------------------------------

function buildIndex() {
  state.resourceNames = new Map(state.resources.map((r) => [r.id, r.name]));
  const accountPlatform = new Map(state.accounts.map((a) => [a.id, a.platform]));
  state.resourcePlatform = new Map(state.resources.map((r) => [r.id, accountPlatform.get(r.accountID)]));

  // Platforms that actually have an account, in the canonical order, with any unknown ones last.
  const present = new Set(state.accounts.map((a) => a.platform).filter(Boolean));
  state.platforms = [
    ...PLATFORM_ORDER.filter((p) => present.has(p)),
    ...[...present].filter((p) => !PLATFORM_ORDER.includes(p)).sort(),
  ];

}

function optionEl(value, label) {
  const o = document.createElement("option");
  o.value = value; o.textContent = label;
  return o;
}

function syncFilters() {
  const platformSel = document.querySelector("[data-platform]");
  platformSel.replaceChildren(optionEl("all", "All platforms"));
  state.platforms.forEach((p) => platformSel.append(optionEl(p, platformLabel(p))));
  if (state.platformFilter !== "all" && !state.platforms.includes(state.platformFilter)) state.platformFilter = "all";
  platformSel.value = state.platformFilter;

  const resourceSel = document.querySelector("[data-resource]");
  resourceSel.replaceChildren(optionEl("all", "All resources"));
  const list = state.resources
    .filter((r) => state.platformFilter === "all" || state.resourcePlatform.get(r.id) === state.platformFilter)
    .sort((a, b) => (a.name ?? "").localeCompare(b.name ?? ""));
  list.forEach((r) => resourceSel.append(optionEl(r.id, r.name)));
  if (state.resourceFilter !== "all" && !list.some((r) => r.id === state.resourceFilter)) state.resourceFilter = "all";
  resourceSel.value = state.resourceFilter;
}

function renderMasthead() {
  const platforms = new Set(state.resources.map((r) => state.resourcePlatform.get(r.id)).filter(Boolean)).size;
  document.querySelector("[data-summary]").textContent =
    `${platforms} platforms · ${state.resources.length} resources · ${state.metrics.length.toLocaleString()} readings · ${state.releases.length} releases`;
  const latest = state.metrics.reduce((max, m) => {
    const time = new Date(m.recordedAt).getTime();
    return Number.isFinite(time) && time > max ? time : max;
  }, -Infinity);
  document.querySelector("[data-snapshot-date]").textContent =
    Number.isFinite(latest) ? `Snapshot · ${dateFmt.format(new Date(latest))}` : "Current snapshot";
}

function wireControls() {
  document.querySelector("[data-platform]").addEventListener("change", (e) => {
    state.platformFilter = e.target.value;
    state.resourceFilter = "all";
    syncFilters();
    render();
  });
  document.querySelector("[data-resource]").addEventListener("change", (e) => {
    state.resourceFilter = e.target.value;
    render();
  });

  document.querySelector("[data-theme-toggle]").addEventListener("click", () => {
    const next = isDark() ? "light" : "dark";
    document.documentElement.setAttribute("data-theme", next);
    localStorage.setItem("insights-theme", next);
    render();
  });

  const refresh = document.querySelector("[data-refresh]");
  refresh.addEventListener("click", async () => {
    refresh.disabled = true;
    try { await loadData(); syncFilters(); renderMasthead(); render(); }
    finally { refresh.disabled = false; }
  });
}

async function loadData() {
  const [accounts, resources, metrics, releases] = await Promise.all([
    fetch("/accounts").then((r) => r.json()),
    fetch("/resources").then((r) => r.json()),
    fetch("/metrics").then((r) => r.json()),
    fetch("/releases").then((r) => r.json()),
  ]);
  state.accounts = accounts;
  state.resources = resources;
  state.metrics = metrics;
  state.releases = releases;
  buildIndex();
}

async function boot() {
  const saved = localStorage.getItem("insights-theme");
  document.documentElement.setAttribute("data-theme", saved ?? (window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"));

  wireControls();
  await loadData();
  syncFilters();
  renderMasthead();
  render();
}

boot();
