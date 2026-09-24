import type { MetricType, Platform, ResourceType } from '$lib/api/types';
import type { MetricKind } from '$lib/format';

/**
 * The view models every screen renders. Shaped exactly like the server's `/api/insights/*`
 * responses, so a screen never knows whether the numbers came from there or were computed in the
 * browser from today's endpoints (see `source.ts`).
 */

/** One day's value. `t` is an ISO date (`2026-09-24`), UTC. */
export interface Point {
	t: string;
	v: number;
}

export interface Tile {
	type: MetricType;
	kind: MetricKind;
	/** Sum over the resources in scope of each one's newest reading. */
	current: number;
	/** The same sum as of the first day of the range; null when nothing had been read by then. */
	atStart: number | null;
	/** Daily totals across the range, carried forward per resource. Empty when there's no history. */
	series: Point[];
}

export interface Summary {
	generatedAt: string;
	from: string;
	to: string;
	tiles: Tile[];
}

export interface SeriesGroup {
	/** `all`, or a platform when grouped by platform. */
	key: string;
	points: Point[];
}

export interface Series {
	type: MetricType;
	bucket: 'day' | 'week';
	groups: SeriesGroup[];
}

export interface ResourceRow {
	id: string;
	name: string;
	kind: ResourceType;
	platform: Platform | null;
	account: string | null;
	lastCollectedAt: string | null;
	latest: Partial<Record<MetricType, number>>;
	atStart: Partial<Record<MetricType, number>>;
	/** The sort metric's daily totals for this resource. */
	spark: Point[];
}

export interface ResourcePage {
	total: number;
	rows: ResourceRow[];
}

/** What the filters admit. `from` and `to` are ISO dates, inclusive. */
export interface Scope {
	from: string;
	to: string;
	platform: Platform | null;
	resourceID: string | null;
}

export interface ResourceQuery {
	sort: MetricType;
	order: 'asc' | 'desc';
	kind?: ResourceType | null;
	limit: number;
	offset: number;
}
