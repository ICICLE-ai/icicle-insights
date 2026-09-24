import type { MetricType, Platform, ResourceType } from '$lib/api/types';

/**
 * How a metric's reading relates to time — which decides what "change" and "trend" can honestly
 * mean for it.
 *
 * - `gauge`: the platform reports the whole figure every time (stars, forks). Sum the newest
 *   reading per resource; a trend is that sum over time.
 * - `window`: a rolling window (views over 14 days). Same arithmetic as a gauge, but the number
 *   describes recent activity, not accumulation, so the label always names the window.
 * - `lifetime`: an all-time total the server maintains. Its row is updated in place, so until the
 *   server keeps daily snapshots (`/api/insights/*`) it has a current value and no history.
 */
export type MetricKind = 'gauge' | 'window' | 'lifetime';

interface MetricInfo {
	label: string;
	short: string;
	kind: MetricKind;
	/** Sentence fragment describing the window, for `window` metrics. */
	window?: string;
}

export const METRICS: Record<MetricType, MetricInfo> = {
	stars: { label: 'Stars', short: 'Stars', kind: 'gauge' },
	forks: { label: 'Forks', short: 'Forks', kind: 'gauge' },
	subscribers: { label: 'Watchers', short: 'Watchers', kind: 'gauge' },
	likes: { label: 'Likes', short: 'Likes', kind: 'gauge' },
	deployments: { label: 'Deployments', short: 'Deployments', kind: 'gauge' },
	views: { label: 'Views · 14 days', short: 'Views', kind: 'window', window: 'a rolling 14 days' },
	clones: {
		label: 'Clones · 14 days',
		short: 'Clones',
		kind: 'window',
		window: 'a rolling 14 days'
	},
	downloads: {
		label: 'Downloads · 30 days',
		short: 'Downloads',
		kind: 'window',
		window: 'a trailing 30 days'
	},
	pulls: { label: 'Pulls', short: 'Pulls', kind: 'window' },
	authentications: { label: 'Authentications', short: 'Authentications', kind: 'window' },
	viewsAllTime: { label: 'Views · all time', short: 'Views', kind: 'lifetime' },
	clonesAllTime: { label: 'Clones · all time', short: 'Clones', kind: 'lifetime' },
	downloadsAllTime: { label: 'Downloads · all time', short: 'Downloads', kind: 'lifetime' },
	pullsAllTime: { label: 'Pulls · all time', short: 'Pulls', kind: 'lifetime' },
	authenticationsAllTime: {
		label: 'Authentications · all time',
		short: 'Authentications',
		kind: 'lifetime'
	}
};

/** Display order: what people look for first. Also the closed list the legacy fan-out fetches. */
export const METRIC_ORDER: readonly MetricType[] = [
	'stars',
	'forks',
	'subscribers',
	'views',
	'clones',
	'downloads',
	'likes',
	'deployments',
	'pulls',
	'authentications',
	'viewsAllTime',
	'clonesAllTime',
	'downloadsAllTime',
	'pullsAllTime',
	'authenticationsAllTime'
];

export const metricLabel = (type: string): string => METRICS[type as MetricType]?.label ?? type;
export const metricKind = (type: string): MetricKind =>
	METRICS[type as MetricType]?.kind ?? 'gauge';
export const isMetricType = (value: string | null | undefined): value is MetricType =>
	!!value && value in METRICS;

export const PLATFORMS: Record<Platform, { label: string; slot: number }> = {
	// Slots index the categorical palette in layout.css. They follow the platform, never its rank,
	// so filtering never repaints a line. The three platforms that report time series take the
	// first three slots, which are the ones validated safe together under colour-vision deficiency.
	github: { label: 'GitHub', slot: 1 },
	huggingface: { label: 'Hugging Face', slot: 2 },
	patra: { label: 'Patra', slot: 3 },
	ghcr: { label: 'GHCR', slot: 4 },
	npm: { label: 'npm', slot: 5 },
	pypi: { label: 'PyPI', slot: 6 }
};

export const PLATFORM_ORDER: readonly Platform[] = [
	'github',
	'huggingface',
	'patra',
	'ghcr',
	'npm',
	'pypi'
];

