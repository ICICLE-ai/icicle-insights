import { goto } from '$app/navigation';
import { page } from '$app/state';
import type { Platform } from '$lib/api/types';
import { isoDay } from '$lib/data/daily';
import type { Scope } from '$lib/data/types';
import { PLATFORMS } from '$lib/format';

/**
 * The filters, kept in the URL rather than in memory.
 *
 * A dashboard view people want to share ("GitHub, last 90 days") is then just a link, the back
 * button undoes a filter change, and a reload lands on the same view. Every screen reads the scope
 * from here, so all of them agree on what is being shown.
 */

export const RANGES = [
	{ id: '30d', label: '30 days', days: 30 },
	{ id: '90d', label: '90 days', days: 90 },
	{ id: '6m', label: '6 months', days: 182 },
	{ id: '1y', label: '1 year', days: 365 }
] as const;

export type RangeID = (typeof RANGES)[number]['id'];

const DEFAULT_RANGE: RangeID = '90d';

export function rangeID(): RangeID {
	const value = page.url.searchParams.get('range');
	return RANGES.some((range) => range.id === value) ? (value as RangeID) : DEFAULT_RANGE;
}

export function rangeLabel(): string {
	return RANGES.find((range) => range.id === rangeID())!.label;
}

export function platformParam(): Platform | null {
	const value = page.url.searchParams.get('platform');
	return value && value in PLATFORMS ? (value as Platform) : null;
}

/** The scope for data calls. A resource page passes its own id; other pages leave it null. */
export function scope(resourceID: string | null = null): Scope {
	const days = RANGES.find((range) => range.id === rangeID())!.days;
	const to = isoDay(Date.now());
	const from = isoDay(Date.now() - (days - 1) * 86_400_000);
	return { from, to, platform: resourceID ? null : platformParam(), resourceID };
}

/** Longer ranges plot weekly points; a year of daily points is noise at chart width. */
export function bucketFor(scope: Scope): 'day' | 'week' {
	const days = (Date.parse(scope.to) - Date.parse(scope.from)) / 86_400_000 + 1;
	return days > 120 ? 'week' : 'day';
}

/** Sets or clears query parameters on the current page without adding a scroll jump. */
export function setParams(values: Record<string, string | null>): Promise<void> {
	const url = new URL(page.url);
	for (const [key, value] of Object.entries(values)) {
		if (value === null || value === '') url.searchParams.delete(key);
		else url.searchParams.set(key, value);
	}
	if (url.searchParams.get('range') === DEFAULT_RANGE) url.searchParams.delete('range');
	return goto(url, { replaceState: true, keepFocus: true, noScroll: true });
}

/** The current query string, for links between pages that should keep the filters. */
export function withScope(path: string, keep: string[] = ['range', 'platform']): string {
	const params = new URLSearchParams();
	for (const key of keep) {
		const value = page.url.searchParams.get(key);
		if (value) params.set(key, value);
	}
	const query = params.toString();
	return query ? `${path}?${query}` : path;
}
