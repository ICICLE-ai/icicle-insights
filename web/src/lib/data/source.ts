import { api } from '$lib/api/client';
import type { MetricType } from '$lib/api/types';
import { METRIC_ORDER } from '$lib/format';
import type { ResourcePage, ResourceQuery, Scope, Series, Summary } from './types';

/**
 * Where the dashboard's numbers come from: the server's `/api/insights/*`, which totals every
 * reading in SQL over the whole history.
 *
 * The dashboard used to fall back to adding up raw `/api/metrics` pages in the browser when a
 * server predated these endpoints. Every deployment serves them now, and that path was capped at
 * 1,000 readings per metric, so it is gone.
 */
export interface InsightsSource {
	summary(scope: Scope): Promise<Summary>;
	series(
		scope: Scope,
		type: MetricType,
		groupBy: 'none' | 'platform',
		bucket: 'day' | 'week'
	): Promise<Series>;
	resources(scope: Scope, query: ResourceQuery): Promise<ResourcePage>;
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

export const source: InsightsSource = {
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
	}
};
