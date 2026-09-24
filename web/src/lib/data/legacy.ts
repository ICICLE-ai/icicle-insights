import { api } from '$lib/api/client';
import type { Metric, MetricType } from '$lib/api/types';
import { METRIC_ORDER, metricKind } from '$lib/format';
import { loadCatalog, scopedResourceIDs } from './catalog';
import {
	currentTotal,
	dailyTotals,
	isoDay,
	latestByResource,
	totalAsOf,
	weekly,
	type Reading
} from './daily';
import type { InsightsSource } from './source';
import type {
	ResourcePage,
	ResourceQuery,
	ResourceRow,
	Scope,
	Series,
	Summary,
	Tile
} from './types';

/**
 * Computes the view models in the browser from today's endpoints.
 *
 * Only for as long as the server has no `/api/insights/*`. It inherits the old dashboard's limits:
 * `GET /api/metrics` returns at most 1,000 readings per request, so this fetches one metric type
 * per request and reports any type that hit the ceiling (`truncated`), because its oldest history
 * is then silently missing. And lifetime metrics have no history here at all — the server updates
 * their one row in place — so their tiles show a value with no trend.
 */

const PAGE_LIMIT = 1000;

interface Slice {
	type: MetricType;
	readings: (Reading & { resourceID: string })[];
	truncated: boolean;
}

let pending: Promise<Slice[]> | null = null;

function loadSlices(): Promise<Slice[]> {
	if (!pending) {
		pending = Promise.all(
			METRIC_ORDER.map(async (type): Promise<Slice> => {
				const metrics = await api<Metric[]>('/metrics', { query: { type, limit: PAGE_LIMIT } });
				return {
					type,
					truncated: metrics.length >= PAGE_LIMIT,
					readings: metrics.flatMap((metric) => {
						const time = metric.recordedAt ? Date.parse(metric.recordedAt) : NaN;
						return metric.resourceID && Number.isFinite(metric.reading) && !Number.isNaN(time)
							? [{ resourceID: metric.resourceID.toLowerCase(), time, value: metric.reading! }]
							: [];
					})
				};
			})
		).then((slices) => slices.filter((slice) => slice.readings.length > 0));
		pending.catch(() => (pending = null));
	}
	return pending;
}

async function scoped(scope: Scope): Promise<{ slices: Slice[]; ids: Set<string> }> {
	const [catalog, slices] = await Promise.all([loadCatalog(), loadSlices()]);
	const ids = scopedResourceIDs(catalog, scope);
	return {
		ids,
		slices: slices
			.map((slice) => ({ ...slice, readings: slice.readings.filter((r) => ids.has(r.resourceID)) }))
			.filter((slice) => slice.readings.length > 0)
	};
}

export const legacySource: InsightsSource = {
	name: 'legacy',

	async truncated() {
		return (await loadSlices()).filter((slice) => slice.truncated).map((slice) => slice.type);
	},

	async summary(scope): Promise<Summary> {
		const { slices } = await scoped(scope);
		const tiles: Tile[] = slices.map(({ type, readings }) => {
			const kind = metricKind(type);
			return kind === 'lifetime'
				? { type, kind, current: currentTotal(readings), atStart: null, series: [] }
				: {
						type,
						kind,
						current: currentTotal(readings),
						atStart: totalAsOf(readings, scope.from),
						series: dailyTotals(readings, scope.from, scope.to)
					};
		});
		return { generatedAt: new Date().toISOString(), from: scope.from, to: scope.to, tiles };
	},

	async series(scope, type, groupBy, bucket): Promise<Series> {
		const [{ slices }, catalog] = await Promise.all([scoped(scope), loadCatalog()]);
		const readings = slices.find((slice) => slice.type === type)?.readings ?? [];
		const groups = new Map<string, Reading[]>();
		for (const reading of readings) {
			const key =
				groupBy === 'platform' ? (catalog.platformOf.get(reading.resourceID) ?? 'unknown') : 'all';
			groups.set(key, [...(groups.get(key) ?? []), reading]);
		}
		const bucketed = (points: ReturnType<typeof dailyTotals>) =>
			bucket === 'week' ? weekly(points) : points;
		return {
			type,
			bucket,
			groups: [...groups].map(([key, group]) => ({
				key,
				points:
					metricKind(type) === 'lifetime' ? [] : bucketed(dailyTotals(group, scope.from, scope.to))
			}))
		};
	},

	async resources(scope, query: ResourceQuery): Promise<ResourcePage> {
		const [{ slices, ids }, catalog] = await Promise.all([scoped(scope), loadCatalog()]);
		const byType = new Map(slices.map((slice) => [slice.type, slice.readings]));

		const rows: ResourceRow[] = [];
		for (const id of ids) {
			const resource = catalog.resourceByID.get(id);
			if (!resource || !resource.type) continue;
			if (query.kind && resource.type !== query.kind) continue;

			const latest: ResourceRow['latest'] = {};
			const atStart: ResourceRow['atStart'] = {};
			let newest = 0;
			for (const [type, readings] of byType) {
				const own = readings.filter((r) => r.resourceID === id);
				if (own.length === 0) continue;
				const last = latestByResource(own).get(id)!;
				latest[type] = last.value;
				newest = Math.max(newest, last.time);
				const start = totalAsOf(own, scope.from);
				if (start !== null) atStart[type] = start;
			}

			const sortReadings = (byType.get(query.sort) ?? []).filter((r) => r.resourceID === id);
			const account = catalog.accountByID.get(resource.accountID?.toLowerCase() ?? '');
			rows.push({
				id,
				name: resource.name ?? 'Unnamed resource',
				kind: resource.type,
				platform: catalog.platformOf.get(id) ?? null,
				account: account?.name ?? null,
				lastCollectedAt: newest ? new Date(newest).toISOString() : null,
				latest,
				atStart,
				spark:
					metricKind(query.sort) === 'lifetime'
						? []
						: dailyTotals(sortReadings, scope.from, scope.to)
			});
		}

		const direction = query.order === 'asc' ? 1 : -1;
		rows.sort((a, b) => {
			const av = a.latest[query.sort];
			const bv = b.latest[query.sort];
			if (av === undefined && bv === undefined) return a.name.localeCompare(b.name);
			if (av === undefined) return 1;
			if (bv === undefined) return -1;
			return (av - bv) * direction || a.name.localeCompare(b.name);
		});

		return { total: rows.length, rows: rows.slice(query.offset, query.offset + query.limit) };
	}
};

/** Today in UTC, for defaulting ranges. */
export const today = (): string => isoDay(Date.now());
