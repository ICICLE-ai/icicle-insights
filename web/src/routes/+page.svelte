<script lang="ts">
	import { page } from '$app/state';
	import * as Card from '$lib/components/ui/card';
	import CatalogSummary from '$lib/components/catalog-summary.svelte';
	import Delta from '$lib/components/delta.svelte';
	import LoadError from '$lib/components/load-error.svelte';
	import ResourceTable from '$lib/components/resource-table.svelte';
	import StatTile from '$lib/components/stat-tile.svelte';
	import TrendChart, { type TrendSeries } from '$lib/components/trend-chart.svelte';
	import { Skeleton } from '$lib/components/ui/skeleton';
	import type { MetricType } from '$lib/api/types';
	import { loadCatalog, scopedResourceIDs } from '$lib/data/catalog';
	import { source } from '$lib/data/source';
	import {
		compact,
		formatDate,
		isMetricType,
		METRICS,
		metricLabel,
		platformColor,
		platformLabel,
		pluralize
	} from '$lib/format';
	import { query } from '$lib/query.svelte';
	import { bucketFor, platformParam, rangeLabel, scope, setParams } from '$lib/scope.svelte';

	const overview = query(async () => {
		const current = scope();
		const [catalog, summary] = await Promise.all([loadCatalog(), source.summary(current)]);
		return { catalog, summary, current };
	});

	// Tiles for things that change over time lead; lifetime totals follow as a quieter strip,
	// because until the server keeps their history they have a value but no trend to click into.
	const trending = $derived(
		overview.data?.summary.tiles.filter((t) => t.kind !== 'lifetime') ?? []
	);
	const lifetime = $derived(
		overview.data?.summary.tiles.filter((t) => t.kind === 'lifetime') ?? []
	);

	const selected = $derived.by((): MetricType | null => {
		const requested = page.url.searchParams.get('metric');
		if (isMetricType(requested) && trending.some((t) => t.type === requested)) return requested;
		return trending[0]?.type ?? null;
	});
	const selectedTile = $derived(trending.find((t) => t.type === selected) ?? null);

	const detail = query(async () => {
		const metric = selected;
		const current = scope();
		if (!metric) return null;
		const [series, resources] = await Promise.all([
			source.series(current, metric, 'platform', bucketFor(current)),
			source.resources(current, { sort: metric, order: 'desc', limit: 500, offset: 0 })
		]);
		return { metric, series, resources };
	});

	const chartSeries = $derived<TrendSeries[]>(
		(detail.data?.series.groups ?? []).map((group) => ({
			key: group.key,
			label: platformLabel(group.key),
			color: platformColor(group.key),
			points: group.points
		}))
	);

	// Value columns for the table: the selected metric first, then up to two others that exist
	// in this scope, so a GitHub view shows views and clones and a Hugging Face view downloads.
	const tableMetrics = $derived.by((): MetricType[] => {
		if (!selected) return [];
		const others = trending.map((t) => t.type).filter((t) => t !== selected);
		return [selected, ...others.slice(0, 2)];
	});

	// Only resources that report the selected metric. A container has no stars, and listing it with
	// a dash would push the rows that matter onto later pages; the full catalog is on /resources.
	const reporting = $derived(
		detail.data
			? detail.data.resources.rows.filter((row) => row.latest[detail.data!.metric] !== undefined)
			: []
	);

	const scopeName = $derived(platformParam() ? platformLabel(platformParam()) : 'All platforms');
	const ids = $derived(
		overview.data
			? scopedResourceIDs(overview.data.catalog, overview.data.current)
			: new Set<string>()
	);
</script>

<svelte:head><title>Overview · ICICLE Insights</title></svelte:head>

