// ICICLE Insights dashboard. Client-rendered from the JSON API (/accounts /resources
// /metrics /releases). One filter bar (range · account · resource) scopes everything below
// it into three views: All accounts → Account → Resource. Chart form is chosen by the data's
// job; series colors follow the resource entity from the validated CVD-safe palette.

const CATEGORICAL = {
  light: ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#4a3aa7", "#e34948"],
  dark: ["#3987e5", "#d95926", "#199e70", "#c98500", "#d55181", "#008300", "#9085e9", "#e66767"],
};
const OTHER = "#898781";
const PLATFORM_LABEL = { github: "GitHub", huggingface: "Hugging Face", npm: "npm", pypi: "PyPI" };
const PLATFORM_ORDER = ["github", "huggingface", "npm", "pypi"];
const RESOURCE_ORDER = ["dataset", "image", "model", "package", "repository", "service"];

const compact = new Intl.NumberFormat("en", { notation: "compact", maximumFractionDigits: 1 });
const whole = new Intl.NumberFormat("en");
const dateFmt = new Intl.DateTimeFormat("en", { year: "numeric", month: "short", day: "numeric" });

const state = {
  accounts: [], resources: [], metrics: [], releases: [],
  rangeDays: 90, accountFilter: "all", resourceFilter: "all",
};
let charts = [];

// ---- theme ---------------------------------------------------------------

const isDark = () => document.documentElement.getAttribute("data-theme") === "dark";
const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
const ramp = () => (isDark() ? CATEGORICAL.dark : CATEGORICAL.light);
const paletteFor = (i) => (i < ramp().length ? ramp()[i] : OTHER);
const colorForResource = (rid) => paletteFor(state.resourceRank.get(rid) ?? 99);

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
  if (state.accountFilter !== "all") return "account";
  return "all";
}

function setSection(name, visible) {
  const s = document.querySelector(`[data-section="${name}"]`);
  if (s) s.hidden = !visible;
}

function windowStartMs() {
  if (state.rangeDays === "all") return -Infinity;
  return Date.now() - state.rangeDays * 24 * 3600 * 1000;
}

