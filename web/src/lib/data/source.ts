import { api, ApiError } from '$lib/api/client';
import type { MetricType } from '$lib/api/types';
import { METRIC_ORDER } from '$lib/format';
import { legacySource } from './legacy';
import type { ResourcePage, ResourceQuery, Scope, Series, Summary } from './types';

/**
 * Where the dashboard's numbers come from. Two implementations of one contract:
 *
 * - `summary`: the server's `/api/insights/*`, aggregated in SQL over the whole history.
 * - `legacy`: the same shapes computed in the browser from `/api/metrics` (see `legacy.ts`).
 *
 * Screens take an `InsightsSource` and never branch on which one it is, so retiring `legacy` once
 * every deployment serves the summary endpoints is deleting a file, not touching a screen.
 */
export interface InsightsSource {
	readonly name: 'summary' | 'legacy';
	summary(scope: Scope): Promise<Summary>;
	series(
		scope: Scope,
		type: MetricType,
		groupBy: 'none' | 'platform',
		bucket: 'day' | 'week'
	): Promise<Series>;
	resources(scope: Scope, query: ResourceQuery): Promise<ResourcePage>;
	/** Metric types whose history is cut short by the legacy row ceiling. Always empty for `summary`. */
	truncated(): Promise<MetricType[]>;
}

const scopeQuery = (scope: Scope) => ({
	from: scope.from,
	to: scope.to,
	platform: scope.platform,
	resourceID: scope.resourceID
});

// The server orders tiles by type name and uses Swift's uppercase UUIDs; the dashboard shows
// metrics in reading order and keys everything on lowercase ids, so both are normalised here once.
const order = (type: MetricType) => METRIC_ORDER.indexOf(type);

export const summarySource: InsightsSource = {
	name: 'summary',
	summary: async (scope) => {
		const summary = await api<Summary>('/insights/summary', { query: scopeQuery(scope) });
		return { ...summary, tiles: [...summary.tiles].sort((a, b) => order(a.type) - order(b.type)) };
	},
	series: (scope, type, groupBy, bucket) =>
		api<Series>('/insights/series', { query: { ...scopeQuery(scope), type, groupBy, bucket } }),
	resources: async (scope, query) => {
		const page = await api<ResourcePage>('/insights/resources', {
			query: {
				...scopeQuery(scope),
				sort: query.sort,
				order: query.order,
				kind: query.kind,
				limit: query.limit,
				offset: query.offset
			}
		});
		return { ...page, rows: page.rows.map((row) => ({ ...row, id: row.id.toLowerCase() })) };
	},
	truncated: async () => []
};

let detected: Promise<InsightsSource> | null = null;

/**
 * The summary source when the server has it, otherwise legacy. Asked once per visit.
 *
 * A 404 is the only answer that means "this server predates the endpoints". Anything else — a
 * 500, a network error — is a real failure, and falling back would hide it behind numbers
 * computed from a truncated sample; so it surfaces to the page instead.
 */
export function source(): Promise<InsightsSource> {
	if (!detected) {
		const day = new Date().toISOString().slice(0, 10);
		detected = api('/insights/summary', { query: { from: day, to: day } })
			.then(() => summarySource)
			.catch((error: unknown) => {
				if (error instanceof ApiError && error.status === 404) return legacySource;
				detected = null;
				throw error;
			});
	}
	return detected;
}
