<script lang="ts">
	import { page } from '$app/state';
	import * as Card from '$lib/components/ui/card';
	import * as Select from '$lib/components/ui/select';
	import * as ToggleGroup from '$lib/components/ui/toggle-group';
	import LoadError from '$lib/components/load-error.svelte';
	import ResourceTable from '$lib/components/resource-table.svelte';
	import { Skeleton } from '$lib/components/ui/skeleton';
	import type { MetricType, ResourceType } from '$lib/api/types';
	import { source } from '$lib/data/source';
	import {
		isMetricType,
		kindPlural,
		METRIC_ORDER,
		metricKind,
		metricLabel,
		platformLabel
	} from '$lib/format';
	import { query } from '$lib/query.svelte';
	import { platformParam, rangeLabel, scope, setParams } from '$lib/scope.svelte';

	/**
	 * The whole catalog in scope as one table, including resources no collector reports on yet
	 * (containers, packages). The overview's table only lists resources that report the metric
	 * it is plotting; this is where everything else is.
	 */
	const data = query(async () => {
		const current = scope();
		const src = await source();
		const summary = await src.summary(current);
		const available = METRIC_ORDER.filter(
			(type) => metricKind(type) !== 'lifetime' && summary.tiles.some((tile) => tile.type === type)
		);
		const requested = page.url.searchParams.get('sort');
		const sort: MetricType =
			isMetricType(requested) && available.includes(requested)
				? requested
				: (available[0] ?? 'stars');
		const resources = await src.resources(current, { sort, order: 'desc', limit: 500, offset: 0 });
		return { available, sort, resources };
	});

	const kind = $derived((page.url.searchParams.get('kind') ?? 'all') as ResourceType | 'all');
	const kinds = $derived(
		[...new Set(data.data?.resources.rows.map((row) => row.kind) ?? [])].sort()
	);
	const rows = $derived(
		(data.data?.resources.rows ?? []).filter((row) => kind === 'all' || row.kind === kind)
	);
	const columns = $derived.by((): MetricType[] => {
		if (!data.data) return [];
		const { sort, available } = data.data;
		return [sort, ...available.filter((type) => type !== sort).slice(0, 3)];
	});
</script>

<svelte:head><title>Resources · ICICLE Insights</title></svelte:head>

<div class="flex flex-col gap-6">
	<div>
		<h1 class="text-xl font-semibold tracking-tight">Resources</h1>
		<p class="text-sm text-muted-foreground">
			Every repository, model, dataset, container and package {platformParam()
				? `on ${platformLabel(platformParam())}`
				: 'being tracked'}.
		</p>
	</div>

	{#if data.error && !data.data}
		<LoadError error={data.error} retry={data.refresh} />
	{:else if !data.data}
		<Skeleton class="h-[520px] rounded-xl" />
	{:else}
		<Card.Root class={data.loading ? 'opacity-60 transition-opacity' : 'transition-opacity'}>
			<Card.Header class="gap-3">
				<div class="flex flex-wrap items-center gap-3">
					<ToggleGroup.Root
						type="single"
						variant="outline"
						size="sm"
						value={kind}
						onValueChange={(value) => value && setParams({ kind: value === 'all' ? null : value })}
						aria-label="Kind"
					>
						<ToggleGroup.Item value="all" class="px-2.5 text-xs">All</ToggleGroup.Item>
						{#each kinds as k (k)}
							<ToggleGroup.Item value={k} class="px-2.5 text-xs">{kindPlural(k)}</ToggleGroup.Item>
						{/each}
					</ToggleGroup.Root>
					{#if data.data.available.length}
						<div class="ml-auto flex items-center gap-2 text-sm">
							<span class="text-xs text-muted-foreground">Change and trend in</span>
							<Select.Root
								type="single"
								value={data.data.sort}
								onValueChange={(value) => setParams({ sort: value })}
							>
								<Select.Trigger size="sm" class="min-w-40" aria-label="Metric for change and trend">
									{metricLabel(data.data.sort)}
								</Select.Trigger>
								<Select.Content>
									{#each data.data.available as type (type)}
										<Select.Item value={type} label={metricLabel(type)} />
									{/each}
								</Select.Content>
							</Select.Root>
						</div>
					{/if}
				</div>
			</Card.Header>
			<Card.Content>
				<ResourceTable
					{rows}
					trendMetric={data.data.sort}
					metrics={columns}
					pageSize={20}
					caption="All resources, change over the last {rangeLabel()}"
				/>
			</Card.Content>
		</Card.Root>
	{/if}
</div>