<div class="flex flex-col gap-6">
	<div class="flex flex-wrap items-end justify-between gap-2">
		<div>
			<h1 class="text-xl font-semibold tracking-tight">{scopeName}</h1>
			<p class="text-sm text-muted-foreground">
				{#if overview.data}
					{pluralize(ids.size, 'resource')} · last {rangeLabel()} · {formatDate(
						overview.data.summary.from
					)} to {formatDate(overview.data.summary.to)}
				{:else}&nbsp;{/if}
			</p>
		</div>
	</div>

	{#if overview.error && !overview.data}
		<LoadError error={overview.error} retry={overview.refresh} />
	{:else if !overview.data}
		<div class="grid grid-cols-2 gap-3 md:grid-cols-3 lg:grid-cols-6">
			{#each Array(6) as _, i (i)}<Skeleton class="h-[104px] rounded-xl" />{/each}
		</div>
		<Skeleton class="h-80 rounded-xl" />
	{:else}
		<div class="flex flex-col gap-6 transition-opacity {overview.loading ? 'opacity-60' : ''}">
			{#if trending.length === 0 && lifetime.length === 0}
				<div class="rounded-xl border bg-card p-10 text-center text-sm text-muted-foreground">
					No readings for these resources yet. Collection runs on each resource's own schedule.
				</div>
			{/if}

			{#if trending.length}
				<section aria-label="Metrics" class="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-4">
					{#each trending as tile (tile.type)}
						<StatTile
							{tile}
							selected={tile.type === selected}
							onselect={() => setParams({ metric: tile.type })}
						/>
					{/each}
				</section>
			{/if}

			{#if lifetime.length}
				<section
					aria-label="Lifetime totals"
					class="flex flex-wrap items-baseline gap-x-6 gap-y-2 text-sm"
				>
					<span class="text-xs font-medium tracking-wide text-muted-foreground uppercase"
						>Lifetime</span
					>
					{#each lifetime as tile (tile.type)}
						<span class="flex items-baseline gap-1.5">
							<span class="font-semibold">{compact(tile.current)}</span>
							<span class="text-muted-foreground">{METRICS[tile.type].short.toLowerCase()}</span>
						</span>
					{/each}
				</section>
			{/if}

			{#if selectedTile}
				<div class="grid gap-6 lg:grid-cols-3">
					<Card.Root class="lg:col-span-2">
						<Card.Header>
							<Card.Title>{metricLabel(selectedTile.type)}</Card.Title>
							<Card.Description>
								Total across {pluralize(reporting.length, 'resource')}
								{#if selectedTile.atStart !== null}
									· <Delta current={selectedTile.current} start={selectedTile.atStart} /> since {formatDate(
										overview.data.summary.from
									)}
								{/if}
								{#if METRICS[selectedTile.type].window}
									<span class="block text-xs"
										>Each reading covers {METRICS[selectedTile.type].window}.</span
									>
								{/if}
							</Card.Description>
						</Card.Header>
						<Card.Content
							class={detail.loading ? 'opacity-60 transition-opacity' : 'transition-opacity'}
						>
							{#if detail.error}
								<LoadError error={detail.error} retry={detail.refresh} />
							{:else if detail.data}
								<TrendChart
									series={chartSeries}
									label="{metricLabel(selectedTile.type)}, total by platform, last {rangeLabel()}"
								/>
							{:else}
								<Skeleton class="h-[260px]" />
							{/if}
						</Card.Content>
					</Card.Root>

					<Card.Root>
						<Card.Header>
							<Card.Title>Catalog</Card.Title>
							<Card.Description>What is being measured</Card.Description>
						</Card.Header>
						<Card.Content>
							<CatalogSummary catalog={overview.data.catalog} {ids} />
						</Card.Content>
					</Card.Root>
				</div>
			{/if}

			{#if selected && detail.data}
				<Card.Root>
					<Card.Header>
						<Card.Title>Resources</Card.Title>
						<Card.Description>
							Resources reporting {metricLabel(selected).toLowerCase()}, with change over the last {rangeLabel()}.
							<a href="/resources" class="underline-offset-4 hover:underline">See every resource</a>
						</Card.Description>
					</Card.Header>
					<Card.Content>
						<ResourceTable
							rows={reporting}
							trendMetric={selected}
							metrics={tableMetrics}
							caption="Resources in {scopeName}, sorted by {metricLabel(selected)}"
						/>
					</Card.Content>
				</Card.Root>
			{/if}
		</div>
	{/if}
</div>