function scopedMetrics() {
  const min = windowStartMs();
  return state.metrics.filter((m) => {
    if (new Date(m.recordedAt).getTime() < min) return false;
    if (state.resourceFilter !== "all") return m.resourceID === state.resourceFilter;
    if (state.accountFilter !== "all") return state.resourceAccount.get(m.resourceID) === state.accountFilter;
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

function aggregate(metrics) {
  const byTime = new Map();
  for (const m of metrics) byTime.set(new Date(m.recordedAt).getTime(), (byTime.get(new Date(m.recordedAt).getTime()) ?? 0) + m.reading);
  return [...byTime.entries()].sort((a, b) => a[0] - b[0]);
}
const aggregateLast = (metrics) => { const a = aggregate(metrics); return a.length ? a[a.length - 1][1] : 0; };

function latestByResource(metrics) {
  const best = new Map();
  for (const m of metrics) {
    const t = new Date(m.recordedAt).getTime();
    const cur = best.get(m.resourceID);
    if (!cur || t > cur.t) best.set(m.resourceID, { t, v: m.reading });
  }
  return best;
}

// One line per resource, ranked by this metric's own latest value; keep the top 8 (each a
// distinct hue) and drop the small tail. Ranking per-chart (not by global totals) keeps every
// metric legible — a star-heavy repo leads the Stars chart even if it has no downloads — and
// avoids a summed "Other" line blowing out the y-scale.
const TREND_CAP = 8;
function trendSeries(metrics) {
  const byResource = new Map();
  for (const m of metrics) {
    if (!byResource.has(m.resourceID)) byResource.set(m.resourceID, []);
    byResource.get(m.resourceID).push([new Date(m.recordedAt).getTime(), m.reading]);
  }
  const all = [];
  for (const [rid, data] of byResource) {
    data.sort((a, b) => a[0] - b[0]);
    all.push({ name: state.resourceNames.get(rid) ?? "?", data, last: data.length ? data[data.length - 1][1] : 0 });
  }
  all.sort((a, b) => b.last - a.last);
  const series = all.slice(0, TREND_CAP);
  series.forEach((s, i) => { s.color = paletteFor(i); });
  return { series, total: all.length };
}

// ---- ApexCharts option builders -----------------------------------------

function trendOptions(series, colors, annotations) {
  const single = series.length === 1;
  return {
    chart: {
      type: single ? "area" : "line", height: 300, fontFamily: "inherit",
      foreColor: css("--chart-text"), background: "transparent",
      toolbar: { show: true, tools: { download: false, selection: false, pan: false, zoom: true, zoomin: true, zoomout: true, reset: true } },
      animations: { enabled: true, speed: 350 },
    },
    colors, series,
    stroke: { width: 2, curve: "smooth", lineCap: "round" },
    // Only area charts get a fill. A zero-opacity fill on a `line` chart hides the stroke too
    // (ApexCharts applies fill opacity to the line), so lines omit `fill` entirely.
    fill: single ? { type: "gradient", gradient: { opacityFrom: 0.2, opacityTo: 0.02 } } : { type: "solid", opacity: 1 },
    markers: { size: 0, hover: { size: 5 } },
    dataLabels: { enabled: false },
    grid: { borderColor: css("--chart-grid"), strokeDashArray: 0, xaxis: { lines: { show: false } }, padding: { left: 8, right: 12 } },
    xaxis: {
      type: "datetime", axisBorder: { color: css("--chart-baseline") }, axisTicks: { color: css("--chart-baseline") },
      labels: { style: { colors: css("--chart-muted") }, datetimeUTC: false }, tooltip: { enabled: false },
    },
    yaxis: { labels: { style: { colors: css("--chart-muted") }, formatter: (v) => compact.format(v) } },
    legend: { show: series.length > 1, position: "bottom", horizontalAlign: "left", markers: { width: 10, height: 10, radius: 6 }, labels: { colors: css("--chart-text") }, itemMargin: { horizontal: 10, vertical: 4 } },
    tooltip: { shared: true, intersect: false, theme: isDark() ? "dark" : "light", x: { format: "dd MMM yyyy" }, y: { formatter: (v) => whole.format(v) } },
    annotations: { xaxis: annotations ?? [] },
  };
}

function sparkOptions(data, color) {
  return {
    chart: { type: "area", height: 42, sparkline: { enabled: true }, animations: { enabled: false } },
    series: [{ name: "", data }], colors: [color],
    stroke: { width: 1.5, curve: "smooth" }, fill: { type: "gradient", gradient: { opacityFrom: 0.35, opacityTo: 0 } },
    tooltip: { enabled: false },
  };
}

function donutOptions(labels, values, colors) {
  const total = values.reduce((a, b) => a + b, 0);
  return {
    chart: { type: "donut", height: 250, fontFamily: "inherit", foreColor: css("--chart-text"), background: "transparent" },
    labels, series: values, colors,
    stroke: { width: 2, colors: [css("--chart-surface")] },
    dataLabels: { enabled: true, formatter: (_v, o) => whole.format(o.w.globals.series[o.seriesIndex]), style: { fontSize: "11px" }, dropShadow: { enabled: false } },
    plotOptions: { pie: { donut: { size: "64%", labels: { show: true, total: { show: true, label: "Total", color: css("--chart-muted"), formatter: () => whole.format(total) } } } } },
    legend: { position: "bottom", labels: { colors: css("--chart-text") }, markers: { width: 10, height: 10, radius: 6 } },
    tooltip: { theme: isDark() ? "dark" : "light", y: { formatter: (v) => whole.format(v) } },
  };
}

function barOptions(categories, values) {
  return {
    chart: { type: "bar", height: Math.max(190, categories.length * 32 + 60), fontFamily: "inherit", foreColor: css("--chart-text"), background: "transparent", toolbar: { show: false } },
    series: [{ name: "Total", data: values }], colors: [css("--accent")],
    plotOptions: { bar: { horizontal: true, borderRadius: 4, borderRadiusApplication: "end", barHeight: "62%" } },
    dataLabels: { enabled: true, formatter: (v) => compact.format(v), textAnchor: "start", offsetX: 4, style: { colors: [css("--chart-text")], fontWeight: 500 } },
    xaxis: { categories, labels: { style: { colors: css("--chart-muted") }, formatter: (v) => compact.format(v) }, axisBorder: { show: false }, axisTicks: { show: false } },
    yaxis: { labels: { style: { colors: css("--chart-text") } } },
    grid: { borderColor: css("--chart-grid"), xaxis: { lines: { show: true } }, yaxis: { lines: { show: false } } },
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

  if (scope === "account") {
    const account = state.accounts.find((a) => a.id === state.accountFilter);
    const resources = state.resources.filter((r) => r.accountID === account.id);
    const rids = new Set(resources.map((r) => r.id));
    const releases = state.releases.filter((r) => rids.has(r.resourceID)).length;
    host.append(el("div", "p-title", account?.name ?? "Account"));
    chips.append(chip(platformLabel(account?.platform), true), chip(`${whole.format(account?.followers ?? 0)} followers`), chip(`${resources.length} resources`), chip(`${releases} releases`));
  } else {
    const resource = state.resources.find((r) => r.id === state.resourceFilter);
    const account = state.accounts.find((a) => a.id === resource?.accountID);
    const releases = state.releases.filter((r) => r.resourceID === resource?.id).length;
    host.append(el("div", "p-title", resource?.name ?? "Resource"));
    chips.append(chip(titleCase(resource?.type ?? ""), true), chip(account?.name ?? "", false), chip(platformLabel(account?.platform)), chip(`${releases} releases`));
  }
  meta.append(chips);
  host.append(meta);
}

function renderKPIs(byType, showAll) {
  const host = document.querySelector("[data-kpis]");
  host.replaceChildren();

  let entries = [...byType.entries()]
    .map(([type, metrics]) => ({ type, agg: aggregate(metrics) }))
    .filter((x) => x.agg.length);
  entries.sort((a, b) => b.agg[b.agg.length - 1][1] - a.agg[a.agg.length - 1][1]);
  if (!showAll) entries = entries.slice(0, 4);

  for (const { type, agg } of entries) {
    const first = agg[0][1], last = agg[agg.length - 1][1];
    const pct = first > 0 ? ((last - first) / first) * 100 : 0;
    const dir = pct > 0.05 ? "up" : pct < -0.05 ? "down" : "flat";

    const card = el("div", "panel kpi");
    card.append(
      el("div", "k-label", titleCase(type)),
      el("div", "k-value", compact.format(last)),
      el("div", `k-delta ${dir}`, `${pct > 0 ? "+" : ""}${pct.toFixed(1)}% vs range start`),
    );
    const spark = el("div", "k-spark");
    card.append(spark);
    host.append(card);
    mount(spark, sparkOptions(agg, paletteFor(0)));
  }
}

function renderDistributions(scope) {
  const host = document.querySelector("[data-distributions]");
  setSection("distributions", scope !== "resource");
  if (scope === "resource") return;
  host.replaceChildren();

  // Resources by type (scoped).
  const resources = scope === "account"
    ? state.resources.filter((r) => r.accountID === state.accountFilter)
    : state.resources;
  const typeCounts = RESOURCE_ORDER.map((t) => resources.filter((r) => r.type === t).length);
  const typeLabels = RESOURCE_ORDER.filter((_, i) => typeCounts[i] > 0).map(titleCase);
  const typeValues = typeCounts.filter((c) => c > 0);
  const typeColors = RESOURCE_ORDER.map((_, i) => paletteFor(i)).filter((_, i) => typeCounts[i] > 0);
  const typePanel = panel("Resources by type");
  const typeMount = el("div", "chart");
  typePanel.append(typeMount); host.append(typePanel);
  mount(typeMount, donutOptions(typeLabels, typeValues, typeColors));

  // Accounts by platform (only meaningful across all accounts).
  if (scope === "all") {
    const counts = PLATFORM_ORDER.map((p) => state.accounts.filter((a) => a.platform === p).length);
    const labels = PLATFORM_ORDER.filter((_, i) => counts[i] > 0).map(platformLabel);
    const values = counts.filter((c) => c > 0);
    const colors = PLATFORM_ORDER.map((_, i) => paletteFor(i)).filter((_, i) => counts[i] > 0);
    const p = panel("Accounts by platform");
    const m = el("div", "chart");
    p.append(m); host.append(p);
    mount(m, donutOptions(labels, values, colors));
  }
}

function renderLeaders(byType, scope) {
  const host = document.querySelector("[data-leaders]");
  setSection("leaders", scope !== "resource");
  if (scope === "resource") return;
  host.replaceChildren();

  // Readings by metric type (magnitude → bar, one hue).
  const typeEntries = [...byType.entries()].map(([type, m]) => [titleCase(type), aggregateLast(m)]).sort((a, b) => a[1] - b[1]);
  if (typeEntries.length) {
    const p = panel("Readings by metric type", "latest totals in range");
    const m = el("div", "chart");
    p.append(m); host.append(p);
    mount(m, barOptions(typeEntries.map((e) => e[0]), typeEntries.map((e) => e[1])));
  }

  // Top resources by the dominant metric type.
  const dominant = [...byType.entries()].sort((a, b) => aggregateLast(b[1]) - aggregateLast(a[1]))[0];
  if (dominant) {
    const [type, metrics] = dominant;
    const latest = latestByResource(metrics);
    const rows = [...latest.entries()]
      .map(([rid, x]) => [state.resourceNames.get(rid) ?? "?", x.v])
      .sort((a, b) => a[1] - b[1]).slice(-8);
    const p = panel(`Top resources by ${type}`, "latest reading");
    const m = el("div", "chart");
    p.append(m); host.append(p);
    mount(m, barOptions(rows.map((r) => r[0]), rows.map((r) => r[1])));
  }
}

function releaseAnnotations() {
  if (state.resourceFilter === "all") return [];
  const min = windowStartMs();
  return state.releases
    .filter((r) => r.resourceID === state.resourceFilter && r.releasedAt && new Date(r.releasedAt).getTime() >= min)
    .map((r) => ({
      x: new Date(r.releasedAt).getTime(),
      borderColor: css("--chart-muted"),
      strokeDashArray: 4,
      label: { text: r.version, orientation: "horizontal", position: "top", style: { fontSize: "10px", color: css("--chart-text"), background: css("--chart-surface"), fontFamily: "inherit" } },
    }));
}

function renderTrends(byType, scope) {
  const host = document.querySelector("[data-charts]");
  host.replaceChildren();
  document.querySelector("[data-charts-title]").textContent =
    scope === "resource" ? "Metrics over time" : scope === "account" ? "Metrics over time · this account" : "Metrics over time · all resources";

  if (byType.size === 0) {
    host.append(el("div", "empty", "No metrics in this range. Reseed the dev database with `just migrate`."));
    return;
  }

  const annotations = releaseAnnotations();
  const ordered = [...byType.entries()].sort((a, b) => aggregateLast(b[1]) - aggregateLast(a[1]));

  for (const [type, metrics] of ordered) {
    const { series, total } = trendSeries(metrics);
    const colors = series.map((s) => s.color);
    const sub = series.length > 1
      ? (total > series.length ? `top ${series.length} of ${total} resources` : `${series.length} resources`)
      : series[0].name;

    const p = panel(`${titleCase(type)} over time`, sub);
    const m = el("div", "chart");
    p.append(m); host.append(p);
    mount(m, trendOptions(series.map((s) => ({ name: s.name, data: s.data })), colors, annotations));
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
    const rids = new Set(state.resources.filter((r) => r.accountID === state.accountFilter).map((r) => r.id));
    list = state.releases.filter((r) => rids.has(r.resourceID));
  }
  list = list.filter((r) => r.releasedAt).sort((a, b) => new Date(b.releasedAt) - new Date(a.releasedAt));

  if (!list.length) { host.append(el("div", "empty", "No releases.")); return; }

  for (const r of list) {
    const row = el("div", "release-row");
    const left = el("div");
    left.append(el("span", "rv", r.version));
    if (scope === "account") left.append(el("span", "rd", `  ·  ${state.resourceNames.get(r.resourceID) ?? ""}`));
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
  renderLeaders(byType, scope);
  renderTrends(byType, scope);
  renderReleases(scope);

  // Belt-and-suspenders: nudge ApexCharts to remeasure once layout settles.
  requestAnimationFrame(() => window.dispatchEvent(new Event("resize")));
}

// ---- bootstrap -----------------------------------------------------------

function buildIndex() {
  state.resourceNames = new Map(state.resources.map((r) => [r.id, r.name]));
  state.resourceAccount = new Map(state.resources.map((r) => [r.id, r.accountID]));

  // Global popularity (total readings per resource) → stable color rank; top 8 get hues.
  const totals = new Map();
  for (const m of state.metrics) totals.set(m.resourceID, (totals.get(m.resourceID) ?? 0) + m.reading);
  const rank = new Map();
  [...state.resources]
    .sort((a, b) => (totals.get(b.id) ?? 0) - (totals.get(a.id) ?? 0))
    .forEach((r, i) => rank.set(r.id, i));
  state.resourceRank = rank;
}

function optionEl(value, label) {
  const o = document.createElement("option");
  o.value = value; o.textContent = label;
  return o;
}

function syncFilters() {
  const accountSel = document.querySelector("[data-account]");
  accountSel.replaceChildren(optionEl("all", "All accounts"));
  [...state.accounts].sort((a, b) => (a.name ?? "").localeCompare(b.name ?? "")).forEach((a) => accountSel.append(optionEl(a.id, a.name)));
  accountSel.value = state.accountFilter;

  const resourceSel = document.querySelector("[data-resource]");
  resourceSel.replaceChildren(optionEl("all", "All resources"));
  const list = state.resources
    .filter((r) => state.accountFilter === "all" || r.accountID === state.accountFilter)
    .sort((a, b) => (a.name ?? "").localeCompare(b.name ?? ""));
  list.forEach((r) => resourceSel.append(optionEl(r.id, r.name)));
  if (state.resourceFilter !== "all" && !list.some((r) => r.id === state.resourceFilter)) state.resourceFilter = "all";
  resourceSel.value = state.resourceFilter;
}

function renderMasthead() {
  const accounts = new Set(state.resources.map((r) => r.accountID)).size;
  document.querySelector("[data-summary]").textContent =
    `${accounts} accounts · ${state.resources.length} resources · ${state.metrics.length.toLocaleString()} readings · ${state.releases.length} releases`;
}

function wireControls() {
  document.querySelectorAll("[data-range]").forEach((btn) => {
    btn.addEventListener("click", () => {
      state.rangeDays = btn.getAttribute("data-range") === "all" ? "all" : Number(btn.getAttribute("data-range"));
      document.querySelectorAll("[data-range]").forEach((b) => b.classList.toggle("seg-active", b === btn));
      render();
    });
  });

  document.querySelector("[data-account]").addEventListener("change", (e) => {
    state.accountFilter = e.target.value;
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