export const platformLabel = (platform: string | null | undefined): string =>
	(platform && PLATFORMS[platform as Platform]?.label) || platform || 'Unknown';

export const platformColor = (platform: string | null | undefined): string => {
	const slot = platform ? PLATFORMS[platform as Platform]?.slot : undefined;
	return slot ? `var(--series-${slot})` : 'var(--muted-foreground)';
};

export const KIND_LABELS: Record<ResourceType, string> = {
	repository: 'Repository',
	container: 'Container',
	package: 'Package',
	dataset: 'Dataset',
	model: 'Model',
	service: 'Service',
	agent: 'Agent'
};

export const kindLabel = (kind: string | null | undefined): string =>
	(kind && KIND_LABELS[kind as ResourceType]) || kind || 'Unknown';

export const kindPlural = (kind: string): string =>
	kind === 'repository' ? 'Repositories' : `${kindLabel(kind)}s`;

const compactFormat = new Intl.NumberFormat('en-US', {
	notation: 'compact',
	maximumFractionDigits: 1
});
const wholeFormat = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 });

/** 1,284 / 12.9K / 4.2M — for tiles, axes and tight table cells. */
export const compact = (value: number | null | undefined): string =>
	value === null || value === undefined || !Number.isFinite(value)
		? '—'
		: Math.abs(value) < 10_000
			? wholeFormat.format(value)
			: compactFormat.format(value);

/** 1,284 — every digit, for tooltips and tables where exactness matters. */
export const whole = (value: number | null | undefined): string =>
	value === null || value === undefined || !Number.isFinite(value)
		? '—'
		: wholeFormat.format(value);

/** Signed change: +12, −3, 0. A true minus sign, so columns line up. */
export const signed = (value: number): string =>
	value > 0 ? `+${compact(value)}` : value < 0 ? `−${compact(-value)}` : '0';

/** Relative change as a percentage, or null when the baseline is zero or missing. */
export function percentChange(current: number, start: number | null): number | null {
	if (start === null || start === 0) return null;
	return ((current - start) / start) * 100;
}

export const formatPercent = (value: number | null): string =>
	value === null
		? ''
		: `${value > 0 ? '+' : value < 0 ? '−' : ''}${Math.abs(value) < 10 ? Math.abs(value).toFixed(1) : Math.round(Math.abs(value))}%`;

const dateFormat = new Intl.DateTimeFormat('en-US', {
	month: 'short',
	day: 'numeric',
	year: 'numeric',
	timeZone: 'UTC'
});
const shortDateFormat = new Intl.DateTimeFormat('en-US', {
	month: 'short',
	day: 'numeric',
	timeZone: 'UTC'
});

/** Accepts an ISO date (`2026-09-24`) or timestamp; renders it in UTC, like the data. */
export const formatDate = (value: string | Date | null | undefined): string => {
	if (!value) return '—';
	const date =
		typeof value === 'string'
			? new Date(value.length === 10 ? `${value}T00:00:00Z` : value)
			: value;
	return Number.isNaN(date.getTime()) ? '—' : dateFormat.format(date);
};

export const formatShortDate = (value: string | Date): string => {
	const date =
		typeof value === 'string'
			? new Date(value.length === 10 ? `${value}T00:00:00Z` : value)
			: value;
	return shortDateFormat.format(date);
};

const relative = new Intl.RelativeTimeFormat('en-US', { numeric: 'auto' });

/** "3 days ago", "in 2 hours". */
export function formatRelative(value: string | Date | null | undefined, now = Date.now()): string {
	if (!value) return '—';
	const time = typeof value === 'string' ? Date.parse(value) : value.getTime();
	if (Number.isNaN(time)) return '—';
	const seconds = (time - now) / 1000;
	const units: [Intl.RelativeTimeFormatUnit, number][] = [
		['year', 31_536_000],
		['month', 2_592_000],
		['week', 604_800],
		['day', 86_400],
		['hour', 3_600],
		['minute', 60]
	];
	for (const [unit, size] of units) {
		if (Math.abs(seconds) >= size) return relative.format(Math.round(seconds / size), unit);
	}
	return 'just now';
}

export const pluralize = (count: number, singular: string, plural = `${singular}s`): string =>
	`${wholeFormat.format(count)} ${count === 1 ? singular : plural}`;
